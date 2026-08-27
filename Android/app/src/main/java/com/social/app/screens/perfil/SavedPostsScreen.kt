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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.flow.update
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
// Colecciones reales para publicaciones guardadas, comparado con
// Instagram -- ver 0125_saved_post_collections.sql. `savedId` (id de la
// propia fila saved_posts, no del post) hace falta para poder cambiar de
// colección/quitar de guardados sin depender de post_id+user_id como
// clave compuesta en cada llamada.
data class SavedItem(val savedId: String, val post: Post, val collectionName: String?)

class SavedPostsViewModel : ViewModel() {
    private val _posts = MutableStateFlow<List<SavedItem>>(emptyList())
    val posts: StateFlow<List<SavedItem>> = _posts.asStateFlow()

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
    private data class SavedPostRow(
        val id: String,
        val posts: Post?,
        @SerialName("collection_name") val collectionName: String? = null
    )

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
                    .select(columns = Columns.raw("id,created_at,collection_name,posts(*)")) {
                        filter { eq("user_id", userId) }
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<SavedPostRow>()
                    .mapNotNull { row -> row.posts?.let { SavedItem(row.id, it, row.collectionName) } }
                    .filter { it.post.authorId !in blockedIds }
                _posts.value = loaded

                val authorIds = loaded.map { it.post.authorId }.distinct()
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
    fun unsave(item: SavedItem) {
        _posts.value = _posts.value.filter { it.savedId != item.savedId }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("saved_posts").delete {
                    filter { eq("id", item.savedId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar de guardados."
            }
        }
    }

    /** Mover un guardado real a otra colección (o quitarlo de todas con
     * `null`), comparado con Instagram -- ver
     * 0125_saved_post_collections.sql (`saved_posts_update_own`, primera
     * política UPDATE real sobre esta tabla). */
    fun setCollection(item: SavedItem, collectionName: String?) {
        val trimmed = collectionName?.trim()?.ifEmpty { null }?.take(50)
        _posts.update { list -> list.map { if (it.savedId == item.savedId) it.copy(collectionName = trimmed) else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("saved_posts")
                    .update({ set("collection_name", trimmed) }) { filter { eq("id", item.savedId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar la colección."
                load()
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
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    var fullScreenUrl by remember { mutableStateOf<String?>(null) }
    // Colecciones reales para publicaciones guardadas, comparado con
    // Instagram -- ver SavedPostsViewModel.setCollection(),
    // 0125_saved_post_collections.sql.
    var selectedCollection by remember { mutableStateOf<String?>(null) }
    var movingItem by remember { mutableStateOf<SavedItem?>(null) }
    var moveDraft by remember { mutableStateOf("") }

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
        // Colecciones reales para publicaciones guardadas, comparado con
        // Instagram -- fila de chips para filtrar, "Todo" siempre
        // primero (bandeja general, incluye lo sin colección también).
        val collections = posts.mapNotNull { it.collectionName }.distinct().sorted()
        if (collections.isNotEmpty()) {
            androidx.compose.foundation.lazy.LazyRow(
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
            ) {
                item {
                    androidx.compose.material3.FilterChip(
                        selected = selectedCollection == null,
                        onClick = { selectedCollection = null },
                        label = { Text("Todo") }
                    )
                }
                items(collections) { name ->
                    androidx.compose.material3.FilterChip(
                        selected = selectedCollection == name,
                        onClick = { selectedCollection = name },
                        label = { Text(name) }
                    )
                }
            }
        }
        val visiblePosts = selectedCollection?.let { c -> posts.filter { it.collectionName == c } } ?: posts
        androidx.compose.foundation.layout.Box(modifier = Modifier.fillMaxWidth()) {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(visiblePosts, key = { it.savedId }) { item ->
                    val post = item.post
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
                                    .clickable { fullScreenUrl = url }
                            )
                        }
                        post.caption?.let { Text(it) }
                        // Colecciones reales, comparado con Instagram --
                        // etiqueta real cuando corresponde, mismo criterio
                        // ya usado para "Reenviado"/"Editado" en el chat.
                        item.collectionName?.let {
                            Text(
                                "🗂 $it",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.padding(top = 2.dp)
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.SpaceBetween
                        ) {
                            Text(
                                "❤ ${post.likeCount} · 💬 ${post.commentCount}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row {
                                OutlinedButton(onClick = {
                                    movingItem = item
                                    moveDraft = item.collectionName ?: ""
                                }) { Text("Mover") }
                                OutlinedButton(onClick = { viewModel.unsave(item) }, modifier = Modifier.padding(start = 8.dp)) { Text("Quitar") }
                            }
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
    fullScreenUrl?.let { url ->
        com.social.app.util.FullScreenImageViewer(url = url, onDismiss = { fullScreenUrl = null })
    }
    // Colecciones reales para publicaciones guardadas, comparado con
    // Instagram -- ver SavedPostsViewModel.setCollection(),
    // 0125_saved_post_collections.sql.
    movingItem?.let { item ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { movingItem = null },
            title = { Text("Mover a colección") },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = moveDraft,
                    onValueChange = { moveDraft = it },
                    placeholder = { Text("Nombre (p. ej. \"Viajes\")") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.setCollection(item, moveDraft)
                    movingItem = null
                }) { Text("Guardar") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.setCollection(item, null)
                    movingItem = null
                }) { Text("Quitar colección") }
            }
        )
    }
}
