package com.social.app.screens.live

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement

@Serializable
data class LiveStreamMessage(
    val id: String,
    @SerialName("stream_id") val streamId: String,
    @SerialName("sender_id") val senderId: String,
    val body: String,
    @SerialName("created_at") val createdAt: String = ""
)

/**
 * Chat en vivo real durante un directo, comparado con Instagram/TikTok
 * Live -- ver 0059_live_stream_messages.sql para el hallazgo completo (el
 * vídeo ya existía desde la ronda anterior, pero nadie podía escribir
 * mientras lo veía). Mismo mecanismo de Realtime ya usado en
 * ChatViewModel.kt/GroupChatViewModel.kt (`postgresChangeFlow`).
 */
class LiveStreamChatViewModel(private val streamId: String) : ViewModel() {

    private val _messages = MutableStateFlow<List<LiveStreamMessage>>(emptyList())
    val messages: StateFlow<List<LiveStreamMessage>> = _messages.asStateFlow()

    private val _senderNames = MutableStateFlow<Map<String, String>>(emptyMap())
    val senderNames: StateFlow<Map<String, String>> = _senderNames.asStateFlow()

    private var channel: RealtimeChannel? = null

    fun load() {
        viewModelScope.launch {
            try {
                _messages.value = SupabaseManager.client.from("live_stream_messages")
                    .select(columns = Columns.raw("id,stream_id,sender_id,body,created_at")) {
                        filter { eq("stream_id", streamId) }
                        order("created_at", Order.ASCENDING)
                        limit(200)
                    }
                    .decodeList<LiveStreamMessage>()
                resolveSenderNames(_messages.value.map { it.senderId })
            } catch (e: Exception) {
                // El chat no es crítico para ver el vídeo -- si falla la
                // carga, el directo sigue reproduciéndose con normalidad.
            }
            subscribeToRealtime()
        }
    }

    private suspend fun resolveSenderNames(senderIds: List<String>) {
        val missing = senderIds.distinct().filter { it !in _senderNames.value }
        if (missing.isEmpty()) return
        try {
            val profiles = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name")) { filter { isIn("id", missing) } }
                .decodeList<com.social.app.backend.model.Profile>()
            _senderNames.update { it + profiles.associate { p -> p.id to p.displayName } }
        } catch (e: Exception) {
            // No crítico -- el mensaje se sigue mostrando con "…" de remitente.
        }
    }

    private fun subscribeToRealtime() {
        val ch = SupabaseManager.client.realtime.channel("live-chat-$streamId")
        channel = ch
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "live_stream_messages"
            filter("stream_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, streamId)
        }.onEach { insert ->
            val message = Json.decodeFromJsonElement(LiveStreamMessage.serializer(), insert.record)
            if (_messages.value.none { it.id == message.id }) {
                _messages.update { it + message }
                viewModelScope.launch { resolveSenderNames(listOf(message.senderId)) }
            }
        }.launchIn(viewModelScope)
        viewModelScope.launch { ch.subscribe() }
    }

    @Serializable
    private data class NewLiveStreamMessage(
        @SerialName("stream_id") val streamId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String
    )

    fun sendMessage(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        // Mismo límite real que live_stream_messages (char_length between
        // 1 and 200, 0059_live_stream_messages.sql) -- chat en vivo corto
        // a propósito, no un mensaje de chat privado largo.
        if (trimmed.length > 200) return
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("live_stream_messages").insert(NewLiveStreamMessage(streamId, userId, trimmed))
            } catch (e: Exception) {
                // Best-effort -- un mensaje de chat en vivo que falla no
                // debe interrumpir la visualización del directo.
            }
        }
    }
}
