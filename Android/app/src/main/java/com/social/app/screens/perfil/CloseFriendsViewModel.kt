package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * "Mejores amigos" real para historias (0075_close_friends_stories.sql),
 * comparado con Instagram (Close Friends) y Snapchat (audiencia
 * personalizada). Hallazgo real de seguridad, no solo de funcionalidad:
 * `stories_select` (0002_rls.sql) no tenía NINGUNA restricción de
 * audiencia -- cualquier usuario autenticado veía la historia de
 * cualquier otro.
 *
 * El candidato natural para elegir "mejores amigos" es la lista de
 * socials aceptados (la relación mutua central de la app, ver
 * SocialsListViewModel.kt) -- no tiene sentido ofrecer añadir a un
 * desconocido sin relación previa. Mismo patrón sin join embebido/FK
 * ambigua ya usado en SocialsListViewModel/ChatListViewModel/
 * DuelHistoryViewModel.
 */
class CloseFriendsViewModel : ViewModel() {

    private val _candidates = MutableStateFlow<List<SocialEntry>>(emptyList())
    val candidates: StateFlow<List<SocialEntry>> = _candidates.asStateFlow()

    private val _closeFriendIds = MutableStateFlow<Set<String>>(emptySet())
    val closeFriendIds: StateFlow<Set<String>> = _closeFriendIds.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class SocialRow(
        val id: String,
        @SerialName("requester_id") val requesterId: String,
        @SerialName("addressee_id") val addresseeId: String
    )

    @Serializable
    private data class NameRow(
        @SerialName("display_name") val displayName: String,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
    )

    @Serializable
    private data class FriendIdRow(@SerialName("friend_id") val friendId: String)

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val rows = SupabaseManager.client.from("socials")
                    .select(columns = Columns.raw("id,requester_id,addressee_id")) {
                        filter {
                            eq("status", "accepted")
                            or {
                                eq("requester_id", userId)
                                eq("addressee_id", userId)
                            }
                        }
                        limit(100)
                    }
                    .decodeList<SocialRow>()

                _candidates.value = rows.mapNotNull { row ->
                    val otherId = if (row.requesterId == userId) row.addresseeId else row.requesterId
                    val profile = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name,avatar_config")) { filter { eq("id", otherId) } }
                            .decodeSingleOrNull<NameRow>()
                    } catch (e: Exception) {
                        null
                    } ?: return@mapNotNull null
                    SocialEntry(row.id, otherId, profile.displayName, profile.avatarConfig)
                }

                // close_friends_select_own (0075) solo deja leer la
                // propia lista -- exactamente lo que hace falta aquí.
                _closeFriendIds.value = SupabaseManager.client.from("close_friends")
                    .select(columns = Columns.raw("friend_id")) { filter { eq("owner_id", userId) } }
                    .decodeList<FriendIdRow>()
                    .map { it.friendId }
                    .toSet()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar tu lista de mejores amigos."
            }
        }
    }

    @Serializable
    private data class NewCloseFriend(
        @SerialName("owner_id") val ownerId: String,
        @SerialName("friend_id") val friendId: String
    )

    fun toggle(profileId: String) {
        val isCurrentlyFriend = profileId in _closeFriendIds.value
        _closeFriendIds.update { if (isCurrentlyFriend) it - profileId else it + profileId }
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                if (isCurrentlyFriend) {
                    SupabaseManager.client.from("close_friends").delete {
                        filter { eq("owner_id", userId); eq("friend_id", profileId) }
                    }
                } else {
                    SupabaseManager.client.from("close_friends").insert(NewCloseFriend(userId, profileId))
                }
            } catch (e: Exception) {
                // Revierte el estado optimista si el servidor rechazó el cambio.
                _closeFriendIds.update { if (isCurrentlyFriend) it + profileId else it - profileId }
                _errorMessage.value = "No se pudo actualizar tu lista de mejores amigos."
            }
        }
    }
}
