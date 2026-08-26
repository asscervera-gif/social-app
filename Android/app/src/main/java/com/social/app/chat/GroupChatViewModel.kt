package com.social.app.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
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
data class GroupMessage(
    val id: String,
    @SerialName("group_chat_id") val groupChatId: String,
    @SerialName("sender_id") val senderId: String,
    val body: String? = null,
    @SerialName("media_url") val mediaUrl: String? = null,
    @SerialName("created_at") val createdAt: String = ""
)

/**
 * Hilo de un chat de grupo real -- mismo patrón que ChatViewModel.kt
 * (1:1), simplificado a propósito: sin reacciones/voz/read-receipts
 * todavía (`group_messages` no las tiene, hueco real documentado en
 * 0057_group_chats.sql, no fingido). Mensajes en vivo vía Realtime, mismo
 * mecanismo ya usado en el chat 1:1 (`postgresChangeFlow`).
 */
class GroupChatViewModel(private val groupChatId: String) : ViewModel() {

    private val _messages = MutableStateFlow<List<GroupMessage>>(emptyList())
    val messages: StateFlow<List<GroupMessage>> = _messages.asStateFlow()

    private val _members = MutableStateFlow<List<Profile>>(emptyList())
    val members: StateFlow<List<Profile>> = _members.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var channel: RealtimeChannel? = null

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _messages.value = SupabaseManager.client.from("group_messages")
                    .select(columns = Columns.raw("id,group_chat_id,sender_id,body,media_url,created_at")) {
                        filter { eq("group_chat_id", groupChatId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<GroupMessage>()
                loadMembers()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los mensajes: ${e.message}"
            } finally {
                _isLoading.value = false
            }
            subscribeToRealtime()
        }
    }

    private suspend fun loadMembers() {
        try {
            val memberIds = SupabaseManager.client.from("group_chat_members")
                .select(columns = Columns.raw("user_id")) { filter { eq("group_chat_id", groupChatId) } }
                .decodeList<MemberIdRow>()
                .map { it.userId }
            if (memberIds.isNotEmpty()) {
                _members.value = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                        filter { isIn("id", memberIds) }
                    }
                    .decodeList<Profile>()
            }
        } catch (e: Exception) {
            // No bloquea el hilo si falla -- los mensajes se siguen
            // mostrando aunque no se pueda mostrar la lista de miembros.
        }
    }

    @Serializable
    private data class MemberIdRow(@SerialName("user_id") val userId: String)

    private fun subscribeToRealtime() {
        val ch = SupabaseManager.client.realtime.channel("group-chat-$groupChatId")
        channel = ch
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "group_messages"
            filter("group_chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, groupChatId)
        }.onEach { insert ->
            val message = Json.decodeFromJsonElement(GroupMessage.serializer(), insert.record)
            if (_messages.value.none { it.id == message.id }) {
                _messages.update { it + message }
            }
        }.launchIn(viewModelScope)
        viewModelScope.launch { ch.subscribe() }
    }

    @Serializable
    private data class NewGroupMessage(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String
    )

    fun sendMessage(text: String) {
        if (text.isBlank()) return
        // Mismo límite real que group_messages (char_length between 1 and
        // 2000, 0057_group_chats.sql) — mismo criterio ya aplicado al
        // resto de campos de texto de la app.
        if (text.length > 2000) {
            _errorMessage.value = "El mensaje no puede tener más de 2000 caracteres."
            return
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val inserted = SupabaseManager.client.from("group_messages")
                    .insert(NewGroupMessage(groupChatId, userId, text)) { select() }
                    .decodeSingle<GroupMessage>()
                if (_messages.value.none { it.id == inserted.id }) {
                    _messages.update { it + inserted }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el mensaje."
            }
        }
    }

    @Serializable
    private data class NewMember(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("user_id") val userId: String
    )

    /** Añadir a alguien real al grupo ya creado -- cualquier miembro puede
     * (RLS `group_chat_members_insert`, 0057_group_chats.sql), salvo
     * bloqueo real de por medio. */
    fun addMember(profileId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("group_chat_members").insert(NewMember(groupChatId, profileId))
                loadMembers()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo añadir al grupo."
            }
        }
    }

    /** Salir del grupo real -- borra la propia fila (RLS
     * `group_chat_members_delete_own`). */
    fun leaveGroup(onLeft: () -> Unit) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").delete {
                    filter { eq("group_chat_id", groupChatId); eq("user_id", userId) }
                }
                onLeft()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo salir del grupo."
            }
        }
    }
}
