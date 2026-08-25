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

/** Equivalente Kotlin de HomeViewModel.swift: feed y recomendados (sin
 * Historias — no implementadas en ninguna plataforma, ver corrección de
 * honestidad en HomeView.swift/HomeScreen.kt). */
class HomeViewModel : ViewModel() {

    data class Recommended(val profile: Profile, val compatibility: Int?)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    private val _feed = MutableStateFlow<List<Post>>(emptyList())
    val feed: StateFlow<List<Post>> = _feed.asStateFlow()

    private val _recommended = MutableStateFlow<List<Recommended>>(emptyList())
    val recommended: StateFlow<List<Recommended>> = _recommended.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _savedPostIds = MutableStateFlow<Set<String>>(emptySet())
    val savedPostIds: StateFlow<Set<String>> = _savedPostIds.asStateFlow()

    // Hallazgo real: no había forma de quitar un like, comparado con
    // cualquier app grande — `like()` solo incrementaba el contador local
    // para siempre, mientras `likes` (constraint unique) se quedaba en una
    // sola fila real. El corazón nunca reflejaba si YA le habías dado
    // like. Ver toggleLike() más abajo.
    private val _likedPostIds = MutableStateFlow<Set<String>>(emptySet())
    val likedPostIds: StateFlow<Set<String>> = _likedPostIds.asStateFlow()

    // Hallazgo real, comparado con cualquier app grande: la tarjeta del
    // feed nunca mostraba QUIÉN publicó cada post -- ni nombre, ni avatar,
    // ni forma de tocar para ver su perfil. A diferencia de Search/Match/
    // Avisos (los tres sí llevan onOpenProfile), Home era la única
    // pantalla con listado sin esa navegación. `posts` no lleva el perfil
    // embebido, así que se resuelve aparte con un solo select por los
    // author_id distintos del feed cargado (no N+1).
    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
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
                // Optimización: la tarjeta del feed solo usa estas 7 columnas
                // de "posts", no filas completas (mismo patrón que
                // MatchViewModel/DuelEntryPoint/AvisosViewModel).
                _feed.value = SupabaseManager.client.from("posts")
                    .select(columns = Columns.raw("id,author_id,media_url,caption,is_social_only,like_count,comment_count,created_at")) {
                        order("created_at", Order.DESCENDING)
                        limit(30)
                    }
                    .decodeList<Post>()
                    .filter { it.authorId !in blockedIds }

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

    @Serializable
    private data class NewLike(
        @SerialName("post_id") val postId: String,
        @SerialName("user_id") val userId: String
    )

    @Serializable
    private data class LikedPostRow(@SerialName("post_id") val postId: String)

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
}
