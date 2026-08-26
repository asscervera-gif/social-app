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
    val isMutedForMe: Boolean = false
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
                val mutedByGroupId = if (userId != null && groups.isNotEmpty()) {
                    SupabaseManager.client.from("group_chat_members")
                        .select(columns = Columns.raw("group_chat_id,muted")) {
                            filter { eq("user_id", userId); isIn("group_chat_id", groups.map { it.id }) }
                        }
                        .decodeList<MyMembership>()
                        .associate { it.groupChatId to it.muted }
                } else {
                    emptyMap()
                }
                _groups.value = groups.map { it.copy(isMutedForMe = mutedByGroupId[it.id] ?: false) }
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
        val muted: Boolean
    )

    /** Silenciar/activar un grupo real, comparado con WhatsApp/Instagram/
     * Messenger -- mismo patrón (optimista + revertir con load() si falla)
     * ya usado en ChatListViewModel.kt.toggleMute() para el chat 1:1. */
    fun toggleMute(group: GroupChat) {
        val newValue = !group.isMutedForMe
        _groups.update { list -> list.map { if (it.id == group.id) it.copy(isMutedForMe = newValue) else it } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("group_chat_members").update({ set("muted", newValue) }) {
                    filter { eq("group_chat_id", group.id); eq("user_id", userId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el silencio del grupo."
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
