package com.social.app.screens.reels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
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
data class ReelComment(
    val id: String,
    @SerialName("reel_id") val reelId: String,
    @SerialName("author_id") val authorId: String,
    val body: String,
    @SerialName("created_at") val createdAt: String = "",
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto (0054_comment_likes.sql).
    @SerialName("like_count") val likeCount: Int = 0,
    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real del reel puede cambiarlo (0084_pin_comments.sql).
    @SerialName("is_pinned") val isPinned: Boolean = false,
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- referencia al comentario
    // real de primer nivel que se responde. Ver 0104_comment_replies.sql.
    @SerialName("parent_comment_id") val parentCommentId: String? = null
)

/**
 * Comentarios de un reel -- hueco real documentado explícitamente al
 * construir la UI de Reels: `reel_comments` (0050_reels.sql) ya existe con
 * su propio contador (`reels.comment_count`, ya visible en ReelsScreen.kt),
 * pero sin ninguna pantalla para leerlos o escribirlos. Mismo patrón
 * exacto que CommentsViewModel.kt (posts), solo cambia la tabla/columna.
 */
class ReelCommentsViewModel(private val reelId: String) : ViewModel() {

    private val _comments = MutableStateFlow<List<ReelComment>>(emptyList())
    val comments: StateFlow<List<ReelComment>> = _comments.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto de un reel (0054_comment_likes.sql), mismo patrón que
    // CommentsViewModel.likedCommentIds (posts).
    private val _likedCommentIds = MutableStateFlow<Set<String>>(emptySet())
    val likedCommentIds: StateFlow<Set<String>> = _likedCommentIds.asStateFlow()

    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real del reel puede fijar/desfijar (0084_pin_comments.sql), la
    // propia hoja necesita saber quién es para mostrar el botón solo a esa
    // persona. `reel_comments` no trae el autor del reel embebido, se
    // resuelve aparte con un solo select, mismo criterio que
    // authorProfiles.
    private val _reelAuthorId = MutableStateFlow<String?>(null)
    val reelAuthorId: StateFlow<String?> = _reelAuthorId.asStateFlow()

    // Desactivar los comentarios de un reel, comparado con Instagram/
    // TikTok -- la propia hoja necesita saberlo para ocultar el campo de
    // escribir uno nuevo (0086_disable_comments.sql, el servidor ya lo
    // garantiza en RLS de todas formas).
    private val _commentsDisabled = MutableStateFlow(false)
    val commentsDisabled: StateFlow<Boolean> = _commentsDisabled.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val loaded = SupabaseManager.client.from("reel_comments")
                    .select(columns = Columns.raw("id,reel_id,author_id,body,created_at,like_count,is_pinned,parent_comment_id")) {
                        filter { eq("reel_id", reelId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<ReelComment>()
                _comments.value = threadOrder(loaded)

                try {
                    val reelRow = SupabaseManager.client.from("reels")
                        .select(columns = Columns.raw("author_id,comments_disabled")) { filter { eq("id", reelId) } }
                        .decodeSingleOrNull<ReelAuthorRow>()
                    _reelAuthorId.value = reelRow?.authorId
                    _commentsDisabled.value = reelRow?.commentsDisabled ?: false
                } catch (e: Exception) {
                    // No crítico: sin esto solo no se muestra el botón de
                    // fijar, el resto de la hoja sigue funcionando.
                }

                val authorIds = loaded.map { it.authorId }.distinct()
                if (authorIds.isNotEmpty()) {
                    try {
                        _authorProfiles.value = SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                                filter { isIn("id", authorIds) }
                            }
                            .decodeList<Profile>()
                            .associateBy { it.id }
                    } catch (e: Exception) {
                        // No bloquea el resto de la hoja si falla.
                    }
                }

                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                val commentIds = loaded.map { it.id }
                if (myId != null && commentIds.isNotEmpty()) {
                    try {
                        _likedCommentIds.value = SupabaseManager.client.from("reel_comment_likes")
                            .select(columns = Columns.raw("reel_comment_id")) {
                                filter { eq("user_id", myId); isIn("reel_comment_id", commentIds) }
                            }
                            .decodeList<LikedReelCommentRow>()
                            .map { it.reelCommentId }
                            .toSet()
                    } catch (e: Exception) {
                        // No bloquea el resto de la hoja si falla.
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los comentarios: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }

    @Serializable
    private data class ReelAuthorRow(
        @SerialName("author_id") val authorId: String,
        @SerialName("comments_disabled") val commentsDisabled: Boolean = false
    )

    /** Responder a un comentario concreto (hilo de un nivel), comparado
     * con Instagram/Facebook/Twitter/TikTok -- mismo criterio real que
     * CommentsViewModel.kt.threadOrder() (posts). Ver
     * 0104_comment_replies.sql. */
    private fun threadOrder(list: List<ReelComment>): List<ReelComment> {
        val topLevel = list.filter { it.parentCommentId == null }
            .sortedWith(compareByDescending<ReelComment> { it.isPinned }.thenBy { it.createdAt })
        val repliesByParent = list.filter { it.parentCommentId != null }.groupBy { it.parentCommentId }
        return topLevel.flatMap { parent -> listOf(parent) + repliesByParent[parent.id].orEmpty().sortedBy { it.createdAt } }
    }

    /** Fijar/desfijar un comentario real, comparado con Instagram/Twitter
     * -- solo el autor real del reel puede hacerlo (`reel_comments_update_pin`,
     * 0084_pin_comments.sql, lo garantiza también del lado del servidor:
     * un intento ajeno afecta 0 filas, revertido en silencio por la propia
     * UI al no ofrecerle el botón). */
    fun togglePin(comment: ReelComment) {
        val newValue = !comment.isPinned
        _comments.update { list -> threadOrder(list.map { if (it.id == comment.id) it.copy(isPinned = newValue) else it }) }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reel_comments")
                    .update({ set("is_pinned", newValue) }) { filter { eq("id", comment.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo fijar el comentario."
                load()
            }
        }
    }

    @Serializable
    private data class LikedReelCommentRow(@SerialName("reel_comment_id") val reelCommentId: String)

    @Serializable
    private data class NewReelCommentLike(
        @SerialName("reel_comment_id") val reelCommentId: String,
        @SerialName("user_id") val userId: String
    )

    /** Toggle real de like/unlike de un comentario de reel -- mismo patrón
     * exacto que CommentsViewModel.toggleCommentLike() (posts). */
    fun toggleCommentLike(comment: ReelComment) {
        val currentlyLiked = _likedCommentIds.value.contains(comment.id)
        _likedCommentIds.update { if (currentlyLiked) it - comment.id else it + comment.id }
        _comments.update { list ->
            list.map {
                if (it.id == comment.id) it.copy(likeCount = (it.likeCount + if (currentlyLiked) -1 else 1).coerceAtLeast(0))
                else it
            }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyLiked) {
                    SupabaseManager.client.from("reel_comment_likes").delete {
                        filter { eq("reel_comment_id", comment.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("reel_comment_likes").insert(NewReelCommentLike(comment.id, userId))
                    com.social.app.backend.AnalyticsManager.track("reel_comment_liked")
                }
            } catch (e: Exception) {
                // Mismo criterio que CommentsViewModel.toggleCommentLike():
                // un 409 por unique(reel_comment_id, user_id) no es un error
                // real, el estado deseado ya se cumple.
            }
        }
    }

    @Serializable
    private data class NewReelComment(
        @SerialName("reel_id") val reelId: String,
        @SerialName("author_id") val authorId: String,
        val body: String,
        @SerialName("parent_comment_id") val parentCommentId: String? = null
    )

    /** [parentCommentId] es opcional -- responder a un comentario
     * concreto (hilo de un nivel), comparado con Instagram/Facebook/
     * Twitter/TikTok, mismo criterio real que CommentsViewModel.kt (posts).
     * Ver 0104_comment_replies.sql. */
    fun addComment(text: String, parentCommentId: String? = null, onCommentAdded: () -> Unit) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        // Mismo límite real que comments_body_length, reutilizado tal
        // cual para reel_comments (0050_reels.sql no define uno propio
        // distinto -- mismo esquema de columna `body text not null`).
        if (trimmed.length > 500) {
            _errorMessage.value = "El comentario no puede tener más de 500 caracteres."
            return
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val inserted = SupabaseManager.client.from("reel_comments")
                    .insert(NewReelComment(reelId, userId, trimmed, parentCommentId)) { select() }
                    .decodeSingle<ReelComment>()
                _comments.update { threadOrder(it + inserted) }
                if (!_authorProfiles.value.containsKey(userId)) {
                    try {
                        val me = SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                                filter { eq("id", userId) }
                            }
                            .decodeSingle<Profile>()
                        _authorProfiles.update { it + (userId to me) }
                    } catch (e: Exception) {
                        // No crítico: el comentario ya se publicó de verdad.
                    }
                }
                com.social.app.backend.AnalyticsManager.track("reel_comment_added")
                onCommentAdded()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo publicar el comentario."
            }
        }
    }

    fun deleteComment(comment: ReelComment, onCommentRemoved: () -> Unit) {
        // Responder a un comentario concreto (0104_comment_replies.sql):
        // `on delete cascade` real se lleva sus respuestas con él -- el
        // estado local tiene que reflejar lo mismo.
        _comments.update { list -> list.filter { it.id != comment.id && it.parentCommentId != comment.id } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reel_comments").delete { filter { eq("id", comment.id) } }
                onCommentRemoved()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar el comentario."
            }
        }
    }
}
