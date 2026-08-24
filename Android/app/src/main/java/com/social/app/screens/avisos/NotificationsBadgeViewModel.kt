package com.social.app.screens.avisos

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.NotificationEntry
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Contador de no leídas para el badge de la pestaña Avisos — antes la
 * pestaña nunca mostraba si había avisos nuevos sin entrar a mirar, a
 * pesar de que `notifications.read_at` ya distingue leído/no leído desde
 * el esquema original y `AvisosViewModel.markRead()` ya lo actualiza.
 * Suscripción realtime en vez de sondeo — mismo patrón ya verificado por
 * el compilador en ChatViewModel.kt (postgresChangeFlow<Insert/Update>).
 */
class NotificationsBadgeViewModel : ViewModel() {

    private val _unreadCount = MutableStateFlow(0)
    val unreadCount: StateFlow<Int> = _unreadCount.asStateFlow()

    private var channel: RealtimeChannel? = null
    // applicationContext, no Activity — RootTabView pasa
    // `LocalContext.current.applicationContext` explícitamente, así que
    // esto no puede filtrar (leak) una Activity aunque el ViewModel
    // sobreviva a rotaciones/recomposiciones.
    private var appContext: Context? = null

    @Serializable
    private data class NotificationRow(
        @SerialName("id") val id: String,
        @SerialName("read_at") val readAt: String? = null
    )

    fun start(context: Context) {
        appContext = context
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            refresh(userId)
            subscribeToRealtime(userId)
        }
    }

    fun stop() {
        viewModelScope.launch { channel?.unsubscribe() }
    }

    private suspend fun refresh(userId: String) {
        try {
            // Sin `isNull` verificado en el resto del código — se trae
            // id+read_at y se cuenta en cliente, mismo criterio que otros
            // filtros no probados en este proyecto. El filtro explícito
            // por `recipient_id` es defensa en profundidad (RLS ya limita
            // a las propias, `notifications_select` en 0002_rls.sql) —
            // antes `userId` se recibía pero nunca se usaba en la consulta.
            val rows = SupabaseManager.client.from("notifications")
                .select(columns = Columns.raw("id,read_at")) {
                    filter { eq("recipient_id", userId) }
                }
                .decodeList<NotificationRow>()
            _unreadCount.value = rows.count { it.readAt == null }
        } catch (e: Exception) {
            // Sin conexión o error de red: se mantiene el último contador
            // conocido en vez de forzarlo a 0, mismo criterio que el resto
            // de ViewModels de esta app ante errores de carga.
        }
    }

    private fun subscribeToRealtime(userId: String) {
        val ch = SupabaseManager.client.realtime.channel("notifications-badge-$userId")
        channel = ch

        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "notifications"
            filter("recipient_id", FilterOperator.EQ, userId)
        }.onEach { insert ->
            _unreadCount.value += 1
            // Notificación local real del sistema — hasta ahora un aviso
            // nuevo solo movía el número del badge, invisible si el
            // usuario estaba en otra pestaña. Ver LocalNotifier.kt para el
            // aviso de honestidad sobre por qué esto no es push real.
            appContext?.let { ctx ->
                try {
                    val entry = Json.decodeFromJsonElement(NotificationEntry.serializer(), insert.record)
                    LocalNotifier.notify(ctx, entry)
                } catch (e: Exception) {
                    // Payload inesperado: no bloquear el contador del badge
                    // (ya actualizado arriba) por un fallo solo de la
                    // notificación visual.
                }
            }
        }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "notifications"
            filter("recipient_id", FilterOperator.EQ, userId)
        }.onEach {
            // No decodificamos el payload para saber si pasó de no-leída a
            // leída (marcar como leída es la única actualización real que
            // hace este cliente) — recargar el contador es más simple y
            // igual de correcto que llevar la cuenta en memoria.
            refresh(userId)
        }.launchIn(viewModelScope)

        viewModelScope.launch { ch.subscribe() }
    }
}
