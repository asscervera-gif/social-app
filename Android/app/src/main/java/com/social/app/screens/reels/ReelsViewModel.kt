package com.social.app.screens.reels

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.StorageUploader
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
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

@Serializable
data class Reel(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("video_url") val videoUrl: String,
    @SerialName("thumbnail_url") val thumbnailUrl: String? = null,
    val caption: String? = null,
    @SerialName("is_social_only") val isSocialOnly: Boolean = false,
    @SerialName("like_count") val likeCount: Int = 0,
    @SerialName("comment_count") val commentCount: Int = 0,
    @SerialName("view_count") val viewCount: Int = 0,
    @SerialName("created_at") val createdAt: String = ""
)

/**
 * Reels (0050_reels.sql) -- primera UI de cliente real sobre el backend de
 * la ronda anterior (tabla + RLS + contadores + avisos ya construidos y
 * verificados con 79/79 tests, pero sin ningún punto de la interfaz que
 * los usara). Mismo patrón exacto que HomeViewModel (feed de posts):
 * bloqueo de cliente, autores resueltos en lote, likes con toggle
 * optimista.
 */
class ReelsViewModel : ViewModel() {

    private val _reels = MutableStateFlow<List<Reel>>(emptyList())
    val reels: StateFlow<List<Reel>> = _reels.asStateFlow()

    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    private val _likedReelIds = MutableStateFlow<Set<String>>(emptySet())
    val likedReelIds: StateFlow<Set<String>> = _likedReelIds.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading: StateFlow<Boolean> = _isUploading.asStateFlow()

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    @Serializable
    private data class NewReelLike(
        @SerialName("reel_id") val reelId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class LikedReelRow(@SerialName("reel_id") val reelId: String)

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                // Mismo refuerzo de privacidad ya aplicado en Home/Match/
                // Find/Search: RLS (reels_select) no sabe nada de `blocks`.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                _reels.value = SupabaseManager.client.from("reels")
                    .select {
                        order("created_at", Order.DESCENDING)
                        limit(30)
                    }
                    .decodeList<Reel>()
                    .filter { it.authorId !in blockedIds }

                val authorIds = _reels.value.map { it.authorId }.distinct()
                if (authorIds.isNotEmpty()) {
                    _authorProfiles.value = SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                            filter { isIn("id", authorIds) }
                        }
                        .decodeList<Profile>()
                        .associateBy { it.id }
                }

                if (myId != null) {
                    _likedReelIds.value = SupabaseManager.client.from("reel_likes")
                        .select(columns = Columns.raw("reel_id")) { filter { eq("user_id", myId) } }
                        .decodeList<LikedReelRow>()
                        .map { it.reelId }
                        .toSet()
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los reels."
            } finally {
                _isLoading.value = false
            }
        }
    }

    /** Mismo patrón exacto que HomeViewModel.toggleLike(), aplicado a
     * reel_likes en vez de likes. */
    fun toggleLike(reel: Reel) {
        val currentlyLiked = _likedReelIds.value.contains(reel.id)
        _likedReelIds.update { if (currentlyLiked) it - reel.id else it + reel.id }
        _reels.update { list ->
            list.map {
                if (it.id == reel.id) it.copy(likeCount = (it.likeCount + if (currentlyLiked) -1 else 1).coerceAtLeast(0))
                else it
            }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyLiked) {
                    SupabaseManager.client.from("reel_likes").delete {
                        filter { eq("reel_id", reel.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("reel_likes").insert(NewReelLike(reel.id, userId))
                    com.social.app.backend.AnalyticsManager.track("reel_liked")
                }
            } catch (e: Exception) {
                // Restricción unique(reel_id, user_id): si ya existía el
                // like, Postgrest devuelve un 409 -- el estado deseado ya
                // se cumple, mismo criterio que HomeViewModel.toggleLike().
            }
        }
    }

    /** Mismo patrón exacto que HomeViewModel.commentAdded()/commentRemoved(),
     * para que ReelsScreen refleje el contador sin recargar todo el feed. */
    fun commentAdded(reelId: String) {
        _reels.update { list ->
            list.map { if (it.id == reelId) it.copy(commentCount = it.commentCount + 1) else it }
        }
    }

    fun commentRemoved(reelId: String) {
        _reels.update { list ->
            list.map { if (it.id == reelId) it.copy(commentCount = (it.commentCount - 1).coerceAtLeast(0)) else it }
        }
    }

    @Serializable
    private data class NewReel(
        @SerialName("author_id") val authorId: String,
        @SerialName("video_url") val videoUrl: String,
        val caption: String?,
        @SerialName("is_social_only") val isSocialOnly: Boolean
    )

    /** Sube el vídeo real al bucket `media` (StorageUploader.uploadVideo,
     * mismo patrón que las fotos de publicaciones) e inserta la fila real
     * en `reels`. Sin miniatura real todavía: `thumbnail_url` se deja sin
     * fijar -- generar un fotograma real necesitaría decodificar el vídeo
     * (MediaMetadataRetriever), hueco real documentado, no fingido con un
     * color aleatorio. */
    fun upload(context: Context, videoUri: Uri, caption: String, isSocialOnly: Boolean, onDone: (Boolean) -> Unit) {
        viewModelScope.launch {
            _isUploading.value = true
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: run {
                    onDone(false)
                    return@launch
                }
                val videoUrl = StorageUploader.uploadVideo(context, videoUri, userId)
                SupabaseManager.client.from("reels").insert(NewReel(userId, videoUrl, caption.ifBlank { null }, isSocialOnly))
                com.social.app.backend.AnalyticsManager.track("reel_created")
                load()
                onDone(true)
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo publicar el reel."
                onDone(false)
            } finally {
                _isUploading.value = false
            }
        }
    }
}
