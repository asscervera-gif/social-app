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
import io.github.jan.supabase.realtime.broadcast
import io.github.jan.supabase.realtime.broadcastFlow
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.presenceChangeFlow
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
    // Nota de voz real (0062_group_message_audio.sql), comparado con
    // WhatsApp/Messenger/Telegram -- mismo campo separado que
    // ChatMessage.audioUrl (chat 1:1, 0019_message_audio.sql).
    @SerialName("audio_url") val audioUrl: String? = null,
    @SerialName("created_at") val createdAt: String = "",
    // Editar un mensaje ya enviado en un grupo (0065_group_messages_edit_delete.sql),
    // comparado con WhatsApp/Telegram/Messenger -- mismo campo separado
    // que ChatMessage.editedAt (chat 1:1, 0049_messages_edit.sql).
    @SerialName("edited_at") val editedAt: String? = null,
    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat.
    @SerialName("shared_post_id") val sharedPostId: String? = null,
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    @SerialName("is_forwarded") val isForwarded: Boolean = false,
    // Fijar un mensaje real (propio o ajeno) para que aparezca destacado
    // arriba del chat, VISIBLE PARA TODOS los miembros -- a diferencia de
    // starred_messages (totalmente privado), comparado con
    // WhatsApp/Telegram, ver 0089_pin_message.sql.
    @SerialName("pinned_at") val pinnedAt: String? = null,
    @SerialName("pinned_by") val pinnedBy: String? = null
)

/**
 * Hilo de un chat de grupo real -- mismo patrón que ChatViewModel.kt
 * (1:1). Reacciones (0060_group_message_reactions.sql), "visto por"
 * (0061_group_message_reads.sql), notas de voz
 * (0062_group_message_audio.sql) y fotos (media_url) reales. Mensajes en
 * vivo vía Realtime, mismo mecanismo ya usado en el chat 1:1
 * (`postgresChangeFlow`).
 */
class GroupChatViewModel(private val groupChatId: String) : ViewModel() {

    private val _messages = MutableStateFlow<List<GroupMessage>>(emptyList())
    val messages: StateFlow<List<GroupMessage>> = _messages.asStateFlow()

    private val _members = MutableStateFlow<List<Profile>>(emptyList())
    val members: StateFlow<List<Profile>> = _members.asStateFlow()

    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat -- vista previa real (miniatura + caption + autor)
    // de la publicación compartida, mismo patrón exacto que
    // ChatViewModel.kt.loadSharedPosts() (chat 1:1).
    private val _sharedPosts = MutableStateFlow<Map<String, com.social.app.backend.model.Post>>(emptyMap())
    val sharedPosts: StateFlow<Map<String, com.social.app.backend.model.Post>> = _sharedPosts.asStateFlow()

    private val _sharedPostAuthors = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val sharedPostAuthors: StateFlow<Map<String, Profile>> = _sharedPostAuthors.asStateFlow()

    private suspend fun loadSharedPosts(messages: List<GroupMessage>) {
        val postIds = messages.mapNotNull { it.sharedPostId }.filter { it !in _sharedPosts.value }.distinct()
        if (postIds.isEmpty()) return
        try {
            val posts = SupabaseManager.client.from("posts")
                .select { filter { isIn("id", postIds) } }
                .decodeList<com.social.app.backend.model.Post>()
            _sharedPosts.update { it + posts.associateBy { post -> post.id } }
            val authorIds = posts.map { it.authorId }.distinct()
            if (authorIds.isNotEmpty()) {
                val authors = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                        filter { isIn("id", authorIds) }
                    }
                    .decodeList<Profile>()
                _sharedPostAuthors.update { it + authors.associateBy { author -> author.id } }
            }
        } catch (e: Exception) {
            // Sin bloquear el resto del hilo si falla -- el mensaje sigue
            // mostrándose, solo sin la vista previa real de la publicación.
        }
    }

    // Nombre editable y foto de grupo real (0063_group_chat_photo.sql),
    // comparado con WhatsApp/Messenger/Telegram -- `group_chats_update_own`
    // (0057_group_chats.sql) ya dejaba al creador renombrar/poner foto,
    // pero ningún cliente lo llamaba nunca ni cargaba esta fila.
    private val _groupChat = MutableStateFlow<GroupChat?>(null)
    val groupChat: StateFlow<GroupChat?> = _groupChat.asStateFlow()

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

    // "En línea" y "escribiendo…" reales en un chat de grupo, comparado
    // con WhatsApp/Messenger -- mismo mecanismo exacto que
    // ChatViewModel.kt (chat 1:1): Presence/Broadcast de Realtime sobre el
    // mismo canal ya abierto para mensajes, sin tabla ni columna nueva. A
    // diferencia del 1:1 (un único "¿está en línea?"), aquí hace falta un
    // CONJUNTO de miembros -- puede haber varios a la vez viendo el grupo
    // o escribiendo.
    private val _onlineMemberIds = MutableStateFlow<Set<String>>(emptySet())
    val onlineMemberIds: StateFlow<Set<String>> = _onlineMemberIds.asStateFlow()

    private val _typingMemberIds = MutableStateFlow<Set<String>>(emptySet())
    val typingMemberIds: StateFlow<Set<String>> = _typingMemberIds.asStateFlow()
    private val typingClearJobs = mutableMapOf<String, kotlinx.coroutines.Job>()
    private var typingSendJob: kotlinx.coroutines.Job? = null

    @Serializable
    private data class PresenceState(@SerialName("user_id") val userId: String)

    @Serializable
    private data class TypingEvent(@SerialName("user_id") val userId: String)

    /** Llamado desde GroupChatScreen en cada pulsación del campo de texto
     * -- mismo debounce de 300ms ya usado en ChatViewModel.kt.notifyTyping(). */
    fun notifyTyping() {
        typingSendJob?.cancel()
        typingSendJob = viewModelScope.launch {
            kotlinx.coroutines.delay(300)
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                channel?.broadcast("typing", TypingEvent(myId))
            } catch (e: Exception) {
                // Sin conexión: no bloquear la escritura por esto.
            }
        }
    }

    private var channel: RealtimeChannel? = null

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                _messages.value = SupabaseManager.client.from("group_messages")
                    .select(columns = Columns.raw("id,group_chat_id,sender_id,body,media_url,audio_url,created_at,edited_at,shared_post_id,is_forwarded")) {
                        filter { eq("group_chat_id", groupChatId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<GroupMessage>()
                loadGroupChat()
                loadMembers()
                loadReactions()
                loadReads()
                loadSharedPosts(_messages.value)
                markUnreadAsRead()
                loadStarred()
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
        if (toMark.isNotEmpty()) {
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
        // Marcar como no leído manualmente (0088_mark_chat_unread.sql) y
        // la detección real de no leído en la lista de grupos se limpian
        // solas al volver a abrir el grupo de verdad, mismo criterio real
        // que el chat 1:1 (ChatViewModel.markMessagesRead()).
        try {
            SupabaseManager.client.from("group_chat_members").update({
                set("marked_unread", false)
                set("last_read_at", java.time.Instant.now().toString())
            }) {
                filter { eq("group_chat_id", groupChatId); eq("user_id", userId) }
            }
        } catch (e: Exception) {
            // No crítico: la próxima carga real de la lista reconcilia el
            // estado con el servidor.
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

    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql) -- totalmente privado, sobre CUALQUIER
    // mensaje de grupo (propio o ajeno).
    private val _starredMessageIds = MutableStateFlow<Set<String>>(emptySet())
    val starredMessageIds: StateFlow<Set<String>> = _starredMessageIds.asStateFlow()

    @Serializable
    private data class StarredGroupIdRow(@SerialName("group_message_id") val groupMessageId: String)

    private suspend fun loadStarred() {
        try {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
            // `starred_messages` no desnormaliza group_chat_id (a
            // diferencia de group_message_reactions) -- filtro por
            // user_id + isIn sobre los group_message_id ya cargados,
            // mismo criterio que ChatViewModel.kt.loadStarred() (1:1).
            val groupMessageIds = _messages.value.map { it.id }
            if (groupMessageIds.isEmpty()) return
            val rows = SupabaseManager.client.from("starred_messages")
                .select(columns = Columns.raw("group_message_id")) {
                    filter { eq("user_id", userId); isIn("group_message_id", groupMessageIds) }
                }
                .decodeList<StarredGroupIdRow>()
            _starredMessageIds.value = rows.map { it.groupMessageId }.toSet()
        } catch (e: Exception) {
            // No crítico: sin esto, el icono de destacado simplemente
            // arranca sin marcar nada hasta la próxima carga.
        }
    }

    @Serializable
    private data class NewStarredGroupMessage(
        @SerialName("user_id") val userId: String,
        @SerialName("group_message_id") val groupMessageId: String
    )

    /** Destacar/quitar destacado un mensaje de grupo real (propio o
     * ajeno), comparado con WhatsApp -- `starred_messages_insert_own` ya
     * comprueba del lado del servidor que soy de verdad miembro de este
     * grupo (0087_starred_messages.sql). */
    fun toggleStar(groupMessageId: String) {
        val currentlyStarred = _starredMessageIds.value.contains(groupMessageId)
        _starredMessageIds.update { if (currentlyStarred) it - groupMessageId else it + groupMessageId }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyStarred) {
                    SupabaseManager.client.from("starred_messages").delete {
                        filter { eq("user_id", userId); eq("group_message_id", groupMessageId) }
                    }
                } else {
                    SupabaseManager.client.from("starred_messages").insert(NewStarredGroupMessage(userId, groupMessageId))
                }
            } catch (e: Exception) {
                // Restricción unique(user_id, group_message_id): si ya
                // existía, el estado deseado ya se cumple.
            }
        }
    }

    /** Fijar/desfijar un mensaje de grupo real (propio o ajeno) para que
     * aparezca destacado arriba del chat, VISIBLE PARA TODOS los miembros
     * -- a diferencia de toggleStar() (totalmente privado), comparado con
     * WhatsApp/Telegram, ver 0089_pin_message.sql. El servidor no impone
     * "solo uno a la vez" -- el propio cliente desfija el anterior antes de
     * fijar uno nuevo (dos escrituras seguidas), mismo criterio que
     * ChatViewModel.togglePin() (chat 1:1). */
    fun togglePin(message: GroupMessage) {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
        val previouslyPinned = _messages.value.firstOrNull { it.pinnedAt != null && it.id != message.id }
        val nowPinning = message.pinnedAt == null
        val nowIso = java.time.Instant.now().toString()
        _messages.update { list ->
            list.map {
                when (it.id) {
                    message.id -> if (nowPinning) it.copy(pinnedAt = nowIso, pinnedBy = userId) else it.copy(pinnedAt = null, pinnedBy = null)
                    previouslyPinned?.id -> it.copy(pinnedAt = null, pinnedBy = null)
                    else -> it
                }
            }
        }
        viewModelScope.launch {
            try {
                if (nowPinning && previouslyPinned != null) {
                    SupabaseManager.client.from("group_messages")
                        .update({ set("pinned_at", null as String?); set("pinned_by", null as String?) }) { filter { eq("id", previouslyPinned.id) } }
                }
                if (nowPinning) {
                    SupabaseManager.client.from("group_messages")
                        .update({ set("pinned_at", nowIso); set("pinned_by", userId) }) { filter { eq("id", message.id) } }
                } else {
                    SupabaseManager.client.from("group_messages")
                        .update({ set("pinned_at", null as String?); set("pinned_by", null as String?) }) { filter { eq("id", message.id) } }
                }
            } catch (e: Exception) {
                // No expone _errorMessage propio en este ViewModel para
                // este tipo de fallo -- mismo criterio silencioso ya usado
                // en toggleStar() de más arriba.
            }
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

    private suspend fun loadGroupChat() {
        try {
            _groupChat.value = SupabaseManager.client.from("group_chats")
                .select(columns = Columns.raw("id,name,created_by,created_at,photo_url")) {
                    filter { eq("id", groupChatId) }
                }
                .decodeSingle<GroupChat>()
        } catch (e: Exception) {
            // Sin bloquear el resto del hilo si falla -- el nombre pasado
            // por navegación (groupName) sigue sirviendo de respaldo.
        }
    }

    @Serializable
    private data class GroupChatUpdate(
        val name: String? = null,
        @SerialName("photo_url") val photoUrl: String? = null
    )

    /** Renombrar el grupo real, comparado con WhatsApp/Messenger/Telegram
     * -- RLS (`group_chats_update_own`, 0057_group_chats.sql) ya limitaba
     * esto al creador; aquí se intenta igual para cualquiera y se deja
     * que el servidor decida (0 filas afectadas y sin error si no eres el
     * creador, mismo comportamiento ya confirmado en test_rls.mjs). */
    fun renameGroup(newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty() || trimmed.length > 100) return
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("group_chats").update(GroupChatUpdate(name = trimmed)) {
                    filter { eq("id", groupChatId) }
                }
                _groupChat.update { it?.copy(name = trimmed) }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo renombrar el grupo."
            }
        }
    }

    /** Foto de grupo real -- reutiliza tal cual `StorageUploader.uploadImage`
     * ya construido para fotos de chat, sin infraestructura nueva. */
    fun updatePhoto(context: android.content.Context, uri: android.net.Uri) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadImage(context, uri, userId)
                SupabaseManager.client.from("group_chats").update(GroupChatUpdate(photoUrl = url)) {
                    filter { eq("id", groupChatId) }
                }
                _groupChat.update { it?.copy(photoUrl = url) }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar la foto del grupo."
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
                loadSharedPosts(listOf(message))
                // El chat sigue abierto -- un mensaje que llega en vivo se
                // marca leído igual que uno cargado al abrir el hilo.
                markUnreadAsRead()
            }
        }.launchIn(viewModelScope)

        // Editar un mensaje ya enviado en un grupo real
        // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
        // Telegram/Messenger -- mismo patrón exacto que ChatViewModel.kt
        // (chat 1:1): cualquier UPDATE de la fila reemplaza la copia local.
        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "group_messages"
            filter("group_chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, groupChatId)
        }.onEach { update ->
            val updated = Json.decodeFromJsonElement(GroupMessage.serializer(), update.record)
            _messages.update { list -> list.map { if (it.id == updated.id) updated else it } }
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

        // "En línea" real -- mismo patrón exacto que ChatViewModel.kt
        // (chat 1:1), aquí como un CONJUNTO de miembros (puede haber
        // varios viendo el grupo a la vez).
        ch.presenceChangeFlow().onEach { action ->
            fun decode(p: io.github.jan.supabase.realtime.Presence) = try {
                Json.decodeFromJsonElement(PresenceState.serializer(), p.state).userId
            } catch (e: Exception) {
                null
            }
            val joined = action.joins.values.mapNotNull(::decode)
            val left = action.leaves.values.mapNotNull(::decode)
            _onlineMemberIds.update { current -> (current + joined) - left.toSet() }
        }.launchIn(viewModelScope)

        viewModelScope.launch {
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                ch.track(Json.encodeToJsonElement(PresenceState.serializer(), PresenceState(myId)).let {
                    it as kotlinx.serialization.json.JsonObject
                })
            } catch (e: Exception) {
                // Sin presencia no se rompe el resto del chat.
            }
        }

        // "Escribiendo…" real -- mismo patrón exacto que ChatViewModel.kt
        // (chat 1:1): sin evento explícito de "dejé de escribir" (WhatsApp
        // hace lo mismo), se apaga sola si esa persona no manda otro
        // broadcast en 3s -- un job de apagado POR PERSONA, a diferencia
        // del 1:1 que solo necesita uno.
        ch.broadcastFlow<TypingEvent>("typing").onEach { event ->
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            if (event.userId == myId) return@onEach
            _typingMemberIds.update { it + event.userId }
            typingClearJobs[event.userId]?.cancel()
            typingClearJobs[event.userId] = viewModelScope.launch {
                kotlinx.coroutines.delay(3000)
                _typingMemberIds.update { it - event.userId }
            }
        }.launchIn(viewModelScope)

        viewModelScope.launch { ch.subscribe() }
    }

    @Serializable
    private data class NewGroupMessage(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String? = null,
        @SerialName("media_url") val mediaUrl: String? = null,
        @SerialName("audio_url") val audioUrl: String? = null
    )

    /** Borrar el propio mensaje en un grupo real
     * (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
     * Telegram/Messenger -- "borrar para todos", mismo criterio simple
     * que ChatViewModel.kt.deleteMessage() (chat 1:1). */
    fun deleteMessage(messageId: String) {
        _messages.update { list -> list.filter { it.id != messageId } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("group_messages").delete { filter { eq("id", messageId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar el mensaje."
            }
        }
    }

    /** Editar un mensaje ya enviado en un grupo real
     * (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
     * Telegram/Messenger -- mismo límite de 2000 caracteres y sin ventana
     * de tiempo límite, mismo criterio que ChatViewModel.kt.editMessage()
     * (chat 1:1). */
    fun editMessage(messageId: String, newBody: String) {
        if (newBody.isEmpty() || newBody.length > 2000) return
        val nowIso = java.time.Instant.now().toString()
        _messages.update { list ->
            list.map { if (it.id == messageId) it.copy(body = newBody, editedAt = nowIso) else it }
        }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("group_messages")
                    .update({ set("body", newBody); set("edited_at", nowIso) }) { filter { eq("id", messageId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo editar el mensaje."
            }
        }
    }

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
                    .insert(NewGroupMessage(groupChatId, userId, body = text)) { select() }
                    .decodeSingle<GroupMessage>()
                if (_messages.value.none { it.id == inserted.id }) {
                    _messages.update { it + inserted }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el mensaje."
            }
        }
    }

    /** Fotos en un chat de grupo, comparado con WhatsApp/Instagram/
     * Messenger/Facebook -- `group_messages.media_url` ya existía en el
     * esquema desde 0057_group_chats.sql, solo faltaba la UI. Reutiliza
     * tal cual `StorageUploader.uploadImage` ya construido para el chat
     * 1:1, sin infraestructura nueva. Equivalente de
     * ChatViewModel.kt.sendPhoto(). */
    fun sendPhoto(context: android.content.Context, uri: android.net.Uri) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadImage(context, uri, userId)
                val inserted = SupabaseManager.client.from("group_messages")
                    .insert(NewGroupMessage(groupChatId, userId, mediaUrl = url)) { select() }
                    .decodeSingle<GroupMessage>()
                if (_messages.value.none { it.id == inserted.id }) {
                    _messages.update { it + inserted }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la foto."
            }
        }
    }

    /** Nota de voz real en un chat de grupo (0062_group_message_audio.sql),
     * comparado con WhatsApp/Messenger/Telegram -- reutiliza tal cual
     * `VoiceRecorder`/`StorageUploader.uploadAudioFile` ya construidos
     * para el chat 1:1, sin infraestructura nueva. Equivalente de
     * ChatViewModel.kt.sendVoiceNote(). */
    fun sendVoiceNote(file: java.io.File) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadAudioFile(file, userId)
                val inserted = SupabaseManager.client.from("group_messages")
                    .insert(NewGroupMessage(groupChatId, userId, audioUrl = url)) { select() }
                    .decodeSingle<GroupMessage>()
                if (_messages.value.none { it.id == inserted.id }) {
                    _messages.update { it + inserted }
                }
                file.delete()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la nota de voz."
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

    /** Expulsar a otro miembro real, comparado con WhatsApp/Messenger/
     * Telegram -- solo el creador puede (RLS
     * `group_chat_members_delete_by_creator`, 0066_group_chat_kick_member.sql,
     * mismo rol de "admin" ya usado para renombrar/silenciar el grupo). El
     * servidor decide de verdad: si quien llama no es el creador, la fila
     * simplemente no se borra (0 filas afectadas), por eso se recarga la
     * lista de miembros después en vez de asumir éxito. */
    fun kickMember(profileId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("group_chat_members").delete {
                    filter { eq("group_chat_id", groupChatId); eq("user_id", profileId) }
                }
                loadMembers()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo expulsar del grupo."
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
