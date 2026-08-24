package com.social.app.screens.avisos

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.NotificationEntry
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/** Equivalente Kotlin de AvisosViewModel.swift, con Realtime en vivo (mismo
 * refuerzo que se aplicó en la versión iOS: sin esto, un aviso nuevo solo
 * se vería al reabrir la pestaña). */
class AvisosViewModel : ViewModel() {

    private val _notifications = MutableStateFlow<List<NotificationEntry>>(emptyList())
    val notifications: StateFlow<List<NotificationEntry>> = _notifications.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun start() {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            load()
            subscribeToRealtime(userId)
        }
    }

    /** Recarga manual (pull-to-refresh) sin volver a suscribirse a Realtime
     * — start() ya lo hace una vez; repetirlo aquí duplicaría el canal. */
    fun refresh() {
        viewModelScope.launch { load() }
    }

    private suspend fun load() {
        try {
            // Optimización: NotificationEntry no decodifica recipient_id ni
            // actor_id (el actor real se lee de payload["actor_id"], ver
            // convención documentada en FollowManager.kt) — se omiten.
            _notifications.value = SupabaseManager.client.from("notifications")
                .select(columns = Columns.raw("id,kind,payload,read_at,created_at")) {
                    order("created_at", Order.DESCENDING); limit(50)
                }
                .decodeList<NotificationEntry>()
        } catch (e: Exception) {
            _errorMessage.value = "No se pudieron cargar los avisos: ${e.message}"
        }
    }

    private fun subscribeToRealtime(userId: String) {
        viewModelScope.launch {
            val channel = SupabaseManager.client.realtime.channel("notifications-$userId")
            channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
                table = "notifications"
                filter("recipient_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, userId)
            }.onEach { insert ->
                val entry = Json.decodeFromJsonElement(NotificationEntry.serializer(), insert.record)
                _notifications.update { listOf(entry) + it }
            }.launchIn(viewModelScope)
            channel.subscribe()
        }
    }

    fun markRead(entry: NotificationEntry) {
        _notifications.update { list -> list.map { if (it.id == entry.id) it.copy(readAt = "now") else it } }
        viewModelScope.launch {
            try {
                // Firma del DSL `update{}` verificada: compila limpio contra
                // supabase-kt 2.5.4 real (antes marcado como no confirmado
                // por falta de compilador en este entorno).
                val nowIso = java.time.Instant.now().toString()
                SupabaseManager.client.from("notifications")
                    .update({ set("read_at", nowIso) }) { filter { eq("id", entry.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo marcar como leído."
            }
        }
    }
}

fun NotificationEntry.icon(): String = when (kind) {
    "social" -> "👥"
    "follow" -> "➕"
    "fight" -> "⚡"
    "like" -> "❤"
    "compat_request" -> "%"
    else -> "🔔"
}

fun NotificationEntry.title(): String = when (kind) {
    "social" -> "Nueva solicitud de social"
    "follow" -> "Nuevo seguidor"
    "fight" -> "Duelo completado"
    "like" -> "Le gustó tu publicación"
    "compat_request" -> "Quiere ver tu compatibilidad"
    else -> "Notificación"
}
