package com.social.app.screens.home

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import com.social.app.backend.StorageUploader
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Post
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
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
        @SerialName("media_url") val mediaUrl: String? = null,
        @SerialName("tagged_profile_id") val taggedProfileId: String? = null,
        // Etiqueta de ubicación real (texto libre, no geocodificado),
        // comparado con Instagram/Facebook/Twitter/Snapchat -- ver
        // 0095_post_location_tag.sql.
        @SerialName("location_name") val locationName: String? = null,
        // Marcar contenido como sensible, comparado con Instagram/
        // Twitter/TikTok -- ver 0096_sensitive_content.sql.
        @SerialName("is_sensitive") val isSensitive: Boolean = false,
        // "¿Quién puede comentar?" real, comparado con Twitter/X/TikTok
        // -- ver 0097_reply_audience.sql.
        @SerialName("reply_audience") val replyAudience: String = "everyone"
    )

    // Borrador de publicación no enviada, comparado con Instagram/Twitter/
    // X -- ver 0128_post_drafts.sql. Alcance deliberado: solo texto
    // (caption/location_name/is_sensitive), sin fotos elegidas (Uri
    // locales que no sobreviven a un reinicio real de la app).
    @Serializable
    data class PostDraft(
        val caption: String,
        @SerialName("location_name") val locationName: String? = null,
        @SerialName("is_sensitive") val isSensitive: Boolean = false
    )

    @Serializable
    private data class UpsertDraft(
        @SerialName("author_id") val authorId: String,
        val caption: String,
        @SerialName("location_name") val locationName: String?,
        @SerialName("is_sensitive") val isSensitive: Boolean
    )

    suspend fun loadDraft(): PostDraft? {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return null
        return try {
            SupabaseManager.client.from("post_drafts")
                .select { filter { eq("author_id", userId) } }
                .decodeSingleOrNull<PostDraft>()
        } catch (e: Exception) {
            null
        }
    }

    suspend fun saveDraft(caption: String, locationName: String?, isSensitive: Boolean) {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
        if (caption.isBlank()) return
        try {
            SupabaseManager.client.from("post_drafts")
                .upsert(UpsertDraft(userId, caption, locationName?.trim()?.ifEmpty { null }, isSensitive), onConflict = "author_id")
        } catch (e: Exception) {
            // Sin bloqueo real: perder un borrador no es tan grave como
            // perder una publicación real ya enviada.
        }
    }

    suspend fun discardDraft() {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
        try {
            SupabaseManager.client.from("post_drafts").delete { filter { eq("author_id", userId) } }
        } catch (e: Exception) {
        }
    }

    @Serializable
    private data class NewPostMedia(
        @SerialName("post_id") val postId: String,
        @SerialName("media_url") val mediaUrl: String,
        val position: Int
    )

    // Encuesta real en una publicación normal, comparado con Twitter/X/
    // Facebook -- ver 0113_post_polls.sql.
    @Serializable
    private data class NewPostPoll(
        @SerialName("post_id") val postId: String,
        val question: String,
        val options: List<String>
    )

    /** [imageUris] es opcional (lista vacía) a propósito: `posts.media_url`
     * es nullable (0001_schema.sql), así que una publicación de solo texto
     * sigue siendo válida — la foto es un extra, no un requisito. Ver
     * StorageUploader.kt para el hallazgo de Storage. Comparado con
     * Instagram/Facebook: varias fotos por publicación
     * (0055_post_media.sql) -- la primera va en `posts.media_url` como
     * siempre (sin cambiar nada para quien solo muestra una miniatura),
     * el resto en `post_media`. [taggedProfileId] es opcional -- "con
     * quién" (0051_post_social_tags.sql), comparado con SOCIAL_APP.html. */
    // Publicación colaborativa real ("Collab"), comparado con Instagram --
    // ver 0142_post_collaborators.sql. Alcance acotado: solo 1 colaborador
    // por post, invitación real (no automática) que aparece como aviso
    // aparte y hace falta aceptar.
    @Serializable
    private data class NewPostCollaborator(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class UsernameRow(val id: String)

    suspend fun post(context: Context, caption: String, isSocialOnly: Boolean, imageUris: List<Uri>, taggedProfileId: String? = null, locationName: String? = null, isSensitive: Boolean = false, replyAudience: String = "everyone", pollQuestion: String = "", pollOptions: List<String> = emptyList(), collaboratorUsername: String = ""): Boolean {
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
        // Mismo límite real que posts_location_name_length
        // (0095_post_location_tag.sql).
        val trimmedLocation = locationName?.trim()?.ifEmpty { null }
        if ((trimmedLocation?.length ?: 0) > 100) {
            _errorMessage.value = "El nombre del sitio no puede tener más de 100 caracteres."
            return false
        }
        _isPosting.value = true
        return try {
            val mediaUrls = imageUris.mapNotNull { StorageUploader.uploadImage(context, it, userId) }
            val insertedPost = SupabaseManager.client.from("posts")
                .insert(NewPost(userId, caption, isSocialOnly, mediaUrls.firstOrNull(), taggedProfileId, trimmedLocation, isSensitive, replyAudience)) { select() }
                .decodeSingle<Post>()
            if (mediaUrls.size > 1) {
                val extraMedia = mediaUrls.drop(1).mapIndexed { index, url ->
                    NewPostMedia(insertedPost.id, url, index + 1)
                }
                SupabaseManager.client.from("post_media").insert(extraMedia)
            }
            // Encuesta real, comparado con Twitter/X/Facebook -- mismo
            // límite real del CHECK de post_polls.question (200
            // caracteres) y de options (2 a 4), 0113_post_polls.sql.
            val trimmedPollQuestion = pollQuestion.trim().take(200)
            val cleanOptions = pollOptions.map { it.trim() }.filter { it.isNotEmpty() }
            if (trimmedPollQuestion.isNotEmpty() && cleanOptions.size in 2..4) {
                SupabaseManager.client.from("post_polls").insert(NewPostPoll(insertedPost.id, trimmedPollQuestion, cleanOptions))
            }
            val trimmedCollaborator = collaboratorUsername.trim().removePrefix("@")
            if (trimmedCollaborator.isNotEmpty()) {
                try {
                    val collaboratorId = SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("id")) { filter { eq("username", trimmedCollaborator) } }
                        .decodeSingleOrNull<UsernameRow>()
                        ?.id
                    if (collaboratorId != null) {
                        SupabaseManager.client.from("post_collaborators").insert(NewPostCollaborator(insertedPost.id, collaboratorId))
                    } else {
                        _errorMessage.value = "Publicado, pero no se encontró a @$trimmedCollaborator para invitar como colaborador."
                    }
                } catch (e: Exception) {
                    // No crítico: la publicación en sí ya se hizo real.
                }
            }
            // Hallazgo real: publicar es la acción de activación más
            // importante del feed y no se registraba — comparado con
            // otras acciones clave ya trackeadas (duel_completed,
            // social_sent, event_joined...), este hueco dejaba a
            // cualquier análisis de embudo sin el paso más básico.
            com.social.app.backend.AnalyticsManager.track("post_created")
            discardDraft()
            _isPosting.value = false
            true
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo publicar."
            _isPosting.value = false
            false
        }
    }

    // Programar la publicación de un post real para más tarde, comparado
    // con Instagram/Twitter-X/TikTok -- ver 0141_scheduled_posts.sql.
    // Alcance acotado (mismo criterio que post_drafts): solo texto + una
    // imagen ya subida, sin encuesta/varias fotos/etiqueta de perfil.
    @Serializable
    private data class NewScheduledPost(
        @SerialName("author_id") val authorId: String,
        val caption: String,
        @SerialName("is_social_only") val isSocialOnly: Boolean,
        @SerialName("media_url") val mediaUrl: String? = null,
        @SerialName("scheduled_for") val scheduledFor: String
    )

    suspend fun schedulePost(context: Context, caption: String, isSocialOnly: Boolean, imageUri: Uri?, scheduledForIso: String): Boolean {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return false
        if (caption.length > 2200) {
            _errorMessage.value = "El texto no puede tener más de 2200 caracteres."
            return false
        }
        _isPosting.value = true
        return try {
            val mediaUrl = imageUri?.let { StorageUploader.uploadImage(context, it, userId) }
            SupabaseManager.client.from("scheduled_posts")
                .insert(NewScheduledPost(userId, caption, isSocialOnly, mediaUrl, scheduledForIso))
            discardDraft()
            _isPosting.value = false
            true
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo programar la publicación."
            _isPosting.value = false
            false
        }
    }
}
