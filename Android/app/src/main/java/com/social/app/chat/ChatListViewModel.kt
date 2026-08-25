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
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class ChatListEntry(
    val chat: Chat,
    val otherName: String,
    val otherAvatarConfig: Map<String, String>?,
    val lastMessage: String?,
    val lastActivity: String
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

@Serializable
private data class LastMessageRow(
    val body: String? = null,
    @SerialName("created_at") val createdAt: String
)

@Serializable
private data class ChatRow(
    val id: String,
    @SerialName("user_a_id") val userAId: String,
    @SerialName("user_b_id") val userBId: String,
    @SerialName("compatibility_score") val compatibilityScore: Int = 50,
    @SerialName("created_at") val createdAt: String
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
                    .select(columns = Columns.raw("id,user_a_id,user_b_id,compatibility_score,created_at")) {
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
                        otherId !in blockedIds
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
                            .select(columns = Columns.raw("body,created_at")) {
                                filter { eq("chat_id", chat.id) }
                                order("created_at", Order.DESCENDING)
                                limit(1)
                            }
                            .decodeSingleOrNull<LastMessageRow>()
                    } catch (e: Exception) {
                        null
                    }

                    ChatListEntry(
                        chat = chat,
                        otherName = otherProfile?.displayName ?: "Perfil",
                        otherAvatarConfig = otherProfile?.avatarConfig,
                        lastMessage = lastMessage?.body,
                        lastActivity = lastMessage?.createdAt ?: row.createdAt
                    )
                }
                _chats.value = entries.sortedByDescending { it.lastActivity }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus chats."
            } finally {
                _isLoading.value = false
            }
        }
    }
}
