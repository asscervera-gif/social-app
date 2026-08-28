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
    @SerialName("created_at") val createdAt: String = "",
    // Desactivar los comentarios de un reel, comparado con Instagram/
    // TikTok -- los comentarios previos se quedan, solo se cierra la
    // puerta a comentarios NUEVOS (0086_disable_comments.sql).
    @SerialName("comments_disabled") val commentsDisabled: Boolean = false,
    // Ocultar el número de "me gusta" real, comparado con Instagram/
    // Facebook -- el autor sigue viendo su cifra real siempre, solo
    // desaparece el número para los demás (0094_hide_like_count.sql).
    @SerialName("hide_like_count") val hideLikeCount: Boolean = false,
    // Marcar contenido como sensible, comparado con Instagram/Twitter/
    // TikTok -- difumina el vídeo para cualquiera que no sea el autor
    // hasta que toque para revelarlo (0096_sensitive_content.sql).
    @SerialName("is_sensitive") val isSensitive: Boolean = false,
    // "¿Quién puede comentar?" real, comparado con Twitter/X/TikTok --
    // 'everyone'/'followers'/'mentioned' (0097_reply_audience.sql).
    @SerialName("reply_audience") val replyAudience: String = "everyone",
    // Etiqueta de ubicación real (texto libre, no geocodificado),
    // comparado con Instagram/TikTok -- mismo diseño exacto que
    // posts.locationName, ver 0114_reel_location_tag.sql.
    @SerialName("location_name") val locationName: String? = null,
    // Sonido de un reel reutilizable ("usar este sonido") + "Reels con
    // este sonido", comparado con TikTok/Instagram Reels -- ver
    // 0150_reel_sounds.sql. Siempre apunta directo a la raíz real de la
    // cadena (nunca a un eslabón intermedio), normalizado por el propio
    // servidor al insertar.
    @SerialName("sound_source_reel_id") val soundSourceReelId: String? = null,
    @SerialName("sound_use_count") val soundUseCount: Int = 0
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

    // Silenciar palabras reales en TU PROPIO feed, comparado con
    // Twitter/X -- cierra el "hueco real aparte" documentado en la ronda
    // de 0116_muted_feed_keywords.sql (solo cubrió el feed principal de
    // publicaciones, nunca reels). Mismo criterio exacto que
    // HomeViewModel.kt: resuelto en cliente, nunca en RLS.
    @Serializable
    private data class MutedFeedKeywordsRow(@SerialName("muted_feed_keywords") val mutedFeedKeywords: List<String> = emptyList())

    @Serializable
    private data class MutedAccountRow(@SerialName("muted_id") val mutedId: String)

    @Serializable
    private data class NewReelLike(
        @SerialName("reel_id") val reelId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class LikedReelRow(@SerialName("reel_id") val reelId: String)

    /** Abrir un reel concreto real desde un aviso de "like"/"comentario",
     * comparado con Instagram/TikTok: `reel_like`/`reel_comment`/
     * `reel_comment_like` ya llevan `reel_id` real en su payload
     * (0050_reels.sql / 0070_notify_comment_like_post_reference.sql), pero
     * tocar el aviso no llevaba a ningún sitio porque `load()` solo trae
     * los 30 reels más recientes -- el reel real del aviso podría no estar
     * ahí (o directamente no estarlo nunca, si hay más de 30 reels más
     * nuevos). Si no aparece en esa ventana, se pide aparte y se antepone
     * a la lista -- mismo criterio de "solo lo necesario" que
     * PostDetailViewModel.kt (no reconstruye el feed entero para una sola
     * pieza de contenido). Sujeto a las mismas reglas RLS/bloqueo reales
     * que el resto del feed: si la política lo deniega, sencillamente no
     * se añade (fallo silencioso, no un crash).
     */
    /** ["soundFilterReelId"] real -- "Reels con este sonido", comparado
     * con TikTok/Instagram Reels: en vez de los 30 más recientes de todo
     * el feed, trae solo los reels reales que comparten ese sonido
     * (`sound_source_reel_id` ya normalizado a la raíz por el propio
     * servidor, ver 0150_reel_sounds.sql) -- una sola consulta plana,
     * sin recursión en el cliente. */
    fun load(pinnedReelId: String? = null, soundFilterReelId: String? = null) {
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
                val mutedFeedKeywords = try {
                    if (myId == null) emptyList() else SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("muted_feed_keywords")) { filter { eq("id", myId) } }
                        .decodeSingleOrNull<MutedFeedKeywordsRow>()
                        ?.mutedFeedKeywords ?: emptyList()
                } catch (e: Exception) {
                    emptyList()
                }
                // Silenciar una cuenta real, comparado con
                // Instagram/Twitter/X/Facebook -- cierra el "hueco real
                // aparte" del mismo tipo ya documentado para
                // mutedFeedKeywords: se extiende a Reels con el mismo
                // criterio exacto. Ver SafetyManager.muteAccount(),
                // 0126_muted_accounts.sql.
                val mutedAccountIds = try {
                    SupabaseManager.client.from("muted_accounts")
                        .select(columns = Columns.raw("muted_id"))
                        .decodeList<MutedAccountRow>()
                        .map { it.mutedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                val recentReels = SupabaseManager.client.from("reels")
                    .select {
                        if (soundFilterReelId != null) {
                            filter { or { eq("sound_source_reel_id", soundFilterReelId); eq("id", soundFilterReelId) } }
                        }
                        order("created_at", Order.DESCENDING)
                        limit(30)
                    }
                    .decodeList<Reel>()
                    .filter {
                        it.authorId !in blockedIds && it.authorId !in mutedAccountIds &&
                            mutedFeedKeywords.none { word -> it.caption?.contains(word, ignoreCase = true) == true }
                    }

                _reels.value = if (pinnedReelId != null && recentReels.none { it.id == pinnedReelId }) {
                    val pinned = try {
                        SupabaseManager.client.from("reels")
                            .select { filter { eq("id", pinnedReelId) } }
                            .decodeSingle<Reel>()
                            .takeIf { it.authorId !in blockedIds }
                    } catch (e: Exception) {
                        null
                    }
                    if (pinned != null) listOf(pinned) + recentReels else recentReels
                } else {
                    recentReels
                }

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

    @Serializable
    private data class NewReelView(
        @SerialName("reel_id") val reelId: String,
        @SerialName("viewer_id") val viewerId: String
    )

    private val viewedReelIdsThisSession = mutableSetOf<String>()

    /** Contador real de vistas, comparado con TikTok/Instagram Reels --
     * hallazgo real: `view_count` existía desde 0050_reels.sql y ya se
     * mostraba en pantalla, pero ningún sitio del código lo incrementaba
     * jamás (RLS bloqueaba un UPDATE directo). Ver 0131_reel_view_count.sql
     * -- `reel_views` (unique por espectador) + trigger real que
     * incrementa `reels.view_count`. `viewedReelIdsThisSession` evita
     * repetir el insert (y el 409 esperado de la unique constraint) cada
     * vez que el usuario vuelve a pasar por el mismo reel en la sesión. */
    fun trackView(reel: Reel) {
        if (!viewedReelIdsThisSession.add(reel.id)) return
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("reel_views").insert(NewReelView(reel.id, userId))
                _reels.update { list -> list.map { if (it.id == reel.id) it.copy(viewCount = it.viewCount + 1) else it } }
            } catch (e: Exception) {
                // Restricción unique(reel_id, viewer_id): si ya existía la
                // vista (de una sesión anterior), el estado deseado ya se
                // cumple -- mismo criterio que toggleLike().
            }
        }
    }

    /** Desactivar los comentarios de un reel propio real, comparado con
     * Instagram/TikTok -- los comentarios que ya existían se quedan tal
     * cual, solo se cierra la puerta a comentarios NUEVOS
     * (`reel_comments_insert_own`, 0086_disable_comments.sql, lo
     * garantiza también del lado del servidor). `reels_write_own` ya es
     * `for all`, mismo criterio que toggleArchive() en posts: sin
     * política RLS nueva. */
    fun toggleCommentsDisabled(reel: Reel) {
        val newValue = !reel.commentsDisabled
        _reels.update { list -> list.map { if (it.id == reel.id) it.copy(commentsDisabled = newValue) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reels")
                    .update({ set("comments_disabled", newValue) }) { filter { eq("id", reel.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el estado de los comentarios."
                load()
            }
        }
    }

    /** Ocultar el número de "me gusta" real, comparado con Instagram/
     * Facebook -- el propio autor sigue viendo su cifra real siempre,
     * solo desaparece para los demás (0094_hide_like_count.sql).
     * `reels_write_own` ya es `for all`, mismo criterio que
     * toggleCommentsDisabled(): sin política RLS nueva. */
    fun toggleHideLikeCount(reel: Reel) {
        val newValue = !reel.hideLikeCount
        _reels.update { list -> list.map { if (it.id == reel.id) it.copy(hideLikeCount = newValue) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reels")
                    .update({ set("hide_like_count", newValue) }) { filter { eq("id", reel.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar la visibilidad del número de me gusta."
                load()
            }
        }
    }

    /** Marcar contenido como sensible, comparado con Instagram/Twitter/
     * TikTok -- ver 0096_sensitive_content.sql. `reels_write_own` ya es
     * `for all`, mismo criterio que toggleHideLikeCount(): sin política
     * RLS nueva. */
    fun toggleSensitive(reel: Reel) {
        val newValue = !reel.isSensitive
        _reels.update { list -> list.map { if (it.id == reel.id) it.copy(isSensitive = newValue) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reels")
                    .update({ set("is_sensitive", newValue) }) { filter { eq("id", reel.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar la marca de contenido sensible."
                load()
            }
        }
    }

    /** "¿Quién puede comentar?" real, comparado con Twitter/X/TikTok --
     * ver 0097_reply_audience.sql. `reels_write_own` ya es `for all`,
     * mismo criterio que toggleSensitive(): sin política RLS nueva. */
    fun cycleReplyAudience(reel: Reel) {
        val newValue = when (reel.replyAudience) {
            "everyone" -> "followers"
            "followers" -> "mentioned"
            else -> "everyone"
        }
        _reels.update { list -> list.map { if (it.id == reel.id) it.copy(replyAudience = newValue) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reels")
                    .update({ set("reply_audience", newValue) }) { filter { eq("id", reel.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar quién puede comentar."
                load()
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
        @SerialName("is_social_only") val isSocialOnly: Boolean,
        @SerialName("location_name") val locationName: String? = null,
        @SerialName("thumbnail_url") val thumbnailUrl: String? = null,
        // Sonido de un reel reutilizable ("usar este sonido"), comparado
        // con TikTok/Instagram Reels -- ver 0150_reel_sounds.sql.
        @SerialName("sound_source_reel_id") val soundSourceReelId: String? = null
    )

    /** Sube el vídeo real al bucket `media` (StorageUploader.uploadVideo,
     * mismo patrón que las fotos de publicaciones) e inserta la fila real
     * en `reels`. Miniatura real, comparado con TikTok/Instagram Reels/
     * YouTube Shorts -- cierra el hueco deliberado documentado antes:
     * `thumbnail_url` se dejaba siempre sin fijar. Ver
     * StorageUploader.uploadVideoThumbnail(). Si falla (vídeo sin
     * fotograma decodificable), el reel se sigue publicando igual, solo
     * sin miniatura real -- nunca bloquea la publicación por esto. */
    fun upload(context: Context, videoUri: Uri, caption: String, isSocialOnly: Boolean, locationName: String = "", soundSourceReelId: String? = null, onDone: (Boolean) -> Unit) {
        viewModelScope.launch {
            _isUploading.value = true
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: run {
                    onDone(false)
                    return@launch
                }
                // Mismo límite real que reels_location_name_length
                // (0114_reel_location_tag.sql).
                val trimmedLocation = locationName.trim().ifEmpty { null }?.take(100)
                val videoUrl = StorageUploader.uploadVideo(context, videoUri, userId)
                val thumbnailUrl = try {
                    StorageUploader.uploadVideoThumbnail(context, videoUri, userId)
                } catch (e: Exception) {
                    null
                }
                SupabaseManager.client.from("reels").insert(NewReel(userId, videoUrl, caption.ifBlank { null }, isSocialOnly, trimmedLocation, thumbnailUrl, soundSourceReelId))
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
