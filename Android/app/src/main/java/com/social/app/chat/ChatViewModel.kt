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

    private val _compatibility = MutableStateFlow(50)
    val compatibility: StateFlow<Int> = _compatibility.asStateFlow()

    private val _opponentId = MutableStateFlow<String?>(null)
    val opponentId: StateFlow<String?> = _opponentId.asStateFlow()

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
                .update({ set("read_at", nowIso) }) {
                    filter {
                        eq("chat_id", chatId)
                        neq("sender_id", userId)
                    }
                }
            _messages.update { list ->
                list.map { if (it.senderId != userId && it.readAt == null) it.copy(readAt = nowIso) else it }
            }
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

            val chat = SupabaseManager.client.from("chats")
                .select { filter { eq("id", chatId) } }
                .decodeSingle<Chat>()
            _compatibility.value = chat.compatibilityScore

            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            _opponentId.value = when (myId) {
                chat.userAId -> chat.userBId
                chat.userBId -> chat.userAId
                else -> null
            }
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
        }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "chats"
            filter("id", io.github.jan.supabase.postgrest.query.filter.FilterOperator.EQ, chatId)
        }.onEach { update ->
            val chat = Json.decodeFromJsonElement(Chat.serializer(), update.record)
            _compatibility.value = chat.compatibilityScore
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
        @SerialName("audio_url") val audioUrl: String? = null
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
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, body = text))
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el mensaje."
            }
        }
    }

    /** Primera pieza de "chat multimedia" — el chat solo soportaba texto
     * (ver `messages_body_or_media`, 0016_message_media.sql: un mensaje
     * necesita AL MENOS texto o foto, nunca ninguno de los dos). */
    fun sendPhoto(context: android.content.Context, uri: android.net.Uri) {
        _icebreaker.value = null
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val url = com.social.app.backend.StorageUploader.uploadImage(context, uri, userId)
                SupabaseManager.client.from("messages").insert(NewMessage(chatId = chatId, senderId = userId, mediaUrl = url))
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la foto."
            }
        }
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
                _errorMessage.value = "No se pudo registrar el voto."
            }
        }
    }
}
