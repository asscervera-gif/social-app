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
 * (1:1). Reacciones (0060_group_message_reactions.sql) y "visto por"
 * (0061_group_message_reads.sql) reales -- voz sigue pendiente, hueco
 * real documentado. Mensajes en vivo vía Realtime, mismo mecanismo ya
 * usado en el chat 1:1 (`postgresChangeFlow`).
 */
class GroupChatViewModel(private val groupChatId: String) : ViewModel() {

    private val _messages = MutableStateFlow<List<GroupMessage>>(emptyList())
    val messages: StateFlow<List<GroupMessage>> = _messages.asStateFlow()

    private val _members = MutableStateFlow<List<Profile>>(emptyList())
    val members: StateFlow<List<Profile>> = _members.asStateFlow()

    // Reacciones a mensajes de grupo (0060_group_message_reactions.sql),
    // comparado con WhatsApp/Messenger/Instagram -- mismo patrón exacto
    // que ChatViewModel.kt (chat 1:1, 0018_message_reactions.sql).
    @Serializable
    data class GroupMessageReaction(
        val id: String,
        @SerialName("group_message_id") val groupMessageId: String,
        @SerialName("user_id") val userId: String,
        val emoji: String
    )

    private val _reactions = MutableStateFlow<Map<String, List<GroupMessageReaction>>>(emptyMap())
    val reactions: StateFlow<Map<String, List<GroupMessageReaction>>> = _reactions.asStateFlow()

    // "Visto por" real en chats de grupo (0061_group_message_reads.sql),
    // comparado con WhatsApp/Messenger -- mapa de group_message_id a la
    // lista de user_id que lo han leído (nunca incluye al propio autor,
    // RLS lo impide desde el servidor).
    private val _reads = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val reads: StateFlow<Map<String, List<String>>> = _reads.asStateFlow()

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
                loadReactions()
                loadReads()
                markUnreadAsRead()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los mensajes: ${e.message}"
            } finally {
                _isLoading.value = false
            }
            subscribeToRealtime()
        }
    }

    @Serializable
    private data class ReadRow(
        @SerialName("group_message_id") val groupMessageId: String,
        @SerialName("user_id") val userId: String
    )

    private suspend fun loadReads() {
        try {
            val rows = SupabaseManager.client.from("group_message_reads")
                .select(columns = Columns.raw("group_message_id,user_id")) { filter { eq("group_chat_id", groupChatId) } }
                .decodeList<ReadRow>()
            _reads.value = rows.groupBy({ it.groupMessageId }, { it.userId })
        } catch (e: Exception) {
            // Sin bloquear el resto del hilo si falla.
        }
    }

    @Serializable
    private data class NewRead(
        @SerialName("group_message_id") val groupMessageId: String,
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("user_id") val userId: String
    )

    /** Marca como leídos todos los mensajes AJENOS todavía no leídos por
     * mí -- RLS (`group_message_reads_insert_own`) ya impide marcar el
     * propio, así que basta con intentarlo para todos y dejar que el
     * servidor descarte lo que no corresponda. */
    private suspend fun markUnreadAsRead() {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
        val alreadyRead = _reads.value.filterValues { userId in it }.keys
        val toMark = _messages.value.filter { it.senderId != userId && it.id !in alreadyRead }
        if (toMark.isEmpty()) return
        try {
            val rows = toMark.map { NewRead(it.id, groupChatId, userId) }
            SupabaseManager.client.from("group_message_reads").insert(rows)
            _reads.update { map ->
                var result = map
                toMark.forEach { msg -> result = result + (msg.id to (result[msg.id].orEmpty() + userId)) }
                result
            }
        } catch (e: Exception) {
            // Best-effort -- un recibo de lectura que falla no debe
            // interrumpir la lectura del chat.
        }
    }

    private suspend fun loadReactions() {
        try {
            // Filtro directo por group_chat_id (desnormalizado en la
            // tabla) en vez de `isIn` sobre una lista de group_message_id
            // -- mismo criterio ya usado en ChatViewModel.kt.loadReactions().
            val rows = SupabaseManager.client.from("group_message_reactions")
                .select { filter { eq("group_chat_id", groupChatId) } }
                .decodeList<GroupMessageReaction>()
            _reactions.value = rows.groupBy { it.groupMessageId }
        } catch (e: Exception) {
            // Sin bloquear el resto del hilo si falla.
        }
    }

    @Serializable
    private data class NewGroupReaction(
        @SerialName("group_message_id") val groupMessageId: String,
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("user_id") val userId: String,
        val emoji: String
    )

    /** Toggle: si ya reaccionaste con ese emoji a ese mensaje, lo quita; si
     * no, lo añade. `unique(group_message_id, user_id, emoji)`
     * (0060_group_message_reactions.sql) es la fuente de verdad real. */
    fun toggleReaction(groupMessageId: String, emoji: String) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            val existing = _reactions.value[groupMessageId]?.firstOrNull { it.userId == userId && it.emoji == emoji }
            try {
                if (existing != null) {
                    SupabaseManager.client.from("group_message_reactions").delete { filter { eq("id", existing.id) } }
                    _reactions.update { map ->
                        map + (groupMessageId to (map[groupMessageId].orEmpty().filter { it.id != existing.id }))
                    }
                } else {
                    val inserted = SupabaseManager.client.from("group_message_reactions")
                        .insert(NewGroupReaction(groupMessageId, groupChatId, userId, emoji)) { select() }
                        .decodeSingle<GroupMessageReaction>()
                    _reactions.update { map ->
                        map + (groupMessageId to (map[groupMessageId].orEmpty() + inserted))
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo reaccionar."
            }
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
                // El chat sigue abierto -- un mensaje que llega en vivo se
                // marca leído igual que uno cargado al abrir el hilo.
                markUnreadAsRead()
            }
        }.launchIn(viewModelScope)

        // "Visto por" en vivo -- otro miembro marcando como leído uno de
        // mis mensajes, sin tener que recargar.
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "group_message_reads"
            filter("group_chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, groupChatId)
        }.onEach { insert ->
            val read = Json.decodeFromJsonElement(ReadRow.serializer(), insert.record)
            _reads.update { map ->
                val current = map[read.groupMessageId].orEmpty()
                if (read.userId in current) map
                else map + (read.groupMessageId to (current + read.userId))
            }
        }.launchIn(viewModelScope)

        // Reacciones en vivo -- inserciones y borrados de otros miembros
        // del grupo, sin tener que recargar. Mismo patrón exacto que
        // ChatViewModel.kt (chat 1:1).
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "group_message_reactions"
            filter("group_chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, groupChatId)
        }.onEach { insert ->
            val reaction = Json.decodeFromJsonElement(GroupMessageReaction.serializer(), insert.record)
            _reactions.update { map ->
                val current = map[reaction.groupMessageId].orEmpty()
                if (current.any { it.id == reaction.id }) map
                else map + (reaction.groupMessageId to (current + reaction))
            }
        }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Delete>(schema = "public") {
            table = "group_message_reactions"
            filter("group_chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, groupChatId)
        }.onEach { delete ->
            val id = delete.oldRecord["id"]?.toString()?.trim('"') ?: return@onEach
            _reactions.update { map -> map.mapValues { (_, list) -> list.filter { it.id != id } } }
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
