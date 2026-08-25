package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
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
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * "Guardados" — hallazgo real: `HomeViewModel.toggleSave()` (y el icono
 * de marcador en `PostCard`) llevan desde hace varias pasadas guardando
 * de verdad en `saved_posts`, pero no existía NINGUNA pantalla en ninguna
 * plataforma para ver lo guardado — comparado con Instagram (colección
 * "Guardado" real), guardar un post en SOCIAL no llevaba a ningún sitio.
 * Equivalente de MyPostsScreen.kt: mismo patrón, distinta fuente
 * (`saved_posts` embebiendo `posts(*)` vía PostgREST, mismo criterio ya
 * compiler-verificado en `EventModeViewModel.kt` con
 * `profiles(display_name)`).
 */
class SavedPostsViewModel : ViewModel() {
    private val _posts = MutableStateFlow<List<Post>>(emptyList())
    val posts: StateFlow<List<Post>> = _posts.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Hallazgo real, mismo hueco raíz ya cerrado en el feed y en
    // comentarios (HomeViewModel/CommentsViewModel.authorProfiles): esta
    // lista tampoco mostraba QUIÉN escribió cada post guardado -- ni
    // siquiera la imagen, comparado con la colección "Guardado" real de
    // Instagram.
    private val _authorProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val authorProfiles: StateFlow<Map<String, Profile>> = _authorProfiles.asStateFlow()

    @Serializable
    private data class SavedPostRow(val posts: Post?)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                // Mismo refuerzo de privacidad ya aplicado en Home/Match/
                // Find/Search/ChatList: no mostrar contenido de gente
                // bloqueada, aquí aplicado a la lista de guardados —
                // guardaste el post antes de bloquear a su autor, no hay
                // razón para que sus publicaciones sigan apareciéndote.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                val loaded = SupabaseManager.client.from("saved_posts")
                    .select(columns = Columns.raw("created_at,posts(*)")) {
                        filter { eq("user_id", userId) }
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<SavedPostRow>()
                    .mapNotNull { it.posts }
                    .filter { it.authorId !in blockedIds }
                _posts.value = loaded

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
                        // No bloquea el resto de la lista si falla.
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus guardados."
            }
        }
    }

    /** Quitar de guardados desde esta misma lista — sin esto, la única
     * forma de "deshacer" sería volver a encontrar el post en el feed. */
    fun unsave(post: Post) {
        _posts.value = _posts.value.filter { it.id != post.id }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("saved_posts").delete {
                    filter {
                        eq("user_id", userId)
                        eq("post_id", post.id)
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar de guardados."
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SavedPostsScreen(viewModel: SavedPostsViewModel = viewModel(), onOpenProfile: (String) -> Unit = {}) {
    val posts by viewModel.posts.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    // Hallazgo real, mismo criterio ya aplicado en Home/Match/ChatList:
    // comparado con Instagram/Twitter/Facebook, esta pantalla (como el
    // resto de listas simples de Perfil) no tenía pull-to-refresh.
    val pullState = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            viewModel.load()
            pullState.endRefresh()
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(16.dp)
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        Text("Guardados", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (posts.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no has guardado ninguna publicación.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        androidx.compose.foundation.layout.Box(modifier = Modifier.fillMaxWidth()) {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(posts, key = { it.id }) { post ->
                    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        // Hallazgo real, mismo hueco raíz ya cerrado en el
                        // feed y en comentarios: esta lista tampoco
                        // mostraba QUIÉN escribió cada post guardado, ni
                        // su imagen -- comparado con la colección
                        // "Guardado" real de Instagram.
                        val author = authorProfiles[post.authorId]
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { onOpenProfile(post.authorId) }.padding(bottom = 6.dp)
                        ) {
                            com.social.app.avatar.AvatarView(config = author?.avatarConfig ?: emptyMap(), size = 24.dp)
                            Text(
                                author?.displayName ?: "…",
                                style = MaterialTheme.typography.labelMedium,
                                modifier = Modifier.padding(start = 6.dp)
                            )
                        }
                        post.mediaUrl?.let { url ->
                            androidx.compose.foundation.Image(
                                painter = coil.compose.rememberAsyncImagePainter(url),
                                contentDescription = null,
                                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                modifier = Modifier.fillMaxWidth().height(180.dp)
                                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                    .padding(bottom = 6.dp)
                            )
                        }
                        post.caption?.let { Text(it) }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.SpaceBetween
                        ) {
                            Text(
                                "❤ ${post.likeCount} · 💬 ${post.commentCount}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            OutlinedButton(onClick = { viewModel.unsave(post) }) { Text("Quitar") }
                        }
                    }
                    HorizontalDivider()
                }
            }
            androidx.compose.material3.pulltorefresh.PullToRefreshContainer(
                state = pullState,
                modifier = Modifier.align(Alignment.TopCenter)
            )
        }
    }
}
