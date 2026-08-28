package com.social.app.screens.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Post
import com.social.app.backend.model.Profile
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Equivalente Kotlin de HomeViewModel.swift: feed y recomendados (sin
 * Historias — no implementadas en ninguna plataforma, ver corrección de
 * honestidad en HomeView.swift/HomeScreen.kt). */
class HomeViewModel : ViewModel() {

    data class Recommended(val profile: Profile, val compatibility: Int?, val requestSent: Boolean = false)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    @Serializable
    private data class MutedFeedKeywordsRow(@SerialName("muted_feed_keywords") val mutedFeedKeywords: List<String> = emptyList())

    @Serializable
    private data class MutedAccountRow(@SerialName("muted_id") val mutedId: String)

    private val _feed = MutableStateFlow<List<Post>>(emptyList())
    val feed: StateFlow<List<Post>> = _feed.asStateFlow()

    private val _recommended = MutableStateFlow<List<Recommended>>(emptyList())
    val recommended: StateFlow<List<Recommended>> = _recommended.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var cachedMyInterests: Set<String> = emptySet()

    private val _savedPostIds = MutableStateFlow<Set<String>>(emptySet())
    val savedPostIds: StateFlow<Set<String>> = _savedPostIds.asStateFlow()

    // Hallazgo real: no había forma de quitar un like, comparado con
    // cualquier app grande — `like()` solo incrementaba el contador local
    // para siempre, mientras `likes` (constraint unique) se quedaba en una
    // sola fila real. El corazón nunca reflejaba si YA le habías dado
    // like. Ver toggleLike() más abajo.
    private val _likedPostIds = MutableStateFlow<Set<String>>(emptySet())
    val likedPostIds: StateFlow<Set<String>> = _likedPostIds.asStateFlow()

    // Repostear una publicación real, comparado con Twitter/X/Facebook --
    // ver 0127_post_reposts.sql. Alcance deliberado de esta ronda: el
    // repost real ya se guarda/cuenta/notifica de verdad, pero el feed
    // principal todavía no mezcla los reposts de gente que sigo (mismo
    // criterio de fase inicial ya usado varias veces esta sesión, p. ej.
    // muted_feed_keywords 0116 solo cubrió el feed antes de extenderse a
    // Reels) -- hueco real aparte para una ronda futura.
    private val _repostedPostIds = MutableStateFlow<Set<String>>(emptySet())
    val repostedPostIds: StateFlow<Set<String>> = _repostedPostIds.asStateFlow()

    private val _repostCounts = MutableStateFlow<Map<String, Int>>(emptyMap())
    val repostCounts: StateFlow<Map<String, Int>> = _repostCounts.asStateFlow()

    // Hallazgo real, comparado con cualquier app grande: la tarjeta del
    // feed nunca mostraba QUIÉN publicó cada post -- ni nombre, ni avatar,
    // ni forma de tocar para ver su perfil. A diferencia de Search/Match/
    // Avisos (los tres sí llevan onOpenProfile), Home era la única
    // pantalla con listado sin esa navegación. `posts` no lleva el perfil
    // embebido, así que se resuelve aparte con un solo select por los
    // author_id distintos del feed cargado (no N+1).
    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    // Comparado con Instagram/Facebook: publicaciones con varias fotos
    // (0055_post_media.sql) -- `post.mediaUrl` sigue siendo la primera,
    // aquí solo las adicionales, indexadas por post para que la tarjeta
    // sepa si debe mostrar un carrusel o una sola imagen.
    @Serializable
    private data class PostMediaRow(
        @SerialName("post_id") val postId: String,
        @SerialName("media_url") val mediaUrl: String
    )
    private val _extraMediaByPost = MutableStateFlow<Map<String, List<String>>>(emptyMap())
    val extraMediaByPost: StateFlow<Map<String, List<String>>> = _extraMediaByPost.asStateFlow()

    // Encuesta real en una publicación normal, comparado con Twitter/X/
    // Facebook -- ver 0113_post_polls.sql, mismo diseño exacto que las
    // encuestas de historias (StoriesViewModel.storyPolls()).
    @Serializable
    data class PostPollRow(
        val id: String,
        @SerialName("post_id") val postId: String,
        val question: String,
        val options: List<String>,
        @SerialName("vote_counts") val voteCounts: List<Int> = emptyList()
    )

    @Serializable
    private data class MyPostPollVoteRow(
        @SerialName("poll_id") val pollId: String,
        @SerialName("option_index") val optionIndex: Int
    )

    @Serializable
    private data class NewPostPollVote(
        @SerialName("poll_id") val pollId: String,
        @SerialName("voter_id") val voterId: String,
        @SerialName("option_index") val optionIndex: Int
    )

    private val _postPolls = MutableStateFlow<Map<String, PostPollRow>>(emptyMap())
    val postPolls: StateFlow<Map<String, PostPollRow>> = _postPolls.asStateFlow()

    private val _myPostPollVotes = MutableStateFlow<Map<String, Int>>(emptyMap())
    val myPostPollVotes: StateFlow<Map<String, Int>> = _myPostPollVotes.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                // Publicaciones programadas reales que ya vencieron,
                // comparado con Instagram/Twitter-X/TikTok -- publicadas
                // "al abrir Home" (sin pg_cron, ver 0141_scheduled_posts.sql
                // para el porqué explícito). No crítico si falla: el
                // resto del feed sigue cargando igual.
                try {
                    SupabaseManager.client.postgrest.rpc("publish_due_scheduled_posts")
                } catch (e: Exception) { /* no crítico */ }
                // Hallazgo real: el feed principal nunca filtraba
                // publicaciones de gente que has bloqueado — a diferencia
                // de Match/Find/Search (sí lo hacen), bloquear a alguien
                // no le ocultaba sus publicaciones del feed, el sitio que
                // más se mira de toda la app. RLS (`posts_select`) no sabe
                // nada de `blocks` (refuerzo puramente de cliente, mismo
                // criterio que el resto de listados).
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                // Palabras silenciadas reales en TU PROPIO feed,
                // comparado con Twitter/X ("Muted words") -- distinto de
                // `muted_keywords` (0078, filtra comentarios AJENOS en
                // TUS publicaciones): esto oculta publicaciones AJENAS de
                // TU feed. Resuelto en cliente, nunca en RLS -- mismo
                // criterio que el filtro de `blocks` de arriba. Ver
                // 0116_muted_feed_keywords.sql.
                val mutedFeedKeywords = try {
                    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                    if (myId == null) emptyList() else SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("muted_feed_keywords")) { filter { eq("id", myId) } }
                        .decodeSingleOrNull<MutedFeedKeywordsRow>()
                        ?.mutedFeedKeywords ?: emptyList()
                } catch (e: Exception) {
                    emptyList()
                }
                // Silenciar una cuenta real, comparado con
                // Instagram/Twitter/X/Facebook -- sus publicaciones
                // dejan de verse en tu feed sin dejar de seguirla, sin
                // bloquearla y sin que se entere nunca. Resuelto en
                // cliente, nunca en RLS -- mismo criterio exacto que
                // `mutedFeedKeywords` de arriba. Ver
                // SafetyManager.muteAccount(), 0126_muted_accounts.sql.
                val mutedAccountIds = try {
                    SupabaseManager.client.from("muted_accounts")
                        .select(columns = Columns.raw("muted_id"))
                        .decodeList<MutedAccountRow>()
                        .map { it.mutedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                // Optimización: la tarjeta del feed solo usa estas 8 columnas
                // de "posts", no filas completas (mismo patrón que
                // MatchViewModel/DuelEntryPoint/AvisosViewModel).
                //
                // Archivar publicaciones real (0076_archive_posts.sql),
                // comparado con Instagram/Facebook: `posts_select` ya
                // excluye una archivada para CUALQUIER OTRO usuario, pero
                // el propio autor SIEMPRE la ve vía RLS (para poder
                // gestionarla en "Tus publicaciones") -- sin filtrar aquí
                // en cliente, el propio autor seguiría viendo su
                // publicación archivada mezclada en su propio feed
                // principal, justo lo que archivar debería evitar.
                _feed.value = SupabaseManager.client.from("posts")
                    .select(columns = Columns.raw("id,author_id,media_url,caption,is_social_only,like_count,comment_count,created_at,archived_at")) {
                        order("created_at", Order.DESCENDING)
                        limit(30)
                    }
                    .decodeList<Post>()
                    .filter {
                        it.authorId !in blockedIds && it.authorId !in mutedAccountIds && it.archivedAt == null &&
                            mutedFeedKeywords.none { word -> it.caption?.contains(word, ignoreCase = true) == true }
                    }

                val feedIds = _feed.value.map { it.id }
                if (feedIds.isNotEmpty()) {
                    try {
                        _extraMediaByPost.value = SupabaseManager.client.from("post_media")
                            .select(columns = Columns.raw("post_id,media_url")) {
                                filter { isIn("post_id", feedIds) }
                                order("position", Order.ASCENDING)
                            }
                            .decodeList<PostMediaRow>()
                            .groupBy({ it.postId }, { it.mediaUrl })
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla -- los posts
                        // se siguen mostrando con solo su primera foto.
                    }
                }

                if (feedIds.isNotEmpty()) {
                    try {
                        val polls = SupabaseManager.client.from("post_polls")
                            .select(columns = Columns.raw("id,post_id,question,options,vote_counts")) { filter { isIn("post_id", feedIds) } }
                            .decodeList<PostPollRow>()
                        _postPolls.value = polls.associateBy { it.postId }
                        val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                        _myPostPollVotes.value = if (polls.isEmpty() || myId == null) emptyMap() else try {
                            SupabaseManager.client.from("post_poll_votes")
                                .select(columns = Columns.raw("poll_id,option_index")) { filter { eq("voter_id", myId); isIn("poll_id", polls.map { it.id }) } }
                                .decodeList<MyPostPollVoteRow>()
                                .associate { it.pollId to it.optionIndex }
                        } catch (e: Exception) {
                            emptyMap()
                        }
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla -- los posts
                        // se siguen mostrando sin su encuesta.
                    }
                }

                val authorIds = _feed.value.map { it.authorId }.distinct()
                if (authorIds.isNotEmpty()) {
                    try {
                        _authorProfiles.value = SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                                filter { isIn("id", authorIds) }
                            }
                            .decodeList<Profile>()
                            .associateBy { it.id }
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla -- las
                        // publicaciones se siguen mostrando aunque no se
                        // pueda mostrar quién las escribió.
                    }
                }

                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                if (myId != null) {
                    try {
                        // Optimización: solo hace falta post_id para saber qué
                        // está guardado — RLS ya limita esto a mis propias filas.
                        _savedPostIds.value = SupabaseManager.client.from("saved_posts")
                            .select(columns = Columns.raw("post_id")) { filter { eq("user_id", myId) } }
                            .decodeList<SavedPostRow>()
                            .map { it.postId }
                            .toSet()
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla — igual que
                        // el resto de datos secundarios de esta pantalla.
                    }
                    try {
                        _likedPostIds.value = SupabaseManager.client.from("likes")
                            .select(columns = Columns.raw("post_id")) { filter { eq("user_id", myId) } }
                            .decodeList<LikedPostRow>()
                            .map { it.postId }
                            .toSet()
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla.
                    }
                    try {
                        val feedIdsForReposts = _feed.value.map { it.id }
                        if (feedIdsForReposts.isNotEmpty()) {
                            val repostRows = SupabaseManager.client.from("post_reposts")
                                .select(columns = Columns.raw("post_id,user_id")) { filter { isIn("post_id", feedIdsForReposts) } }
                                .decodeList<RepostRow>()
                            _repostedPostIds.value = repostRows.filter { it.userId == myId }.map { it.postId }.toSet()
                            _repostCounts.value = repostRows.groupingBy { it.postId }.eachCount()
                        }
                    } catch (e: Exception) {
                        // No bloquea el resto del feed si falla.
                    }
                }

                val myInterests = myId?.let { userId ->
                    try {
                        // Optimización: solo se necesita "interests" para el
                        // cálculo, pero "id" y "display_name" son campos no
                        // opcionales en Profile (sin default) — decodeSingle
                        // lanzaría MissingFieldException si se omiten.
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,interests")) { filter { eq("id", userId) } }
                            .decodeSingle<Profile>()
                            .interests
                            .toSet()
                    } catch (e: Exception) {
                        emptySet()
                    }
                } ?: emptySet()
                // Cacheado a nivel de clase -- ver compatibilityFor(), que
                // reutiliza este mismo cálculo para mostrar el % de
                // compatibilidad en la cabecera de cada post del feed, no
                // solo en la tarjeta de "Recomendados" (hallazgo real
                // comparado con SOCIAL_APP.html: el boceto muestra el %
                // también en cada publicación, no solo en el carrusel).
                cachedMyInterests = myInterests

                // `blockedIds` ya se calculó arriba (reutilizado también
                // para el feed) — mismo criterio que MatchViewModel.kt: a
                // quien bloqueas seguía apareciendo en Recomendados. Solo
                // se puede filtrar "a quién he bloqueado yo" — RLS de
                // `blocks` no deja ver quién me bloqueó a mí, límite de
                // privacidad correcto, no un hueco.

                // Misma heurística de solapamiento de intereses que
                // MatchViewModel.estimatedCompatibility, y mismo filtro de
                // invisibles/self-exclusión (ver corrección en MatchViewModel.kt).
                // Misma optimización que MatchViewModel.kt: solo se usan
                // nombre, avatar, intereses y compat_public en la tarjeta.
                val candidates = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config,interests,compat_public")) {
                        filter {
                            eq("is_invisible", false)
                            myId?.let { neq("id", it) }
                        }
                        limit(10)
                    }
                    .decodeList<Profile>()
                    .filter { it.id !in blockedIds }
                _recommended.value = candidates.map { Recommended(it, estimatedCompatibility(it, myInterests)) }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el feed: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }

    private fun estimatedCompatibility(profile: Profile, myInterests: Set<String>): Int? {
        if (!profile.compatPublic) return null
        val theirInterests = profile.interests.toSet()
        if (myInterests.isEmpty() || theirInterests.isEmpty()) return null
        val intersection = myInterests.intersect(theirInterests).size
        val union = myInterests.union(theirInterests).size
        if (union == 0) return null
        return ((intersection.toDouble() / union) * 100).toInt()
    }

    /** Expone el mismo cálculo que arriba para el autor de un post del feed
     * -- mismo criterio real que SOCIAL_APP.html (compat% en la cabecera de
     * cada publicación, no solo en "Recomendados"). */
    fun compatibilityFor(profile: Profile): Int? = estimatedCompatibility(profile, cachedMyInterests)

    @Serializable
    private data class NewCompatRequest(
        @SerialName("requester_id") val requesterId: String,
        @SerialName("target_id") val targetId: String
    )

    /** Solicitar ver la compatibilidad real de alguien que la tiene privada
     * -- mismo patrón exacto que MatchViewModel.requestCompatibility(),
     * hasta ahora solo construido en Match. Comparado con SOCIAL_APP.html:
     * "Recomendados" (y ahora la cabecera de cada post) mostraba "?%" sin
     * ninguna forma real de pedir verlo, a diferencia de Match. */
    fun requestCompatibility(profileId: String) {
        _recommended.update { list ->
            list.map { if (it.profile.id == profileId) it.copy(requestSent = true) else it }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("compat_requests").insert(
                    NewCompatRequest(requesterId = userId, targetId = profileId)
                )
                com.social.app.backend.AnalyticsManager.track("compat_request_sent")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la solicitud de compatibilidad."
            }
        }
    }

    @Serializable
    private data class NewLike(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class LikedPostRow(@SerialName("post_id") val postId: String)

    @Serializable
    private data class RepostRow(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class NewRepost(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    /** Repostear/quitar repost real de una publicación, comparado con
     * Twitter/X/Facebook -- mismo patrón exacto que toggleLike()/
     * toggleSave() de abajo, restricción unique(post_id, user_id) real
     * (0127_post_reposts.sql). */
    fun toggleRepost(post: Post) {
        val currentlyReposted = _repostedPostIds.value.contains(post.id)
        _repostedPostIds.update { if (currentlyReposted) it - post.id else it + post.id }
        _repostCounts.update { it + (post.id to ((it[post.id] ?: 0) + if (currentlyReposted) -1 else 1).coerceAtLeast(0)) }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyReposted) {
                    SupabaseManager.client.from("post_reposts").delete {
                        filter { eq("post_id", post.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("post_reposts").insert(NewRepost(post.id, userId))
                    com.social.app.backend.AnalyticsManager.track("post_reposted")
                }
            } catch (e: Exception) {
                // Restricción unique(post_id, user_id): el estado deseado
                // ya se cumple, mismo criterio que toggleLike()/toggleSave().
            }
        }
    }

    private val _storyShareMessage = MutableStateFlow<String?>(null)
    val storyShareMessage: StateFlow<String?> = _storyShareMessage.asStateFlow()

    @Serializable
    private data class NewSharedStory(
        @SerialName("author_id") val authorId: String,
        @SerialName("media_url") val mediaUrl: String,
        @SerialName("shared_post_id") val sharedPostId: String,
        @SerialName("shared_post_author_id") val sharedPostAuthorId: String
    )

    /** Compartir una publicación a tu Historia con atribución real al autor
     * original, comparado con Instagram/Facebook ("Add post to your
     * story") -- ver 0129_story_shared_post.sql. Alcance deliberado:
     * reutiliza `post.mediaUrl` tal cual, sin pipeline de composición
     * nuevo -- solo posible en un post con foto/vídeo real (mismo límite
     * que `stories.media_url not null` siempre exigió). */
    fun shareToStory(post: Post) {
        val mediaUrl = post.mediaUrl ?: return
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("stories").insert(
                    NewSharedStory(userId, mediaUrl, post.id, post.authorId)
                )
                com.social.app.backend.AnalyticsManager.track("post_shared_to_story")
                _storyShareMessage.value = "Compartido a tu historia"
            } catch (e: Exception) {
                _storyShareMessage.value = "No se pudo compartir a tu historia."
            }
        }
    }

    fun clearStoryShareMessage() {
        _storyShareMessage.value = null
    }

    /** Toggle real de like/unlike — antes era solo `like()`, un botón de un
     * solo sentido que incrementaba el contador local para siempre sin
     * saber si ya estaba likeado (ver hallazgo arriba). `posts.like_count`
     * lo mantiene sincronizado un trigger (0007_likes.sql), no este código
     * — aquí solo se registra/borra el like del usuario. Mismo patrón ya
     * correcto de toggleSave(). */
    fun toggleLike(post: Post) {
        val currentlyLiked = _likedPostIds.value.contains(post.id)
        _likedPostIds.update { if (currentlyLiked) it - post.id else it + post.id }
        _feed.update { list ->
            list.map {
                if (it.id == post.id) it.copy(likeCount = (it.likeCount + if (currentlyLiked) -1 else 1).coerceAtLeast(0))
                else it
            }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyLiked) {
                    SupabaseManager.client.from("likes").delete {
                        filter { eq("post_id", post.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("likes").insert(NewLike(post.id, userId))
                    // Hallazgo real, misma auditoría de AnalyticsManager
                    // de las últimas pasadas: dar like es la señal de
                    // participación más frecuente de cualquier feed y no
                    // se registraba en absoluto. Solo en la dirección de
                    // "dar like" (no "quitar"), mismo criterio que
                    // report_submitted (solo el envío, no cada re-lectura).
                    com.social.app.backend.AnalyticsManager.track("post_liked")
                }
            } catch (e: Exception) {
                // Restricción unique(post_id, user_id): si ya existía el like,
                // Postgrest devuelve un 409 — no es un error real de usuario,
                // el estado deseado ya se cumple (mismo criterio que
                // toggleSave()).
            }
        }
    }

    /** Refleja en el feed el comentario ya persistido por CommentsViewModel
     * (ver 0008_comments.sql) sin tener que recargar el feed entero — mismo
     * criterio de actualización local que like(). */
    fun commentAdded(postId: String) {
        _feed.update { list ->
            list.map { if (it.id == postId) it.copy(commentCount = it.commentCount + 1) else it }
        }
    }

    /** Contraparte de commentAdded() para el borrado de comentarios recién
     * añadido (ver CommentsViewModel.deleteComment). */
    fun commentRemoved(postId: String) {
        _feed.update { list ->
            list.map { if (it.id == postId) it.copy(commentCount = (it.commentCount - 1).coerceAtLeast(0)) else it }
        }
    }

    @Serializable
    private data class SavedPostRow(@SerialName("post_id") val postId: String)

    @Serializable
    private data class NewSavedPost(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    /** Icono "guardar" antes puramente decorativo (`Image`/sin onClick en
     * ambas plataformas) — igual que el "like" falso encontrado antes de
     * esta sesión, pero aquí ni siquiera había un intento de wiring. Toggle
     * real con persistencia en `saved_posts` (ver 0009_saved_posts.sql,
     * tabla privada del usuario, sin contador público). */
    fun toggleSave(post: Post) {
        val currentlySaved = _savedPostIds.value.contains(post.id)
        _savedPostIds.update { if (currentlySaved) it - post.id else it + post.id }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlySaved) {
                    SupabaseManager.client.from("saved_posts").delete {
                        filter { eq("post_id", post.id); eq("user_id", userId) }
                    }
                } else {
                    SupabaseManager.client.from("saved_posts").insert(NewSavedPost(post.id, userId))
                    // Hallazgo real, misma auditoría de AnalyticsManager
                    // de las últimas pasadas: guardar tampoco se
                    // registraba. Solo en la dirección de "guardar", mismo
                    // criterio que post_liked/user_followed.
                    com.social.app.backend.AnalyticsManager.track("post_saved")
                }
            } catch (e: Exception) {
                // Restricción unique(post_id, user_id) en el caso de guardar
                // dos veces seguidas: el estado deseado ya se cumple, no es
                // un error real de usuario (mismo criterio que like()).
            }
        }
    }

    /** Votar/cambiar de opción en la encuesta de una publicación,
     * comparado con Twitter/X/Facebook -- mismo patrón exacto que
     * StoriesViewModel.voteOnPoll() (0100), `upsert` real con
     * `onConflict` cubre insertar el primer voto y cambiar de opción con
     * una sola llamada, cada una ya cubierta por su propia política RLS
     * real (0113_post_polls.sql). */
    fun voteOnPostPoll(pollId: String, optionIndex: Int) {
        _myPostPollVotes.update { it + (pollId to optionIndex) }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("post_poll_votes")
                    .upsert(NewPostPollVote(pollId, userId, optionIndex), onConflict = "poll_id,voter_id")
                val updated = SupabaseManager.client.from("post_polls")
                    .select(columns = Columns.raw("id,post_id,question,options,vote_counts")) { filter { eq("id", pollId) } }
                    .decodeSingleOrNull<PostPollRow>()
                if (updated != null) {
                    _postPolls.update { it + (updated.postId to updated) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo registrar el voto."
            }
        }
    }
}
