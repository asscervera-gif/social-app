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

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val loaded = SupabaseManager.client.from("comments")
                    .select(columns = Columns.raw("id,post_id,author_id,body,created_at")) {
                        filter { eq("post_id", postId) }
                        order("created_at", Order.ASCENDING)
                    }
                    .decodeList<Comment>()
                _comments.value = loaded

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
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los comentarios: ${e.message}"
            } finally {
                _isLoading.value = false
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
                _comments.update { it + inserted }
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
