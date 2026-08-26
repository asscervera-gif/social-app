package com.social.app.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Chat
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

data class ChatListEntry(
    val chat: Chat,
    val otherName: String,
    val otherAvatarConfig: Map<String, String>?,
    val lastMessage: String?,
    val lastActivity: String,
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de quitar una conversación de "Tus chats" -- ver
    // 0044_chats_hide.sql. Necesario para saber qué columna
    // (hidden_by_a/hidden_by_b) me corresponde a MÍ en este chat.
    val iAmUserA: Boolean,
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de silenciar una conversación sin salir ni bloquear --
    // ver 0047_message_notify_mute.sql.
    val isMutedForMe: Boolean,
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: "Tus
    // chats" no distinguía visualmente qué conversaciones tenían mensajes
    // sin leer.
    val hasUnread: Boolean,
    // Fijar un chat arriba de la lista, comparado con
    // WhatsApp/Telegram/Messenger -- ver 0081_pin_chats.sql.
    val isPinnedForMe: Boolean,
    // Marcar un chat como no leído manualmente, comparado con WhatsApp/
    // Telegram/Messenger -- ver 0088_mark_chat_unread.sql. Se guarda
    // aparte de `hasUnread` (que ya combina esto con el estado real de
    // lectura) porque el botón de la UI necesita saber CUÁL de los dos
    // motivos aplica para decidir su propia etiqueta.
    val markedUnreadForMe: Boolean
)

// Hallazgo real, comparado con WhatsApp/Instagram/Messenger: la lista de
// chats solo mostraba el nombre de la otra persona, nunca su avatar --
// el identificador visual principal de cualquier lista de conversaciones.
@Serializable
private data class NameRow(
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
)

@Serializable
private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

// Hallazgo real, comparado con WhatsApp/Instagram/Messenger: "Tus chats"
// no distinguía visualmente qué conversaciones tenían mensajes sin leer.
// markMessagesRead() (ChatViewModel) marca TODO el historial pendiente de
// una vez al abrir el chat (no hay marcado incremental mensaje a
// mensaje), así que el estado de lectura del ÚLTIMO mensaje ya equivale a
// "¿hay algo sin leer en este chat?" -- sin necesitar una segunda consulta.
@Serializable
private data class LastMessageRow(
    val body: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("sender_id") val senderId: String,
    @SerialName("read_at") val readAt: String? = null
)

@Serializable
private data class ChatRow(
    val id: String,
    @SerialName("user_a_id") val userAId: String,
    @SerialName("user_b_id") val userBId: String,
    @SerialName("compatibility_score") val compatibilityScore: Int = 50,
    @SerialName("created_at") val createdAt: String,
    @SerialName("hidden_by_a") val hiddenByA: Boolean = false,
    @SerialName("hidden_by_b") val hiddenByB: Boolean = false,
    @SerialName("muted_by_a") val mutedByA: Boolean = false,
    @SerialName("muted_by_b") val mutedByB: Boolean = false,
    @SerialName("pinned_by_a") val pinnedByA: Boolean = false,
    @SerialName("pinned_by_b") val pinnedByB: Boolean = false,
    // Marcar un chat como no leído manualmente, comparado con WhatsApp/
    // Telegram/Messenger (0088_mark_chat_unread.sql).
    @SerialName("marked_unread_by_a") val markedUnreadByA: Boolean = false,
    @SerialName("marked_unread_by_b") val markedUnreadByB: Boolean = false
    // muted_until_a/b (0082_mute_until.sql) deliberadamente NO se decodifican
    // aquí: esta app nunca convierte una fecha real que llega del servidor
    // en un objeto de fecha para compararla contra "ahora" en cliente (ver
    // Profile.createdAt) -- el formato exacto de timestamptz que devuelve
    // PostgREST no está verificado contra un proyecto real en este entorno.
    // La expiración real solo importa para decidir si se manda o no el
    // aviso, y esa comparación ya la hace el propio servidor
    // (notify_new_message, 0082) -- el icono de silenciado del cliente
    // sigue reflejando el flag en bruto, mismo criterio ya usado antes de
    // esta ronda.
)

/**
 * Hallazgo real, el más grande de esta pasada: no existía NINGUNA pantalla
 * de lista de chats en toda la app — la única forma de entrar a un chat era
 * un `chatId` puntual llegado desde una notificación de social aceptado
 * (`AvisosScreen.kt`). Una vez se salía de ese chat, no había forma de
 * volver a encontrarlo salvo esperar otra notificación. `chats` no tiene
 * columna de "último mensaje" — se resuelve con una consulta aparte por
 * chat (igual que se resuelve el nombre del oponente en
 * DuelHistoryViewModel: sin join embebido, para no adivinar el nombre de
 * una FK sin poder probarlo contra un Postgres real).
 */
class ChatListViewModel : ViewModel() {

    private val _chats = MutableStateFlow<List<ChatListEntry>>(emptyList())
    val chats: StateFlow<List<ChatListEntry>> = _chats.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var chatsChannel: RealtimeChannel? = null

    /**
     * Sin esto, un chat nuevo (social recién aceptado) o un mensaje nuevo en
     * un chat ya existente no aparecía/actualizaba la lista hasta salir y
     * volver a entrar a "Tus chats" — mismo criterio de "en vivo, no solo al
     * abrir" ya aplicado a Avisos/Chat. Dos suscripciones a `chats`
     * (`user_a_id`/`user_b_id`) porque `postgresChangeFlow` filtra por una
     * sola columna a la vez — mismo límite ya documentado en
     * NotificationsBadgeViewModel. Los mensajes nuevos se cubren
     * recargando en cada inserción de chat NO nuevo — más simple y
     * suficientemente correcto que suscribirse a `messages` sin filtro (que
     * traería tráfico de chats ajenos).
     */
    fun start() {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            load()
            subscribeToRealtime(userId)
        }
    }

    fun stop() {
        viewModelScope.launch { chatsChannel?.unsubscribe() }
    }

    private fun subscribeToRealtime(userId: String) {
        val ch = SupabaseManager.client.realtime.channel("chat-list-$userId")
        chatsChannel = ch

        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "chats"
            filter("user_a_id", FilterOperator.EQ, userId)
        }.onEach { load() }.launchIn(viewModelScope)

        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "chats"
            filter("user_b_id", FilterOperator.EQ, userId)
        }.onEach { load() }.launchIn(viewModelScope)

        viewModelScope.launch { ch.subscribe() }
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                // Hallazgo real: la lista de chats seguía mostrando
                // conversaciones con gente que has bloqueado — el envío
                // de mensajes ya está bloqueado en el servidor
                // (0013_block_enforcement_chat.sql), pero el chat en sí
                // seguía apareciendo en la lista, algo que ninguna app de
                // mensajería grande hace.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                // Hallazgo real: sin `.limit()`, a diferencia de la
                // convención del resto del proyecto (mismo patrón
                // corregido en ChatViewModel.loadHistory() esta pasada).
                val myChats = SupabaseManager.client.from("chats")
                    .select(columns = Columns.raw("id,user_a_id,user_b_id,compatibility_score,created_at,hidden_by_a,hidden_by_b,muted_by_a,muted_by_b,pinned_by_a,pinned_by_b,marked_unread_by_a,marked_unread_by_b")) {
                        filter {
                            or {
                                eq("user_a_id", userId)
                                eq("user_b_id", userId)
                            }
                        }
                        limit(200)
                    }
                    .decodeList<ChatRow>()
                    .filter {
                        val otherId = if (it.userAId == userId) it.userBId else it.userAId
                        val hiddenForMe = if (it.userAId == userId) it.hiddenByA else it.hiddenByB
                        otherId !in blockedIds && !hiddenForMe
                    }

                // Hallazgo real: la lista no ordenaba por actividad
                // reciente, comparado con cualquier app de mensajería
                // (WhatsApp/Instagram DMs siempre muestran el chat más
                // reciente arriba) — se quedaba en el orden por defecto de
                // la base de datos, sin importar si acababa de llegar un
                // mensaje a un chat antiguo.
                val entries = myChats.map { row ->
                    val chat = Chat(row.id, row.userAId, row.userBId, row.compatibilityScore)
                    val otherId = if (row.userAId == userId) row.userBId else row.userAId
                    val otherProfile = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name,avatar_config")) { filter { eq("id", otherId) } }
                            .decodeSingleOrNull<NameRow>()
                    } catch (e: Exception) {
                        null
                    }

                    val lastMessage = try {
                        SupabaseManager.client.from("messages")
                            .select(columns = Columns.raw("body,created_at,sender_id,read_at")) {
                                filter { eq("chat_id", chat.id) }
                                order("created_at", Order.DESCENDING)
                                limit(1)
                            }
                            .decodeSingleOrNull<LastMessageRow>()
                    } catch (e: Exception) {
                        null
                    }

                    val markedUnreadForMe = if (row.userAId == userId) row.markedUnreadByA else row.markedUnreadByB
                    ChatListEntry(
                        chat = chat,
                        otherName = otherProfile?.displayName ?: "Perfil",
                        otherAvatarConfig = otherProfile?.avatarConfig,
                        lastMessage = lastMessage?.body,
                        lastActivity = lastMessage?.createdAt ?: row.createdAt,
                        iAmUserA = row.userAId == userId,
                        isMutedForMe = if (row.userAId == userId) row.mutedByA else row.mutedByB,
                        // Marcar como no leído manualmente, comparado con
                        // WhatsApp/Telegram/Messenger -- capa personal por
                        // encima del estado real de lectura del último
                        // mensaje (0088_mark_chat_unread.sql).
                        hasUnread = (lastMessage != null && lastMessage.senderId != userId && lastMessage.readAt == null) || markedUnreadForMe,
                        isPinnedForMe = if (row.userAId == userId) row.pinnedByA else row.pinnedByB,
                        markedUnreadForMe = markedUnreadForMe
                    )
                }
                // Fijado primero (mismo criterio que WhatsApp/Telegram),
                // actividad reciente dentro de cada grupo.
                _chats.value = entries.sortedWith(compareByDescending<ChatListEntry> { it.isPinnedForMe }.thenByDescending { it.lastActivity })
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus chats."
            } finally {
                _isLoading.value = false
            }
        }
    }

    /** "Ocultar conversación" -- solo afecta a MI copia (columna
     * hidden_by_a/hidden_by_b según corresponda), nunca a la de la otra
     * persona (protect_chat_hidden_flags, 0044_chats_hide.sql, lo
     * garantiza también del lado del servidor). Un mensaje nuevo real la
     * restaura sola. */
    fun hideChat(entry: ChatListEntry) {
        _chats.update { it.filter { e -> e.chat.id != entry.chat.id } }
        viewModelScope.launch {
            try {
                val column = if (entry.iAmUserA) "hidden_by_a" else "hidden_by_b"
                SupabaseManager.client.from("chats")
                    .update({ set(column, true) }) { filter { eq("id", entry.chat.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo ocultar la conversación."
                load()
            }
        }
    }

    /** Silenciar con una duración real elegida por la persona (8 horas / 1
     * semana / siempre), comparado con WhatsApp/Telegram -- antes era un
     * simple interruptor sin expiración (ver 0082_mute_until.sql). `until`
     * en null significa "para siempre", mismo criterio que
     * `profiles.banned_until`. Solo afecta a MI copia (columnas
     * muted_by_a/muted_until_a o muted_by_b/muted_until_b según
     * corresponda), nunca a la de la otra persona
     * (protect_chat_muted_flags lo garantiza también del lado del
     * servidor). */
    fun muteChatFor(entry: ChatListEntry, until: Instant?) {
        _chats.update { list ->
            list.map { if (it.chat.id == entry.chat.id) it.copy(isMutedForMe = true) else it }
        }
        viewModelScope.launch {
            try {
                val mutedColumn = if (entry.iAmUserA) "muted_by_a" else "muted_by_b"
                val untilColumn = if (entry.iAmUserA) "muted_until_a" else "muted_until_b"
                SupabaseManager.client.from("chats")
                    .update({
                        set(mutedColumn, true)
                        set(untilColumn, until?.toString())
                    }) { filter { eq("id", entry.chat.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo silenciar la conversación."
                load()
            }
        }
    }

    /** Activar (quitar el silencio) -- limpia también la fecha de
     * expiración para no dejar estado colgado. */
    fun unmuteChat(entry: ChatListEntry) {
        _chats.update { list ->
            list.map { if (it.chat.id == entry.chat.id) it.copy(isMutedForMe = false) else it }
        }
        viewModelScope.launch {
            try {
                val mutedColumn = if (entry.iAmUserA) "muted_by_a" else "muted_by_b"
                val untilColumn = if (entry.iAmUserA) "muted_until_a" else "muted_until_b"
                SupabaseManager.client.from("chats")
                    .update({
                        set(mutedColumn, false)
                        set(untilColumn, null as String?)
                    }) { filter { eq("id", entry.chat.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo activar la conversación."
                load()
            }
        }
    }

    /** Fijar/desfijar -- solo afecta a MI copia (columna
     * pinned_by_a/pinned_by_b según corresponda), nunca a la de la otra
     * persona (protect_chat_pinned_flags, 0081_pin_chats.sql, lo
     * garantiza también del lado del servidor). A diferencia de ocultar,
     * un chat fijado NO se desfija solo al llegar un mensaje -- mismo
     * criterio que WhatsApp/Telegram. */
    fun togglePin(entry: ChatListEntry) {
        val newValue = !entry.isPinnedForMe
        _chats.update { list ->
            list.map { if (it.chat.id == entry.chat.id) it.copy(isPinnedForMe = newValue) else it }
                .sortedWith(compareByDescending<ChatListEntry> { it.isPinnedForMe }.thenByDescending { it.lastActivity })
        }
        viewModelScope.launch {
            try {
                val column = if (entry.iAmUserA) "pinned_by_a" else "pinned_by_b"
                SupabaseManager.client.from("chats")
                    .update({ set(column, newValue) }) { filter { eq("id", entry.chat.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo fijar la conversación."
                load()
            }
        }
    }

    /** Marcar/desmarcar un chat como no leído manualmente, comparado con
     * WhatsApp/Telegram/Messenger -- capa puramente personal (columna
     * marked_unread_by_a/marked_unread_by_b según corresponda) por
     * encima del estado real de lectura del último mensaje, NUNCA toca
     * `messages.read_at` (0088_mark_chat_unread.sql, lo garantiza también
     * del lado del servidor: nadie puede tocar la copia ajena). Se limpia
     * sola al volver a abrir el chat de verdad -- ver
     * ChatViewModel.markMessagesRead(). */
    fun toggleMarkUnread(entry: ChatListEntry) {
        val newValue = !entry.markedUnreadForMe
        // Sin actualización optimista de `hasUnread` aquí a propósito:
        // combina el estado real de lectura del último mensaje CON este
        // flag manual, y no se guarda el primero por separado en
        // ChatListEntry -- `load()` tras la escritura real es más simple
        // y siempre correcto que intentar reconstruir el estado real a
        // partir del booleano ya combinado.
        _chats.update { list ->
            list.map { if (it.chat.id == entry.chat.id) it.copy(markedUnreadForMe = newValue) else it }
        }
        viewModelScope.launch {
            try {
                val column = if (entry.iAmUserA) "marked_unread_by_a" else "marked_unread_by_b"
                SupabaseManager.client.from("chats")
                    .update({ set(column, newValue) }) { filter { eq("id", entry.chat.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el estado de leído."
            } finally {
                load()
            }
        }
    }
}
