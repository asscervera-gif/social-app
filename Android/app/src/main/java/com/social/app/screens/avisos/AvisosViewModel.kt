package com.social.app.screens.avisos

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.NotificationEntry
import com.social.app.backend.model.Profile
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

    // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
    // chats/duelos: Avisos mostraba un icono de emoji genérico por tipo,
    // pero nunca el avatar de quién disparó el aviso -- comparado con la
    // pestaña "Actividad" de Instagram, que siempre muestra la foto de
    // perfil del actor como elemento visual principal de cada fila.
    private val _actorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val actorProfiles: StateFlow<Map<String, Profile>> = _actorProfiles.asStateFlow()

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
            val loaded = SupabaseManager.client.from("notifications")
                .select(columns = Columns.raw("id,kind,payload,read_at,created_at")) {
                    order("created_at", Order.DESCENDING); limit(50)
                }
                .decodeList<NotificationEntry>()
            _notifications.value = loaded
            fetchActorProfiles(loaded.mapNotNull { it.payload["actor_id"] }.distinct())
        } catch (e: Exception) {
            _errorMessage.value = "No se pudieron cargar los avisos: ${e.message}"
        }
    }

    private suspend fun fetchActorProfiles(actorIds: List<String>) {
        val missing = actorIds.filter { it !in _actorProfiles.value }
        if (missing.isEmpty()) return
        try {
            val fetched = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                    filter { isIn("id", missing) }
                }
                .decodeList<Profile>()
                .associateBy { it.id }
            _actorProfiles.update { it + fetched }
        } catch (e: Exception) {
            // No bloquea el resto de Avisos si falla -- las filas se
            // siguen mostrando aunque no se pueda mostrar el avatar.
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
                entry.payload["actor_id"]?.let { fetchActorProfiles(listOf(it)) }
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

    /** Hallazgo real, comparado con Gmail/Instagram/Twitter -- cualquier
     * lista de notificaciones grande deja marcar todo como leído de una
     * vez, no solo aviso por aviso. `notifications_update`
     * (0002_rls.sql) es por fila (`recipient_id = auth.uid()`), sin
     * límite de cuántas filas puede tocar una sola sentencia -- un
     * UPDATE real, no N llamadas. Igual que markMessagesRead()
     * (ChatViewModel.kt): marcar de nuevo un aviso ya leído es
     * idempotente, no hace falta filtrar por null (sin `isNull`
     * verificado en el resto del proyecto). */
    fun markAllRead() {
        if (_notifications.value.all { it.readAt != null }) return
        _notifications.update { list -> list.map { it.copy(readAt = it.readAt ?: "now") } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val nowIso = java.time.Instant.now().toString()
                SupabaseManager.client.from("notifications")
                    .update({ set("read_at", nowIso) }) { filter { eq("recipient_id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron marcar todos los avisos como leídos."
            }
        }
    }
}

// Hallazgo real: aceptar un social o una solicitud de compatibilidad no
// notificaba nunca a quien la pidió -- ver 0046_notify_accepted.sql.
fun NotificationEntry.icon(): String = when (kind) {
    "social" -> "👥"
    "follow" -> "➕"
    "fight" -> "⚡"
    "like" -> "❤"
    "compat_request" -> "%"
    "social_accepted" -> "✅"
    "compat_accepted" -> "%"
    // Hallazgo real, el hueco de mensajería más grande de la sesión:
    // ningún mensaje nuevo generaba nunca un aviso -- ver
    // 0047_message_notify_mute.sql.
    "message" -> "💬"
    // Reels (0050_reels.sql) -- mismos iconos que like/comment normales.
    "reel_like" -> "❤"
    "reel_comment" -> "💬"
    // Hallazgo real (0058_group_message_notify.sql): "comment"/
    // "comment_like"/"reel_comment_like" ya estaban en
    // notifications_kind_check desde hace varias rondas (0008/0054), pero
    // NUNCA se añadieron aquí -- caían siempre en el "🔔" genérico aunque
    // el aviso en sí se generara bien. Corregido junto con "group_message"
    // (nuevo, 0057_group_chats.sql).
    "comment" -> "💬"
    "comment_like" -> "❤"
    "reel_comment_like" -> "❤"
    "group_message" -> "👥"
    else -> "🔔"
}

fun NotificationEntry.title(): String = when (kind) {
    "social" -> "Nueva solicitud de social"
    "follow" -> "Nuevo seguidor"
    "fight" -> "Duelo completado"
    "like" -> "Le gustó tu publicación"
    "compat_request" -> "Quiere ver tu compatibilidad"
    "social_accepted" -> "Aceptó tu social"
    "compat_accepted" -> "Compartió su compatibilidad contigo"
    "message" -> "Nuevo mensaje"
    "reel_like" -> "Le gustó tu reel"
    "reel_comment" -> "Comentó tu reel"
    "comment" -> "Comentó tu publicación"
    "comment_like" -> "Le gustó tu comentario"
    "reel_comment_like" -> "Le gustó tu comentario"
    "group_message" -> "Nuevo mensaje de grupo"
    else -> "Notificación"
}
