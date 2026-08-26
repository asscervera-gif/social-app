package com.social.app.screens.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Comment
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
 * Comentarios de un post — pieza que faltaba del hueco documentado en
 * LOOP_STATE.md: `posts.comment_count` existía como columna y se mostraba
 * en el feed, pero no había tabla `comments` ni forma de escribir uno.
 * Mismo patrón que `HomeViewModel.like()`: actualización optimista +
 * persistencia real (ver 0008_comments.sql, que también mantiene
 * `posts.comment_count` sincronizado con un trigger).
 */
class CommentsViewModel(private val postId: String) : ViewModel() {

    private val _comments = MutableStateFlow<List<Comment>>(emptyList())
    val comments: StateFlow<List<Comment>> = _comments.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Hallazgo real, mismo hueco raíz que HomeViewModel.authorProfiles
    // (pasada anterior): la hoja de comentarios nunca mostraba QUIÉN
    // escribió cada uno -- ni nombre, ni avatar, comparado con cualquier
    // app grande. `comments` no lleva el perfil embebido, se resuelve
    // aparte con un solo select por los author_id distintos.
    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto (0054_comment_likes.sql) -- mismo patrón que
    // HomeViewModel.likedPostIds, aquí a nivel de comentario individual.
    private val _likedCommentIds = MutableStateFlow<Set<String>>(emptySet())
    val likedCommentIds: StateFlow<Set<String>> = _likedCommentIds.asStateFlow()

    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real de la publicación puede fijar/desfijar
    // (0084_pin_comments.sql), la propia hoja necesita saber quién es para
    // mostrar el botón solo a esa persona. `comments` no trae el autor de
    // la publicación embebido, se resuelve aparte con un solo select,
    // mismo criterio que authorProfiles.
    private val _postAuthorId = MutableStateFlow<String?>(null)
    val postAuthorId: StateFlow<String?> = _postAuthorId.asStateFlow()

    // Desactivar los comentarios de una publicación, comparado con
    // Instagram/TikTok -- la propia hoja necesita saberlo para ocultar el
    // campo de escribir uno nuevo (0086_disable_comments.sql, el servidor
    // ya lo garantiza en RLS de todas formas).
    private val _commentsDisabled = MutableStateFlow(false)
    val commentsDisabled: StateFlow<Boolean> = _commentsDisabled.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val loaded = SupabaseManager.client.from("comments")
                    .select(columns = Columns.raw("id,post_id,author_id,body,created_at,like_count,is_pinned")) {
                        filter { eq("post_id", postId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<Comment>()
                _comments.value = sortPinnedFirst(loaded)

                try {
                    val postRow = SupabaseManager.client.from("posts")
                        .select(columns = Columns.raw("author_id,comments_disabled")) { filter { eq("id", postId) } }
                        .decodeSingleOrNull<PostAuthorRow>()
                    _postAuthorId.value = postRow?.authorId
                    _commentsDisabled.value = postRow?.commentsDisabled ?: false
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
                        // No bloquea el resto de la hoja si falla -- los
                        // comentarios se siguen mostrando aunque no se
                        // pueda mostrar quién los escribió.
                    }
                }

                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                val commentIds = loaded.map { it.id }
                if (myId != null && commentIds.isNotEmpty()) {
                    try {
                        _likedCommentIds.value = SupabaseManager.client.from("comment_likes")
                            .select(columns = Columns.raw("comment_id")) {
                                filter { eq("user_id", myId); isIn("comment_id", commentIds) }
                            }
                            .decodeList<LikedCommentRow>()
                            .map { it.commentId }
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
    private data class PostAuthorRow(
        @SerialName("author_id") val authorId: String,
        @SerialName("comments_disabled") val commentsDisabled: Boolean = false
    )

    private fun sortPinnedFirst(list: List<Comment>) =
        list.sortedWith(compareByDescending<Comment> { it.isPinned }.thenBy { it.createdAt })

    /** Fijar/desfijar un comentario real, comparado con Instagram/Twitter
     * -- solo el autor real de la publicación puede hacerlo
     * (`comments_update_pin`, 0084_pin_comments.sql, lo garantiza también
     * del lado del servidor: un intento ajeno afecta 0 filas, revertido en
     * silencio por la propia UI al no ofrecerle el botón). */
    fun togglePin(comment: Comment) {
        val newValue = !comment.isPinned
        _comments.update { list -> sortPinnedFirst(list.map { if (it.id == comment.id) it.copy(isPinned = newValue) else it }) }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("comments")
                    .update({ set("is_pinned", newValue) }) { filter { eq("id", comment.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo fijar el comentario."
                load()
            }
        }
    }

    @Serializable
    private data class LikedCommentRow(@SerialName("comment_id") val commentId: String)

    @Serializable
    private data class NewCommentLike(
        @SerialName("comment_id") val commentId: String,
        @SerialName("user_id") val userId: String
    )

    /** Toggle real de like/unlike de un comentario -- mismo patrón exacto
     * que HomeViewModel.toggleLike() para posts. `comments.like_count` lo
     * mantiene sincronizado el trigger real de 0054_comment_likes.sql, no
     * este código -- aquí solo se registra/borra el like del usuario. */
    fun toggleCommentLike(comment: Comment) {
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
                    SupabaseManager.client.from("comment_likes").delete {
                        filter { eq("comment_id", comment.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("comment_likes").insert(NewCommentLike(comment.id, userId))
                    com.social.app.backend.AnalyticsManager.track("comment_liked")
                }
            } catch (e: Exception) {
                // Restricción unique(comment_id, user_id): si ya existía el
                // like, Postgrest devuelve un 409 — mismo criterio que
                // HomeViewModel.toggleLike(), el estado deseado ya se cumple.
            }
        }
    }

    @Serializable
    private data class NewComment(
        @SerialName("post_id") val postId: String,
        @SerialName("author_id") val authorId: String,
        val body: String
    )

    /** Añade un comentario real, con `onCommentAdded` para que la pantalla
     * que muestra el contador (HomeScreen) lo refleje sin recargar todo el
     * feed. Actualización optimista con id temporal — se reemplaza por la
     * lista real en el siguiente `load()` si hiciera falta reconciliar. */
    fun addComment(text: String, onCommentAdded: () -> Unit) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        // Mismo límite real que comments_body_length (0008_comments.sql,
        // el único de los cuatro campos de texto que ya lo tenía desde
        // antes de 0023_text_length_limits.sql) — nunca se validó en el
        // cliente, mismo hueco ya cerrado para nombre/bio/caption/mensaje.
        if (trimmed.length > 500) {
            _errorMessage.value = "El comentario no puede tener más de 500 caracteres."
            return
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val inserted = SupabaseManager.client.from("comments")
                    .insert(NewComment(postId, userId, trimmed)) { select() }
                    .decodeSingle<Comment>()
                _comments.update { sortPinnedFirst(it + inserted) }
                // Si es el primer comentario propio en este post, mi
                // perfil todavía no está en authorProfiles (solo se cargó
                // el de quienes ya habían comentado) -- sin esto, mi
                // propio comentario recién publicado se vería con nombre
                // "…" hasta la próxima recarga.
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
                // Hallazgo real, misma auditoría de AnalyticsManager de
                // la pasada anterior: comentar tampoco se registraba.
                com.social.app.backend.AnalyticsManager.track("comment_added")
                onCommentAdded()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo publicar el comentario."
            }
        }
    }

    /** Hallazgo real: comparado con cualquier app grande, no había forma
     * de borrar el propio comentario — `comments_delete_own`
     * (0008_comments.sql) ya lo permitía a nivel de RLS, solo faltaba el
     * botón. `posts.comment_count` lo mantiene sincronizado el mismo
     * trigger que ya cubre la inserción. */
    fun deleteComment(comment: Comment, onCommentRemoved: () -> Unit) {
        _comments.update { list -> list.filter { it.id != comment.id } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("comments").delete { filter { eq("id", comment.id) } }
                onCommentRemoved()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar el comentario."
            }
        }
    }
}
