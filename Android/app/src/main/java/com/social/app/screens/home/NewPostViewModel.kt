package com.social.app.screens.home

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import com.social.app.backend.StorageUploader
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Hallazgo real, otro hueco grande: no existía NINGUNA forma de crear una
 * publicación en toda la app — se podía dar like, comentar, guardar y
 * compartir publicaciones ajenas, pero nunca crear una propia. A diferencia
 * de `stories.media_url` (`not null`), `posts.media_url` es opcional
 * (0001_schema.sql) — una publicación solo de texto es válida a nivel de
 * esquema y RLS (`posts_write_own`) sin necesitar Supabase Storage, a
 * diferencia de Historias/chat multimedia.
 */
class NewPostViewModel : ViewModel() {

    private val _isPosting = MutableStateFlow(false)
    val isPosting: StateFlow<Boolean> = _isPosting.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class NewPost(
        @SerialName("author_id") val authorId: String,
        val caption: String,
        @SerialName("is_social_only") val isSocialOnly: Boolean,
        @SerialName("media_url") val mediaUrl: String? = null
    )

    /** [imageUri] es opcional a propósito: `posts.media_url` es nullable
     * (0001_schema.sql), así que una publicación de solo texto sigue siendo
     * válida — la foto es un extra, no un requisito. Ver StorageUploader.kt
     * para el hallazgo de Storage. */
    suspend fun post(context: Context, caption: String, isSocialOnly: Boolean, imageUri: Uri?): Boolean {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return false
        // Mismo límite real que posts_caption_length
        // (0023_text_length_limits.sql) — validado aquí también para dar
        // un error claro en vez de que el insert falle en silencio con el
        // mensaje genérico de más abajo, mismo criterio ya aplicado a
        // nombre/bio de perfil (PerfilViewModel.updateBasicInfo).
        if (caption.length > 2200) {
            _errorMessage.value = "El texto no puede tener más de 2200 caracteres."
            return false
        }
        _isPosting.value = true
        return try {
            val mediaUrl = imageUri?.let { StorageUploader.uploadImage(context, it, userId) }
            SupabaseManager.client.from("posts").insert(NewPost(userId, caption, isSocialOnly, mediaUrl))
            // Hallazgo real: publicar es la acción de activación más
            // importante del feed y no se registraba — comparado con
            // otras acciones clave ya trackeadas (duel_completed,
            // social_sent, event_joined...), este hueco dejaba a
            // cualquier análisis de embudo sin el paso más básico.
            com.social.app.backend.AnalyticsManager.track("post_created")
            _isPosting.value = false
            true
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo publicar."
            _isPosting.value = false
            false
        }
    }
}
