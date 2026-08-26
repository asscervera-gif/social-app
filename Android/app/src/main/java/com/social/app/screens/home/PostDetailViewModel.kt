package com.social.app.screens.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Post
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

/**
 * Publicación individual real ("permalink"), comparado con Instagram/
 * Twitter/Facebook: ninguna de las dos apps tenía una pantalla que
 * mostrara UNA publicación fuera del feed -- ni el feed la tenía, ni
 * tocar un aviso de "like"/"comentario" llevaba a ningún sitio (tap
 * muerto, ver AvisosScreen.kt/AvisosViewModel.kt, a pesar de que
 * `notifications.payload.post_id` ya existe desde 0007/0008). Reutiliza
 * el mismo toggle de like/guardar que HomeViewModel.kt, pero operando
 * sobre una sola publicación en vez de una lista completa (no reutilizable
 * tal cual: HomeViewModel muta `_feed`, aquí solo hay `_post`).
 */
class PostDetailViewModel(private val postId: String) : ViewModel() {

    private val _post = MutableStateFlow<Post?>(null)
    val post: StateFlow<Post?> = _post.asStateFlow()

    private val _author = MutableStateFlow<Profile?>(null)
    val author: StateFlow<Profile?> = _author.asStateFlow()

    private val _extraMedia = MutableStateFlow<List<String>>(emptyList())
    val extraMedia: StateFlow<List<String>> = _extraMedia.asStateFlow()

    private val _isLiked = MutableStateFlow(false)
    val isLiked: StateFlow<Boolean> = _isLiked.asStateFlow()

    private val _isSaved = MutableStateFlow(false)
    val isSaved: StateFlow<Boolean> = _isSaved.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            try {
                val post = SupabaseManager.client.from("posts")
                    .select { filter { eq("id", postId) } }
                    .decodeSingle<Post>()
                _post.value = post

                _author.value = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                        filter { eq("id", post.authorId) }
                    }
                    .decodeSingle<Profile>()

                // Carrusel de varias fotos (post_media), mismo patrón exacto
                // que HomeViewModel.kt.load() pero filtrado a un solo post.
                _extraMedia.value = SupabaseManager.client.from("post_media")
                    .select(columns = Columns.raw("media_url")) {
                        filter { eq("post_id", postId) }
                        order("position", Order.ASCENDING)
                    }
                    .decodeList<ExtraMediaRow>()
                    .map { it.mediaUrl }

                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id
                if (userId != null) {
                    _isLiked.value = SupabaseManager.client.from("likes")
                        .select(columns = Columns.raw("post_id")) { filter { eq("post_id", postId); eq("user_id", userId) } }
                        .decodeList<LikeRow>().isNotEmpty()
                    _isSaved.value = SupabaseManager.client.from("saved_posts")
                        .select(columns = Columns.raw("post_id")) { filter { eq("post_id", postId); eq("user_id", userId) } }
                        .decodeList<SavedPostRow>().isNotEmpty()
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la publicación."
            }
        }
    }

    @Serializable
    private data class ExtraMediaRow(@SerialName("media_url") val mediaUrl: String)

    @Serializable
    private data class LikeRow(@SerialName("post_id") val postId: String)

    @Serializable
    private data class SavedPostRow(@SerialName("post_id") val postId: String)

    @Serializable
    private data class NewLike(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class NewSavedPost(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    /** Mismo criterio exacto que HomeViewModel.kt.toggleLike() (chat 1:1 de
     * "posts"), operando sobre `_post` en vez de una lista completa. */
    fun toggleLike() {
        val current = _post.value ?: return
        val currentlyLiked = _isLiked.value
        _isLiked.value = !currentlyLiked
        _post.update { it?.copy(likeCount = (it.likeCount + if (currentlyLiked) -1 else 1).coerceAtLeast(0)) }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyLiked) {
                    SupabaseManager.client.from("likes").delete {
                        filter { eq("post_id", current.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("likes").insert(NewLike(current.id, userId))
                    com.social.app.backend.AnalyticsManager.track("post_liked")
                }
            } catch (e: Exception) {
                // Restricción unique(post_id, user_id): el estado deseado ya
                // se cumple, mismo criterio que HomeViewModel.kt.toggleLike().
            }
        }
    }

    fun toggleSave() {
        val current = _post.value ?: return
        val currentlySaved = _isSaved.value
        _isSaved.value = !currentlySaved
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlySaved) {
                    SupabaseManager.client.from("saved_posts").delete {
                        filter { eq("post_id", current.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("saved_posts").insert(NewSavedPost(current.id, userId))
                    com.social.app.backend.AnalyticsManager.track("post_saved")
                }
            } catch (e: Exception) {
                // Restricción unique(post_id, user_id): el estado deseado ya
                // se cumple, mismo criterio que HomeViewModel.kt.toggleSave().
            }
        }
    }

    fun commentAdded() {
        _post.update { it?.copy(commentCount = it.commentCount + 1) }
    }

    fun commentRemoved() {
        _post.update { it?.copy(commentCount = (it.commentCount - 1).coerceAtLeast(0)) }
    }
}
