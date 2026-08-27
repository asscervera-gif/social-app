package com.social.app.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class GroupChat(
    val id: String,
    val name: String,
    @SerialName("created_by") val createdBy: String,
    @SerialName("created_at") val createdAt: String = "",
    // Nombre editable y foto de grupo real (0063_group_chat_photo.sql),
    // comparado con WhatsApp/Messenger/Telegram.
    @SerialName("photo_url") val photoUrl: String? = null,
    // Silenciar un chat de grupo real (0064_group_chat_mute.sql),
    // comparado con WhatsApp/Instagram/Messenger -- viene de la propia
    // fila de membresía (`group_chat_members.muted`), no de esta tabla;
    // se rellena aparte en load(), nunca decodificado directamente del
    // select de `group_chats`.
    val isMutedForMe: Boolean = false,
    // Fijar un chat de grupo arriba de la lista, comparado con
    // WhatsApp/Telegram/Messenger -- ver 0081_pin_chats.sql, mismo
    // criterio que isMutedForMe: viene de la propia fila de membresía.
    val isPinnedForMe: Boolean = false,
    // Mensajes que desaparecen real también en el chat de grupo,
    // comparado con WhatsApp/Instagram DM -- cierra el alcance
    // deliberado documentado desde 0115_disappearing_messages.sql (solo
    // 1:1 esa ronda). Solo el creador/admin puede tocarlo
    // (group_chats_update_own/_by_admin), ver 0124_group_disappearing_messages.sql.
    @SerialName("disappearing_seconds") val disappearingSeconds: Int? = null,
    // Marcar un chat de grupo como no leído manualmente, comparado con
    // WhatsApp/Telegram/Messenger -- combina el flag manual real con la
    // detección real de no leído (`group_chat_members.last_read_at`
    // frente al último mensaje real), primera vez que la lista de grupos
    // tiene CUALQUIER concepto de no leído (0088_mark_chat_unread.sql).
    val hasUnread: Boolean = false,
    val markedUnreadForMe: Boolean = false
)

/**
 * Chats de grupo reales por primera vez, comparado con WhatsApp/Instagram/
 * Messenger/Facebook -- `chats` (0001_schema.sql) es estrictamente 1:1.
 * Ronda de cliente sobre el backend ya construido y verificado
 * (0057_group_chats.sql, 128/128 tests locales).
 *
 * Aviso real, documentado también en la propia migración: crear un grupo
 * NO puede usar `.insert(...) { select() }` (el patrón ya usado para
 * `posts`/`live_streams`) -- `insert into group_chats returning` falla
 * por RLS porque RETURNING revisa la fila contra `group_chats_select`
 * (que depende de que el trigger de auto-alta del creador ya haya
 * corrido) en un punto anterior a que ese efecto cuente para esa
 * comprobación en concreto. El id se genera aquí mismo con
 * `UUID.randomUUID()` y se inserta explícito, evitando RETURNING del todo.
 */
class GroupChatsViewModel : ViewModel() {

    private val _groups = MutableStateFlow<List<GroupChat>>(emptyList())
    val groups: StateFlow<List<GroupChat>> = _groups.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val groups = SupabaseManager.client.from("group_chats")
                    .select(columns = Columns.raw("id,name,created_by,created_at,photo_url")) {
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<GroupChat>()
                // Silenciar un chat de grupo real (0064_group_chat_mute.sql):
                // `muted` vive en la propia fila de membresía, no en
                // `group_chats` -- una segunda consulta, filtrada a MI
                // propio user_id (RLS ya solo deja ver la propia igualmente).
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id
                val myMemberships = if (userId != null && groups.isNotEmpty()) {
                    SupabaseManager.client.from("group_chat_members")
                        .select(columns = Columns.raw("group_chat_id,muted,hidden,pinned,marked_unread,last_read_at")) {
                            filter { eq("user_id", userId); isIn("group_chat_id", groups.map { it.id }) }
                        }
                        .decodeList<MyMembership>()
                        .associateBy { it.groupChatId }
                } else {
                    emptyMap()
                }
                // Primera vez que la lista de grupos tiene CUALQUIER
                // concepto de no leído, comparado con WhatsApp/Instagram/
                // Messenger (0088_mark_chat_unread.sql) -- se compara el
                // último mensaje REAL de cada grupo contra
                // `last_read_at` de mi propia membresía, mismo criterio
                // que `messages.read_at` para el chat 1:1
                // (ChatListViewModel.kt).
                val visibleGroups = groups.filter { myMemberships[it.id]?.hidden != true }
                val lastMessages = if (userId != null) {
                    visibleGroups.associate { group ->
                        val lastMessage = try {
                            SupabaseManager.client.from("group_messages")
                                .select(columns = Columns.raw("sender_id,created_at")) {
                                    filter { eq("group_chat_id", group.id) }
                                    order("created_at", Order.DESCENDING)
                                    limit(1)
                                }
                                .decodeSingleOrNull<LastGroupMessageRow>()
                        } catch (e: Exception) {
                            null
                        }
                        group.id to lastMessage
                    }
                } else {
                    emptyMap()
                }
                // Ocultar un chat de grupo real (0068_group_chat_hide.sql),
                // comparado con WhatsApp/Instagram/Messenger -- mismo
                // criterio que ChatListViewModel.kt.load() (chat 1:1): un
                // grupo oculto para MÍ desaparece de la lista por completo,
                // no se muestra tachado ni aparte.
                //
                // Fijar arriba (0081_pin_chats.sql), comparado con
                // WhatsApp/Telegram/Messenger -- mismo criterio de orden
                // que ChatListViewModel.kt.load() (chat 1:1).
                _groups.value = visibleGroups
                    .map { group ->
                        val membership = myMemberships[group.id]
                        val markedUnreadForMe = membership?.markedUnread ?: false
                        val lastMessage = lastMessages[group.id]
                        val lastReadAt = membership?.lastReadAt
                        val hasRealUnread = lastMessage != null &&
                            lastMessage.senderId != userId &&
                            (lastReadAt == null || lastMessage.createdAt > lastReadAt)
                        group.copy(
                            isMutedForMe = membership?.muted ?: false,
                            isPinnedForMe = membership?.pinned ?: false,
                            hasUnread = hasRealUnread || markedUnreadForMe,
                            markedUnreadForMe = markedUnreadForMe
                        )
                    }
                    .sortedByDescending { it.isPinnedForMe }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los grupos: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }

    @Serializable
    private data class MyMembership(
        @SerialName("group_chat_id") val groupChatId: String,
        val muted: Boolean,
        val hidden: Boolean = false,
        val pinned: Boolean = false,
        // Marcar como no leído manualmente + detección real de no leído,
        // comparado con WhatsApp/Telegram/Messenger
        // (0088_mark_chat_unread.sql).
        @SerialName("marked_unread") val markedUnread: Boolean = false,
        @SerialName("last_read_at") val lastReadAt: String? = null
    )

    @Serializable
    private data class LastGroupMessageRow(
        @SerialName("sender_id") val senderId: String,
        @SerialName("created_at") val createdAt: String
    )

    /** Silenciar un grupo real con una duración real elegida (8 horas / 1
     * semana / siempre), comparado con WhatsApp/Telegram -- antes era un
     * simple interruptor sin expiración (ver 0082_mute_until.sql, columna
     * `group_chat_members.muted_until`, null = para siempre). Mismo patrón
     * (optimista + revertir con load() si falla) ya usado en
     * ChatListViewModel.kt.muteChatFor() para el chat 1:1. */
    fun muteGroupFor(group: GroupChat, until: java.time.Instant?) {
        _groups.update { list -> list.map { if (it.id == group.id) it.copy(isMutedForMe = true) else it } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({
                    set("muted", true)
                    set("muted_until", until?.toString())
                }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo silenciar el grupo."
                load()
            }
        }
    }

    /** Activar (quitar el silencio) de un grupo real -- limpia también la
     * fecha de expiración para no dejar estado colgado. */
    fun unmuteGroup(group: GroupChat) {
        _groups.update { list -> list.map { if (it.id == group.id) it.copy(isMutedForMe = false) else it } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({
                    set("muted", false)
                    set("muted_until", null as String?)
                }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo activar el grupo."
                load()
            }
        }
    }

    /** Fijar/desfijar un grupo real arriba de la lista, comparado con
     * WhatsApp/Telegram/Messenger -- mismo patrón (optimista + revertir
     * con load() si falla) ya usado en toggleMute(). A diferencia de
     * ocultar, un grupo fijado NO se desfija solo al llegar un mensaje. */
    fun togglePin(group: GroupChat) {
        val newValue = !group.isPinnedForMe
        _groups.update { list ->
            list.map { if (it.id == group.id) it.copy(isPinnedForMe = newValue) else it }
                .sortedByDescending { it.isPinnedForMe }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({ set("pinned", newValue) }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo fijar el grupo."
                load()
            }
        }
    }

    /** Marcar/desmarcar un chat de grupo como no leído manualmente,
     * comparado con WhatsApp/Telegram/Messenger -- capa personal por
     * encima de la detección real de no leído
     * (`group_chat_members.marked_unread`, 0088_mark_chat_unread.sql, ya
     * cubierta por `group_chat_members_update_own`). Sin actualización
     * optimista de `hasUnread` por el mismo motivo que
     * ChatListViewModel.toggleMarkUnread(): combina dos fuentes y no
     * vale la pena reconstruirlo en cliente, `load()` tras escribir es
     * simple y siempre correcto. */
    fun toggleMarkUnread(group: GroupChat) {
        val newValue = !group.markedUnreadForMe
        _groups.update { list -> list.map { if (it.id == group.id) it.copy(markedUnreadForMe = newValue) else it } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({ set("marked_unread", newValue) }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el estado de leído."
            } finally {
                load()
            }
        }
    }

    /** Ocultar un chat de grupo real de la lista sin salir de él, comparado
     * con WhatsApp/Instagram/Messenger -- mismo criterio de "archivar" que
     * ChatListViewModel.kt.hideChat() (chat 1:1): desaparece de la lista
     * hasta que llegue un mensaje nuevo real, que lo restaura solo
     * (`unhide_group_on_new_message`, 0068_group_chat_hide.sql). */
    fun hideGroup(group: GroupChat) {
        _groups.update { list -> list.filter { it.id != group.id } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({ set("hidden", true) }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo ocultar el grupo."
                load()
            }
        }
    }

    @Serializable
    private data class NewGroupChat(
        val id: String,
        val name: String,
        @SerialName("created_by") val createdBy: String
    )

    @Serializable
    private data class NewGroupMember(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("user_id") val userId: String
    )

    /** Crea el grupo real (el creador se añade solo como miembro vía
     * `trg_add_group_creator_as_member`) y añade de una vez a los socials
     * ya elegidos -- mismo patrón de picker que "¿Con quién?" en
     * NewPostSheet.kt (reutiliza SocialsListViewModel, sin duplicar esa
     * consulta). */
    suspend fun createGroup(name: String, initialMemberIds: List<String>): GroupChat? {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return null
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return null
        val groupId = UUID.randomUUID().toString()
        return try {
            SupabaseManager.client.from("group_chats").insert(NewGroupChat(groupId, trimmed, userId))
            if (initialMemberIds.isNotEmpty()) {
                val rows = initialMemberIds.map { NewGroupMember(groupId, it) }
                SupabaseManager.client.from("group_chat_members").insert(rows)
            }
            com.social.app.backend.AnalyticsManager.track("group_chat_created")
            GroupChat(id = groupId, name = trimmed, createdBy = userId)
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo crear el grupo."
            null
        }
    }
}
