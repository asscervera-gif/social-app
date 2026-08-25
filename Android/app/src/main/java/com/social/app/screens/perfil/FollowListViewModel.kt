package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.chat.FollowManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class FollowEntry(
    val profileId: String,
    val displayName: String,
    val avatarConfig: Map<String, String>? = null,
    val isFollowing: Boolean
)

/**
 * Hallazgo real, comparado con Instagram/Twitter/TikTok: los contadores
 * "Sigo"/"Seguid." de la cabecera del perfil (PerfilViewModel.kt,
 * followersCount/followingCount) ya eran reales desde una pasada anterior,
 * pero tocarlos no hacía nada -- no existía NINGUNA pantalla para ver QUIÉN
 * sigue a quién, solo el número. Mismo patrón sin join embebido/FK ambigua
 * que SocialsListViewModel: `follows` referencia `profiles` dos veces
 * (follower_id/followee_id).
 */
class FollowListViewModel : ViewModel() {

    private val _following = MutableStateFlow<List<FollowEntry>>(emptyList())
    val following: StateFlow<List<FollowEntry>> = _following.asStateFlow()

    private val _followers = MutableStateFlow<List<FollowEntry>>(emptyList())
    val followers: StateFlow<List<FollowEntry>> = _followers.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var myId: String? = null

    @Serializable
    private data class FollowRow(
        @SerialName("follower_id") val followerId: String,
        @SerialName("followee_id") val followeeId: String
    )

    @Serializable
    private data class NameRow(
        val id: String,
        @SerialName("display_name") val displayName: String,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
    )

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    fun load() {
        viewModelScope.launch {
            try {
                val id = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                myId = id
                // Mismo refuerzo de privacidad que SocialsListViewModel/
                // Home/Match/Find/Search/ChatList/Guardados: bloquear a
                // alguien no borra la fila `follows` (conceptos
                // independientes), así que sin este filtro alguien
                // bloqueado seguiría apareciendo en esta lista.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }

                val followingIds = SupabaseManager.client.from("follows")
                    .select(columns = Columns.raw("followee_id")) { filter { eq("follower_id", id) }; limit(200) }
                    .decodeList<FollowRow>()
                    .map { it.followeeId }
                    .filter { it !in blockedIds }
                    .toSet()

                val followerIds = SupabaseManager.client.from("follows")
                    .select(columns = Columns.raw("follower_id")) { filter { eq("followee_id", id) }; limit(200) }
                    .decodeList<FollowRow>()
                    .map { it.followerId }
                    .filter { it !in blockedIds }
                    .toSet()

                val allIds = (followingIds + followerIds).toList()
                val profiles = if (allIds.isEmpty()) emptyList() else SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_config")) { filter { isIn("id", allIds) } }
                    .decodeList<NameRow>()
                val byId = profiles.associateBy { it.id }

                _following.value = followingIds.mapNotNull { pid ->
                    byId[pid]?.let { FollowEntry(pid, it.displayName, it.avatarConfig, isFollowing = true) }
                }
                _followers.value = followerIds.mapNotNull { pid ->
                    byId[pid]?.let { FollowEntry(pid, it.displayName, it.avatarConfig, isFollowing = pid in followingIds) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la lista."
            }
        }
    }

    fun toggleFollow(entry: FollowEntry) {
        val id = myId ?: return
        viewModelScope.launch {
            val manager = FollowManager()
            if (entry.isFollowing) manager.unfollow(id, entry.profileId) else manager.follow(id, entry.profileId)
            load()
        }
    }
}
