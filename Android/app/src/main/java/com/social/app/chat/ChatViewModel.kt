package com.social.app.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Chat
import com.social.app.backend.model.ChatMessage
import io.github.jan.supabase.functions.functions
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
import io.ktor.client.statement.bodyAsText
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

/**
 * Chat en tiempo real vía Supabase Realtime, con barra de compatibilidad —
 * equivalente Kotlin de ChatViewModel.swift. Mismo patrón: canal por chat
 * (`chat-{chatId}`), no un canal global, para no saturar con tráfico ajeno
 * (ver scaling_notes.md sobre límites de conexiones Realtime a escala).
 */
class ChatViewModel(private val chatId: String) : ViewModel() {

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()

    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- mensaje real que se está
    // citando ahora mismo en el compositor, ver 0102_message_reply.sql.
    private val _replyingTo = MutableStateFlow<ChatMessage?>(null)
    val replyingTo: StateFlow<ChatMessage?> = _replyingTo.asStateFlow()

    fun setReplyingTo(message: ChatMessage?) {
        _replyingTo.value = message
    }

    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat -- vista previa real
    // (miniatura + caption + autor) de la publicación compartida en un
    // mensaje, cargada por lotes a partir de los shared_post_id presentes
    // en los mensajes ya cargados, mismo patrón que loadMembers() en
    // GroupChatViewModel.kt.
    private val _sharedPosts = MutableStateFlow<Map<String, com.social.app.backend.model.Post>>(emptyMap())
    val sharedPosts: StateFlow<Map<String, com.social.app.backend.model.Post>> = _sharedPosts.asStateFlow()

    private val _sharedPostAuthors = MutableStateFlow<Map<String, com.social.app.backend.model.Profile>>(emptyMap())
    val sharedPostAuthors: StateFlow<Map<String, com.social.app.backend.model.Profile>> = _sharedPostAuthors.asStateFlow()

    private suspend fun loadSharedPosts(messages: List<ChatMessage>) {
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
                    .decodeList<com.social.app.backend.model.Profile>()
                _sharedPostAuthors.update { it + authors.associateBy { author -> author.id } }
            }
        } catch (e: Exception) {
            // Sin bloquear el resto del chat si falla -- el mensaje sigue
            // mostrándose, solo sin la vista previa real de la publicación.
        }
    }

    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat -- vista previa real
    // (miniatura) de la historia respondida en un mensaje, cargada por
    // lotes, mismo patrón exacto que loadSharedPosts() de arriba. Sin
    // autor propio: en un chat 1:1, la historia referenciada es siempre de
    // uno de los dos participantes ya conocidos (mío o del otro), así que
    // el texto de la burbuja ("Respondiste"/"Respondió a tu historia") se
    // decide comparando message.senderId con myId, sin otra consulta.
    private val _storyPreviews = MutableStateFlow<Map<String, StoryPreview>>(emptyMap())
    val storyPreviews: StateFlow<Map<String, StoryPreview>> = _storyPreviews.asStateFlow()

    @Serializable
    data class StoryPreview(val id: String, @SerialName("media_url") val mediaUrl: String)

    private suspend fun loadStoryPreviews(messages: List<ChatMessage>) {
        val storyIds = messages.mapNotNull { it.storyId }.filter { it !in _storyPreviews.value }.distinct()
        if (storyIds.isEmpty()) return
        try {
            val stories = SupabaseManager.client.from("stories")
                .select(columns = Columns.raw("id,media_url")) { filter { isIn("id", storyIds) } }
                .decodeList<StoryPreview>()
            _storyPreviews.update { it + stories.associateBy { story -> story.id } }
        } catch (e: Exception) {
            // Historia real ya caducada/borrada (stories_select filtra
            // expires_at > now(), 0002_rls.sql) -- comportamiento CORRECTO
            // y esperado, no un fallo: el mensaje sigue mostrándose, solo
            // sin la vista previa de la historia ya no disponible.
        }
    }

    private val _compatibility = MutableStateFlow(50)
    val compatibility: StateFlow<Int> = _compatibility.asStateFlow()

    // Mensajes que desaparecen real, comparado con WhatsApp/Instagram DM
    // -- null = desactivado, en segundos si está activo. Ver
    // 0115_disappearing_messages.sql.
    private val _disappearingSeconds = MutableStateFlow<Int?>(null)
    val disappearingSeconds: StateFlow<Int?> = _disappearingSeconds.asStateFlow()

    private val _opponentId = MutableStateFlow<String?>(null)
    val opponentId: StateFlow<String?> = _opponentId.asStateFlow()

    // Recibo de lectura real ("Leído ✓✓"), comparado con WhatsApp/
    // Instagram/Messenger -- mismo criterio recíproco real que esas apps:
    // si CUALQUIERA de los dos (yo o la otra persona) desactivó su propio
    // recibo, no se pinta "Leído" para ninguno de los dos lados, aunque
    // `read_at` siga marcándose igual que siempre por debajo (sigue
    // haciendo falta para el propio recuento de "no leídos" del
    // destinatario, 0088). Ver 0091_read_receipts_toggle.sql.
    private val _showReadReceipts = MutableStateFlow(true)
    val showReadReceipts: StateFlow<Boolean> = _showReadReceipts.asStateFlow()

    private val _suggestedActivity = MutableStateFlow<String?>(null)
    val suggestedActivity: StateFlow<String?> = _suggestedActivity.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Paginación hacia atrás -- hueco real documentado desde que loadHistory()
    // se limitó a los últimos 100 mensajes (ver comentario ahí): sin esto, un
    // chat con más de 100 mensajes perdía silenciosamente todo lo anterior,
    // sin forma de volver a verlo.
    private val _isLoadingOlder = MutableStateFlow(false)
    val isLoadingOlder: StateFlow<Boolean> = _isLoadingOlder.asStateFlow()

    private val _hasMoreHistory = MutableStateFlow(false)
    val hasMoreHistory: StateFlow<Boolean> = _hasMoreHistory.asStateFlow()

    private val olderPageSize = 50L

    // Última pieza real de "chat funcional con fotos, voz, reacciones,
    // read receipts" alcanzable sin infraestructura mayor — solo queda voz
    // (grabación nativa, alcance propio, documentado aparte).
    private val _reactions = MutableStateFlow<Map<String, List<MessageReaction>>>(emptyMap())
    val reactions: StateFlow<Map<String, List<MessageReaction>>> = _reactions.asStateFlow()

    private var channel: RealtimeChannel? = null

    // "En línea" — comparado con WhatsApp/Instagram DM, no había ninguna
    // señal de si la otra persona tiene el chat abierto ahora mismo. Se
    // usa Presence de Realtime (efímero, mismo canal `chat-{chatId}`):
    // "en línea" significa "tiene esta conversación abierta", no "tiene
    // la app abierta en algún sitio" — alcance deliberadamente acotado al
    // chat, sin un sistema de presencia global de toda la app.
    private val _isOpponentOnline = MutableStateFlow(false)
    val isOpponentOnline: StateFlow<Boolean> = _isOpponentOnline.asStateFlow()

    @Serializable
    private data class PresenceState(@SerialName("user_id") val userId: String)

    // "Escribiendo..." — comparado con WhatsApp/Instagram DM, no había
    // ninguna señal de que la otra persona está escribiendo. Se usa
    // Broadcast de Realtime (efímero, sin tabla ni columna nueva) sobre el
    // mismo canal `chat-{chatId}` ya abierto para mensajes/reacciones —
    // nadie más que los miembros de este chat puede verlo.
    private val _isOpponentTyping = MutableStateFlow(false)
    val isOpponentTyping: StateFlow<Boolean> = _isOpponentTyping.asStateFlow()
    private var typingClearJob: kotlinx.coroutines.Job? = null
    private var typingSendJob: kotlinx.coroutines.Job? = null

    @Serializable
    private data class TypingEvent(@SerialName("user_id") val userId: String)

    /** Llamado desde ChatScreen en cada pulsación del campo de texto — con
     * el mismo debounce de 300ms ya usado en SearchViewModel.kt para no
     * saturar la red con un broadcast por letra tecleada. */
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

    fun start() {
        viewModelScope.launch {
            loadHistory()
            subscribeToRealtime()
            markMessagesRead()
            markMessageNotificationsRead()
            loadReactions()
            loadStarred()
            loadOpponentLastActive()
            // "Últ. vez hace...", comparado con WhatsApp -- heurística
            // real de actividad: abrir un chat cuenta como "usando la
            // app ahora mismo". Alcance deliberado: sin interruptor de
            // privacidad recíproco todavía (0119_last_active_at.sql).
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("last_active_at", java.time.Instant.now().toString()) }) { filter { eq("id", userId) } }
            } catch (e: Exception) { /* no crítico */ }
        }
    }

    private val _opponentLastActiveAt = MutableStateFlow<String?>(null)
    val opponentLastActiveAt: StateFlow<String?> = _opponentLastActiveAt.asStateFlow()

    @Serializable
    private data class LastActiveRow(
        val id: String? = null,
        @SerialName("last_active_at") val lastActiveAt: String? = null,
        @SerialName("share_last_active") val shareLastActive: Boolean = true
    )

    /** Interruptor recíproco de privacidad para "Últ. vez", comparado con
     * WhatsApp/Telegram -- cierra el hueco deliberado documentado en
     * 0119_last_active_at.sql. Mismo criterio real que
     * loadReadReceiptsVisibility(): si CUALQUIERA de los dos apagó su
     * propia share_last_active, no se pinta "Últ. vez" en ningún sentido.
     * Ver 0122_last_active_privacy_toggle.sql. */
    private suspend fun loadOpponentLastActive() {
        try {
            val chat = SupabaseManager.client.from("chats")
                .select { filter { eq("id", chatId) } }
                .decodeSingle<Chat>()
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
            val opponent = if (chat.userAId == myId) chat.userBId else chat.userAId
            val rows = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,last_active_at,share_last_active")) { filter { isIn("id", listOf(myId, opponent)) } }
                .decodeList<LastActiveRow>()
            _opponentLastActiveAt.value = if (rows.all { it.shareLastActive }) {
                SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("last_active_at")) { filter { eq("id", opponent) } }
                    .decodeSingleOrNull<LastActiveRow>()?.lastActiveAt
            } else null
        } catch (e: Exception) { /* no crítico */ }
    }

    @Serializable
    private data class ReadReceiptsRow(
        val id: String,
        @SerialName("read_receipts_enabled") val readReceiptsEnabled: Boolean
    )

    /** Igual que WhatsApp/Instagram/Messenger: si CUALQUIERA de los dos
     * (yo o la otra persona) desactivó su propio recibo de lectura, no se
     * pinta "Leído" en ninguno de los dos sentidos -- ver
     * 0091_read_receipts_toggle.sql. */
    private suspend fun loadReadReceiptsVisibility(myId: String?, opponentId: String?) {
        if (myId == null || opponentId == null) return
        try {
            val rows = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,read_receipts_enabled")) { filter { isIn("id", listOf(myId, opponentId)) } }
                .decodeList<ReadReceiptsRow>()
            _showReadReceipts.value = rows.all { it.readReceiptsEnabled }
        } catch (e: Exception) {
            // No crítico: si falla, se queda en el valor por defecto (true).
        }
    }

    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql) -- totalmente privado, sobre CUALQUIER
    // mensaje (propio o ajeno).
    private val _starredMessageIds = MutableStateFlow<Set<String>>(emptySet())
    val starredMessageIds: StateFlow<Set<String>> = _starredMessageIds.asStateFlow()

    @Serializable
    private data class StarredIdRow(@SerialName("message_id") val messageId: String)

    private suspend fun loadStarred() {
        try {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
            val messageIds = _messages.value.map { it.id }
            if (messageIds.isEmpty()) return
            val rows = SupabaseManager.client.from("starred_messages")
                .select(columns = Columns.raw("message_id")) {
                    filter { eq("user_id", userId); isIn("message_id", messageIds) }
                }
                .decodeList<StarredIdRow>()
            _starredMessageIds.value = rows.map { it.messageId }.toSet()
        } catch (e: Exception) {
            // No crítico: sin esto, el icono de destacado simplemente
            // arranca sin marcar nada hasta la próxima carga.
        }
    }

    @Serializable
    private data class NewStarredMessage(
        @SerialName("user_id") val userId: String,
        @SerialName("message_id") val messageId: String
    )

    /** Destacar/quitar destacado un mensaje real (propio o ajeno),
     * comparado con WhatsApp -- `starred_messages_insert_own` ya
     * comprueba del lado del servidor que soy de verdad parte de este
     * chat (0087_starred_messages.sql). */
    fun toggleStar(messageId: String) {
        val currentlyStarred = _starredMessageIds.value.contains(messageId)
        _starredMessageIds.update { if (currentlyStarred) it - messageId else it + messageId }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyStarred) {
                    SupabaseManager.client.from("starred_messages").delete {
                        filter { eq("user_id", userId); eq("message_id", messageId) }
                    }
                } else {
                    SupabaseManager.client.from("starred_messages").insert(NewStarredMessage(userId, messageId))
                }
            } catch (e: Exception) {
                // Restricción unique(user_id, message_id): si ya existía,
                // el estado deseado ya se cumple, mismo criterio que
                // toggleCommentLike().
            }
        }
    }

    /** Fijar/desfijar un mensaje real (propio o ajeno) para que aparezca
     * destacado arriba del chat, VISIBLE PARA TODOS los participantes -- a
     * diferencia de toggleStar() (totalmente privado), comparado con
     * WhatsApp/Telegram, ver 0089_pin_message.sql. El servidor no impone
     * "solo uno a la vez" -- el propio cliente desfija el anterior antes de
     * fijar uno nuevo (dos escrituras seguidas), mismo criterio ya usado en
     * otras rondas de "el cliente orquesta, el servidor solo protege
     * identidad". */
    fun togglePin(message: ChatMessage) {
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
                    SupabaseManager.client.from("messages")
                        .update({ set("pinned_at", null as String?); set("pinned_by", null as String?) }) { filter { eq("id", previouslyPinned.id) } }
                }
                if (nowPinning) {
                    SupabaseManager.client.from("messages")
                        .update({ set("pinned_at", nowIso); set("pinned_by", userId) }) { filter { eq("id", message.id) } }
                } else {
                    SupabaseManager.client.from("messages")
                        .update({ set("pinned_at", null as String?); set("pinned_by", null as String?) }) { filter { eq("id", message.id) } }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo fijar el mensaje."
            }
        }
    }

    @Serializable
    private data class MessageNotifRow(
        val id: String,
        val payload: Map<String, String>,
        @SerialName("read_at") val readAt: String? = null
    )

    /** Hallazgo real, el hueco de mensajería más grande de la sesión:
     * ningún mensaje nuevo generaba nunca un aviso -- ver
     * 0047_message_notify_mute.sql. Sin esto, el badge de Avisos
     * acumularía avisos de mensajes que el usuario ya vio aquí mismo, en
     * el propio chat. Dos pasos (traer + filtrar en cliente + actualizar
     * por id) en vez de filtrar por `payload->>chat_id` directo en el
     * servidor -- sin precedente verificado de filtro sobre una columna
     * jsonb en este proyecto, mismo criterio de no adivinar una sintaxis
     * no probada que ya se aplica al resto del código. */
    private suspend fun markMessageNotificationsRead() {
        try {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
            val rows = SupabaseManager.client.from("notifications")
                .select(columns = Columns.raw("id,payload,read_at")) {
                    filter {
                        eq("kind", "message")
                        eq("recipient_id", userId)
                    }
                    limit(200)
                }
                .decodeList<MessageNotifRow>()
            val matchingIds = rows.filter { it.readAt == null && it.payload["chat_id"] == chatId }.map { it.id }
            if (matchingIds.isEmpty()) return
            val nowIso = java.time.Instant.now().toString()
            SupabaseManager.client.from("notifications")
                .update({ set("read_at", nowIso) }) { filter { isIn("id", matchingIds) } }
        } catch (e: Exception) {
            // No bloquea el resto del chat si falla.
        }
    }

    @Serializable
    data class MessageReaction(
        val id: String,
        @SerialName("message_id") val messageId: String,
        @SerialName("user_id") val userId: String,
        val emoji: String
    )

    private suspend fun loadReactions() {
        try {
            // Filtro directo por chat_id (desnormalizado en la tabla) en
            // vez de `isIn` sobre una lista de message_id — sin precedente
            // verificado en este proyecto, mismo criterio que otros
            // filtros no probados.
            val rows = SupabaseManager.client.from("message_reactions")
                .select { filter { eq("chat_id", chatId) } }
                .decodeList<MessageReaction>()
            _reactions.value = rows.groupBy { it.messageId }
        } catch (e: Exception) {
            // Sin bloquear el resto del chat si falla.
        }
    }

    /** Toggle: si ya reaccionaste con ese emoji a ese mensaje, lo quita;
     * si no, lo añade. `unique(message_id, user_id, emoji)` en
     * 0018_message_reactions.sql es la fuente de verdad real. */
    fun toggleReaction(messageId: String, emoji: String) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            val existing = _reactions.value[messageId]?.firstOrNull { it.userId == userId && it.emoji == emoji }
            try {
                if (existing != null) {
                    SupabaseManager.client.from("message_reactions").delete { filter { eq("id", existing.id) } }
                    _reactions.update { map ->
                        map + (messageId to (map[messageId].orEmpty().filter { it.id != existing.id }))
                    }
                } else {
                    val inserted = SupabaseManager.client.from("message_reactions")
                        .insert(NewReaction(messageId, chatId, userId, emoji)) { select() }
                        .decodeSingle<MessageReaction>()
                    _reactions.update { map ->
                        map + (messageId to (map[messageId].orEmpty() + inserted))
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo reaccionar."
            }
        }
    }

    @Serializable
    private data class NewReaction(
        @SerialName("message_id") val messageId: String,
        @SerialName("chat_id") val chatId: String,
        @SerialName("user_id") val userId: String,
        val emoji: String
    )

    /** Última pieza real de "chat funcional con fotos, voz, reacciones,
     * read receipts" alcanzable sin infraestructura nueva — mismo patrón
     * que AvisosViewModel.markRead(). `messages_update_read`
     * (0017_message_read_receipts.sql) solo deja marcar como leídos los
     * mensajes ajenos, nunca los propios. */
    private suspend fun markMessagesRead() {
        try {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
            val nowIso = java.time.Instant.now().toString()
            // Sin `isNull` verificado en el resto del código — marcar de
            // nuevo un mensaje ya leído es idempotente (mismo `read_at`
            // final en la práctica), así que no hace falta filtrar por
            // null, mismo criterio que otros filtros no probados aquí.
            SupabaseManager.client.from("messages")
                .update({ set("read_at", nowIso); set("delivered_at", nowIso) }) {
                    filter {
                        eq("chat_id", chatId)
                        neq("sender_id", userId)
                    }
                }
            _messages.update { list ->
                list.map { if (it.senderId != userId && it.readAt == null) it.copy(readAt = nowIso, deliveredAt = it.deliveredAt ?: nowIso) else it }
            }
            // Marcar como no leído manualmente (0088_mark_chat_unread.sql)
            // se limpia solo al volver a abrir el chat de verdad, mismo
            // criterio real que WhatsApp. Escribir `false` en las DOS
            // columnas a la vez es seguro sin saber si soy user_a o
            // user_b: `protect_chat_unread_flags` ya revierte en
            // silencio la columna ajena, dejando pasar solo la propia --
            // mismo contrato ya verificado en test_rls.mjs.
            SupabaseManager.client.from("chats")
                .update({
                    set("marked_unread_by_a", false)
                    set("marked_unread_by_b", false)
                }) { filter { eq("id", chatId) } }
        } catch (e: Exception) {
            // No es crítico si falla: los mensajes simplemente no se
            // marcan como leídos, sin romper el resto del chat.
        }
    }

    fun stop() {
        viewModelScope.launch { channel?.unsubscribe() }
    }

    private suspend fun loadHistory() {
        try {
            // Hallazgo real de escalabilidad: sin límite, abrir un chat
            // largo traía el historial ENTERO cada vez — mismo patrón de
            // `.limit()` ya usado en el resto del proyecto (Home/Match/
            // Search/etc). Se piden los últimos 100 en orden descendente y
            // se invierten para mostrar cronológicamente — un `limit()`
            // con orden ascendente traería los 100 MÁS ANTIGUOS, no los
            // recientes, que es lo que de verdad se quiere ver al abrir un
            // chat. Paginar hacia atrás sí está construido -- ver
            // loadOlderMessages() más abajo, cableado desde ChatScreen.kt.
            val recent = SupabaseManager.client.from("messages")
                .select {
                    filter { eq("chat_id", chatId) }
                    order("created_at", Order.DESCENDING)
                    limit(100)
                }
                .decodeList<ChatMessage>()
            _hasMoreHistory.value = recent.size >= 100
            _messages.value = recent.reversed()
            loadSharedPosts(_messages.value)
            loadStoryPreviews(_messages.value)

            val chat = SupabaseManager.client.from("chats")
                .select { filter { eq("id", chatId) } }
                .decodeSingle<Chat>()
            _compatibility.value = chat.compatibilityScore
            _disappearingSeconds.value = chat.disappearingSeconds

            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            _opponentId.value = when (myId) {
                chat.userAId -> chat.userBId
                chat.userBId -> chat.userAId
                else -> null
            }
            loadReadReceiptsVisibility(myId, _opponentId.value)
            checkActivitySuggestion()
            if (_messages.value.isEmpty()) loadIcebreaker()
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo cargar el chat: ${e.message}"
        }
    }

    /** "Cargar mensajes anteriores" -- pide la página de mensajes justo antes
     * del más antiguo ya cargado (mismo criterio de orden que loadHistory()),
     * y la antepone a la lista actual. `_hasMoreHistory` se pone a `false` en
     * cuanto una página vuelve incompleta, para dejar de mostrar el botón. */
    fun loadOlderMessages() {
        if (_isLoadingOlder.value || !_hasMoreHistory.value) return
        val oldest = _messages.value.firstOrNull()?.createdAt ?: return
        _isLoadingOlder.value = true
        viewModelScope.launch {
            try {
                val older = SupabaseManager.client.from("messages")
                    .select {
                        filter {
                            eq("chat_id", chatId)
                            lt("created_at", oldest)
                        }
                        order("created_at", Order.DESCENDING)
                        limit(olderPageSize)
                    }
                    .decodeList<ChatMessage>()
                _hasMoreHistory.value = older.size >= olderPageSize
                _messages.value = older.reversed() + _messages.value
                loadSharedPosts(older)
                loadStoryPreviews(older)
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar mensajes anteriores."
            } finally {
                _isLoadingOlder.value = false
            }
        }
    }

    @Serializable
    private data class IcebreakerRequest(@SerialName("chatId") val chatId: String)

    @Serializable
    private data class IcebreakerResponse(val message: String? = null)

    private val _icebreaker = MutableStateFlow<String?>(null)
    val icebreaker: StateFlow<String?> = _icebreaker.asStateFlow()

    /** "Potenciar la IA" (petición explícita del usuario), comparado con
     * Hinge ("Your Turn")/Bumble ("Opening Move"): un chat nuevo (social
     * aceptado, sin mensajes todavía) se quedaba con el campo de texto
     * vacío, sin ninguna ayuda real para arrancar la conversación. Se
     * pide una sugerencia real a `icebreaker-ai` (mismo patrón que
     * `duel-ai`/`activity-ai`) — efímera, no se persiste en ninguna
     * tabla, y solo se pide cuando el chat está realmente vacío. */
    fun loadIcebreaker() {
        viewModelScope.launch {
            try {
                val response = SupabaseManager.client.functions.invoke("icebreaker-ai", body = IcebreakerRequest(chatId))
                _icebreaker.value = Json.decodeFromString<IcebreakerResponse>(response.bodyAsText()).message
            } catch (e: Exception) {
                // Sin IA disponible no se rompe el resto del chat —
                // simplemente no se muestra ninguna sugerencia de apertura.
            }
        }
    }

    /** Usar la sugerencia como borrador — el usuario sigue pudiendo
     * editarla antes de enviar, nunca se manda sola. */
    fun dismissIcebreaker() {
        _icebreaker.value = null
    }

    @Serializable
    private data class ActivityRow(val suggestion: String)

    /** Equivalente de ChatViewModel.swift.checkActivitySuggestion — antes
     * ChatScreen.kt mostraba un texto fijo hardcodeado en vez de consultar
     * la tabla `activities` real (generada por IA en Fase 6, fuera de
     * alcance aquí; solo se lee lo ya guardado). */
    @Serializable
    private data class ActivityRequest(@SerialName("chatId") val chatId: String)

    @Serializable
    private data class ActivityResponse(val suggestion: String? = null)

    /** Hallazgo real (cerrado esta pasada): esta función siempre consultó
     * `activities` de verdad, pero NADA insertaba en esa tabla en ningún
     * sitio — el campo "✨ Actividad sugerida" estaba conectado a un pozo
     * vacío desde que se construyó. Ahora, si la compatibilidad supera el
     * 50% y no hay ninguna fila todavía, se genera una de verdad con IA
     * (Edge Function `activity-ai`, mismo patrón que `duel-ai`: la clave
     * de Anthropic nunca sale del servidor). */
    private suspend fun checkActivitySuggestion() {
        if (_compatibility.value <= 50) {
            _suggestedActivity.value = null
            return
        }
        val existing = try {
            SupabaseManager.client.from("activities")
                .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("suggestion")) {
                    filter { eq("chat_id", chatId) }
                    order("created_at", Order.DESCENDING)
                    limit(1)
                }
                .decodeSingleOrNull<ActivityRow>()
                ?.suggestion
        } catch (e: Exception) {
            null
        }
        if (existing != null) {
            _suggestedActivity.value = existing
            return
        }
        _suggestedActivity.value = try {
            val response = SupabaseManager.client.functions.invoke("activity-ai", body = ActivityRequest(chatId))
            Json.decodeFromString<ActivityResponse>(response.bodyAsText()).suggestion
        } catch (e: Exception) {
            // Sin IA disponible (límite de uso, red...) no se rompe el
            // resto del chat — simplemente no se muestra sugerencia.
            null
        }
    }

    private fun subscribeToRealtime() {
        val ch = SupabaseManager.client.realtime.channel("chat-$chatId")
        channel = ch

        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "messages"
            filter("chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { insert ->
            val message = Json.decodeFromJsonElement(ChatMessage.serializer(), insert.record)
            _messages.update { it + message }
            loadSharedPosts(listOf(message))
            loadStoryPreviews(listOf(message))
            // Entregado real (0117): en cuanto llega en vivo a MI
            // dispositivo (aunque no haya abierto el chat), comparado
            // con WhatsApp (✓✓ gris antes de leer).
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            if (myId != null && message.senderId != myId) {
                viewModelScope.launch {
                    try {
                        SupabaseManager.client.from("messages")
                            .update({ set("delivered_at", java.time.Instant.now().toString()) }) { filter { eq("id", message.id) } }
                    } catch (e: Exception) { /* no crítico */ }
                }
            }
        }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "chats"
            filter("id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { update ->
            val chat = Json.decodeFromJsonElement(Chat.serializer(), update.record)
            _compatibility.value = chat.compatibilityScore
            _disappearingSeconds.value = chat.disappearingSeconds
        }.launchIn(viewModelScope)

        // Para que el remitente vea "Leído" en vivo cuando la otra persona
        // marca sus mensajes como leídos, sin tener que recargar el chat.
        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "messages"
            filter("chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { update ->
            val updated = Json.decodeFromJsonElement(ChatMessage.serializer(), update.record)
            _messages.update { list -> list.map { if (it.id == updated.id) updated else it } }
        }.launchIn(viewModelScope)

        // Reacciones en vivo — inserciones y borrados de otros miembros del
        // chat, sin tener que recargar.
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "message_reactions"
            filter("chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { insert ->
            val reaction = Json.decodeFromJsonElement(MessageReaction.serializer(), insert.record)
            _reactions.update { map ->
                val current = map[reaction.messageId].orEmpty()
                if (current.any { it.id == reaction.id }) map
                else map + (reaction.messageId to (current + reaction))
            }
        }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Delete>(schema = "public") {
            table = "message_reactions"
            filter("chat_id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { delete ->
            val id = delete.oldRecord["id"]?.toString()?.trim('"') ?: return@onEach
            _reactions.update { map -> map.mapValues { (_, list) -> list.filter { it.id != id } } }
        }.launchIn(viewModelScope)

        val onlineUserIds = mutableSetOf<String>()
        ch.presenceChangeFlow().onEach { action ->
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            fun decode(p: io.github.jan.supabase.realtime.Presence) = try {
                Json.decodeFromJsonElement(PresenceState.serializer(), p.state).userId
            } catch (e: Exception) {
                null
            }
            action.joins.values.mapNotNull(::decode).forEach { onlineUserIds.add(it) }
            action.leaves.values.mapNotNull(::decode).forEach { onlineUserIds.remove(it) }
            _isOpponentOnline.value = onlineUserIds.any { it != myId }
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

        ch.broadcastFlow<TypingEvent>("typing").onEach { event ->
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            if (event.userId == myId) return@onEach
            _isOpponentTyping.value = true
            // Sin un evento explícito de "dejé de escribir" (WhatsApp hace
            // lo mismo): se apaga sola si no llega otro broadcast en 3s.
            typingClearJob?.cancel()
            typingClearJob = viewModelScope.launch {
                kotlinx.coroutines.delay(3000)
                _isOpponentTyping.value = false
            }
        }.launchIn(viewModelScope)

        viewModelScope.launch { ch.subscribe() }
    }

    @Serializable
    private data class NewMessage(
        @SerialName("chat_id") val chatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String? = null,
        @SerialName("media_url") val mediaUrl: String? = null,
        @SerialName("audio_url") val audioUrl: String? = null,
        @SerialName("reply_to_message_id") val replyToMessageId: String? = null,
        @SerialName("view_once") val viewOnce: Boolean = false,
        @SerialName("is_video") val isVideo: Boolean = false
    )

    fun sendMessage(text: String) {
        if (text.isBlank()) return
        // Mismo límite real que messages_body_length
        // (0023_text_length_limits.sql) — validado aquí también, mismo
        // criterio ya aplicado a nombre/bio de perfil y caption de posts.
        if (text.length > 2000) {
            _errorMessage.value = "El mensaje no puede tener más de 2000 caracteres."
            return
        }
        // Hallazgo real: si el usuario ignoraba la sugerencia de apertura
        // (icebreaker) y escribía su propio mensaje, la sugerencia se
        // quedaba visible para siempre encima del compositor incluso
        // después de que el chat ya tuviera mensajes de verdad — nada la
        // limpiaba salvo tocarla o su propia "✕".
        _icebreaker.value = null
        // Responder a un mensaje concreto (cita), comparado con
        // WhatsApp/Telegram/iMessage/Instagram DM -- se consume aquí y se
        // limpia, tanto si el envío sale bien como si falla (mismo
        // criterio real que esas apps: la cita no sobrevive a un envío
        // fallido, se vuelve a elegir).
        val replyToId = _replyingTo.value?.id
        _replyingTo.value = null
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, body = text, replyToMessageId = replyToId))
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el mensaje."
            }
        }
    }

    /** Primera pieza de "chat multimedia" — el chat solo soportaba texto
     * (ver `messages_body_or_media`, 0016_message_media.sql: un mensaje
     * necesita AL MENOS texto o foto, nunca ninguno de los dos).
     * [viewOnce] es opcional -- foto para ver una vez, comparado con
     * WhatsApp/Instagram DM/Snapchat, ver 0105_view_once_messages.sql. */
    /** Vídeo real en el chat, comparado con WhatsApp/Telegram/iMessage --
     * reutiliza mediaUrl + is_video (0121_video_messages.sql), mismo
     * patrón exacto que sendPhoto() de abajo. */
    fun sendVideo(context: android.content.Context, uri: android.net.Uri, caption: String = "") {
        _icebreaker.value = null
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadVideo(context, uri, userId)
                val trimmedCaption = caption.trim().ifEmpty { null }?.take(2000)
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, mediaUrl = url, isVideo = true, body = trimmedCaption))
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el vídeo."
            }
        }
    }

    fun sendPhoto(context: android.content.Context, uri: android.net.Uri, viewOnce: Boolean = false, caption: String = "") {
        _icebreaker.value = null
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadImage(context, uri, userId)
                // Añadir un pie de foto real, comparado con WhatsApp/
                // Telegram/Instagram DM -- mismo límite real que
                // messages_body_length (0023, 2000 caracteres).
                val trimmedCaption = caption.trim().ifEmpty { null }?.take(2000)
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, mediaUrl = url, viewOnce = viewOnce, body = trimmedCaption))
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la foto."
            }
        }
    }

    /** Abre una foto real "para ver una vez", comparado con
     * WhatsApp/Instagram DM/Snapchat -- solo tiene sentido llamarlo sobre
     * un mensaje ajeno (RLS/`protect_message_columns` ya lo exigen: el
     * propio remitente NUNCA puede marcarla como abierta,
     * 0105_view_once_messages.sql). El propio servidor vacía media_url de
     * verdad al marcar opened_at -- por eso aquí se guarda la URL real
     * ANTES de mandar el UPDATE, para poder mostrarla una última vez en
     * el visor a pantalla completa sin depender de una segunda consulta
     * (que ya la vería vacía). */
    fun openViewOnceMessage(messageId: String): String? {
        val message = _messages.value.firstOrNull { it.id == messageId } ?: return null
        val mediaUrl = message.mediaUrl ?: return null
        _messages.update { list -> list.map { if (it.id == messageId) it.copy(openedAt = java.time.Instant.now().toString(), mediaUrl = null) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("messages")
                    .update({ set("opened_at", java.time.Instant.now().toString()) }) { filter { eq("id", messageId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo abrir la foto."
            }
        }
        return mediaUrl
    }

    /** Última pieza real de "chat funcional con fotos, voz, reacciones,
     * read receipts" — mensaje de voz nativo (ver VoiceRecorder.kt,
     * MediaRecorder sin SDK de terceros, y 0019_message_audio.sql). */
    fun sendVoiceNote(file: java.io.File) {
        _icebreaker.value = null
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadAudioFile(file, userId)
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, audioUrl = url))
                file.delete()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la nota de voz."
            }
        }
    }

    /** Hallazgo real, mismo patrón que socials/compat_requests: no había
     * NINGUNA forma de borrar un mensaje propio, ni siquiera el remitente
     * — `messages` no tenía política de delete hasta esta pasada (ver
     * 0022_messages_delete.sql). "Borrar para todos", no solo-para-mí. */
    /** "Eliminar para mí" real, comparado con WhatsApp -- sobre CUALQUIER
     * mensaje (propio o ajeno): la otra persona lo sigue viendo con
     * normalidad, la fila real nunca se borra -- solo se añade mi
     * propio id a `deleted_for`, y ChatScreen.kt ya filtra en cliente
     * cualquier mensaje donde aparezca mi id (0118_delete_message_for_me.sql). */
    fun deleteForMe(messageId: String) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val current = _messages.value.firstOrNull { it.id == messageId }?.deletedFor ?: emptyList()
                if (userId in current) return@launch
                SupabaseManager.client.from("messages")
                    .update({ set("deleted_for", current + userId) }) { filter { eq("id", messageId) } }
                _messages.update { list ->
                    list.map { if (it.id == messageId) it.copy(deletedFor = it.deletedFor + userId) else it }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo eliminar el mensaje para ti."
            }
        }
    }

    fun deleteMessage(messageId: String) {
        _messages.update { list -> list.filter { it.id != messageId } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("messages").delete { filter { eq("id", messageId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar el mensaje."
            }
        }
    }

    /** Hallazgo real, comparado con WhatsApp/Telegram/Messenger: un
     * mensaje mal escrito solo se podía borrar entero, nunca corregir --
     * `messages` no tenía ninguna política de UPDATE que dejara al
     * remitente tocar su propio `body` hasta esta pasada (ver
     * 0049_messages_edit.sql). Mismo límite real que
     * `messages_body_length` (0023, 2000 caracteres). Sin ventana de
     * tiempo límite para editar (alcance deliberado, ver la propia
     * migración). */
    fun editMessage(messageId: String, newBody: String) {
        if (newBody.isEmpty() || newBody.length > 2000) return
        val nowIso = java.time.Instant.now().toString()
        _messages.update { list ->
            list.map { if (it.id == messageId) it.copy(body = newBody, editedAt = nowIso) else it }
        }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("messages")
                    .update({ set("body", newBody); set("edited_at", nowIso) }) { filter { eq("id", messageId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo editar el mensaje."
            }
        }
    }

    @Serializable
    private data class NewVote(
        @SerialName("chat_id") val chatId: String,
        @SerialName("voter_id") val voterId: String,
        val delta: Int
    )

    /** Vota +1/+10/+100 o -1/-10/-100, igual que ChatView.swift.
     *
     * Hallazgo de seguridad real (corregido en 0032_protect_compatibility_score.sql):
     * antes esta función calculaba `newScore` en el cliente y lo escribía
     * directamente en `chats.compatibility_score` — un cliente modificado
     * podía saltarse el voto por completo y escribir cualquier valor. El
     * servidor ahora es la única fuente de verdad: un trigger en
     * `compatibility_votes` aplica el delta y actualiza el score, y un
     * segundo trigger revierte cualquier escritura directa a
     * `compatibility_score` que no venga de ese trigger. Este cliente ya
     * no escribe `chats` en absoluto — el número autoritativo llega por la
     * suscripción Realtime a `UPDATE` en `chats` que ya existía.
     *
     * Retoque de UX de la misma pasada: sin ninguna actualización local,
     * la barra se quedaría congelada hasta que diera la vuelta completa
     * el trayecto voto→trigger→Realtime, un retraso perceptible que antes
     * no existía (la escritura directa daba feedback instantáneo). Se
     * mantiene el feedback optimista — SOLO en memoria, nunca escrito a
     * la base de datos — y se deja que el valor real de `chats` lo
     * sobrescriba en cuanto llegue por Realtime. */
    fun vote(delta: Int) {
        _compatibility.value = (_compatibility.value + delta).coerceIn(0, 100)
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("compatibility_votes").insert(NewVote(chatId, userId, delta))
            } catch (e: Exception) {
                // Cooldown real de 30s entre votos (0112_compatibility_votes_cooldown.sql):
                // a diferencia de un error de red normal, este rechazo es
                // real y frecuente -- sin revertir aquí, el número
                // optimista de arriba se quedaba mal hasta el próximo
                // evento real de Realtime en `chats` (que podía tardar o
                // no llegar nunca si nadie más toca el chat).
                _compatibility.value = (_compatibility.value - delta).coerceIn(0, 100)
                _errorMessage.value = "Espera unos segundos antes de volver a votar."
            }
        }
    }

    @Serializable
    data class CompatibilityVoteEntry(
        val id: String,
        @SerialName("voter_id") val voterId: String,
        val delta: Int,
        @SerialName("created_at") val createdAt: String
    )

    private val _compatibilityHistory = MutableStateFlow<List<CompatibilityVoteEntry>>(emptyList())
    val compatibilityHistory: StateFlow<List<CompatibilityVoteEntry>> = _compatibilityHistory

    /** Historial visual real del % de compatibilidad -- el dato
     * (`compatibility_votes`) y su RLS de lectura ya existían desde 0002,
     * pero ningún cliente lo leyó nunca hasta ahora (solo se insertaba,
     * nunca se consultaba). Hueco #1 de la auditoría de sistemas propios
     * de SOCIAL: la feature de menor coste posible, sin migración nueva. */
    fun loadCompatibilityHistory() {
        viewModelScope.launch {
            try {
                _compatibilityHistory.value = SupabaseManager.client.from("compatibility_votes")
                    .select(columns = Columns.raw("id,voter_id,delta,created_at")) {
                        filter { eq("chat_id", chatId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<CompatibilityVoteEntry>()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el historial de compatibilidad."
            }
        }
    }

    /** Activar/desactivar mensajes que desaparecen real para TODO el
     * chat, comparado con WhatsApp/Instagram DM -- ajuste COMPARTIDO
     * (no una preferencia personal como silenciar/fijar): cualquiera de
     * los dos puede tocarlo, y afecta a los dos por igual. Solo afecta a
     * mensajes NUEVOS -- nunca retroactivo (0115_disappearing_messages.sql).
     * `seconds` en null desactiva el modo real. */
    fun setDisappearingSeconds(seconds: Int?) {
        _disappearingSeconds.value = seconds
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("chats")
                    .update({ set("disappearing_seconds", seconds) }) { filter { eq("id", chatId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el modo de mensajes que desaparecen."
            }
        }
    }
}
