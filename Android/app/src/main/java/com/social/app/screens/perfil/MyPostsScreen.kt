package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * "Tus publicaciones" — Android nunca tuvo la rejilla de 6 subsecciones de
 * iOS en absoluto. Con el compositor de publicaciones ya real (ver
 * NewPostViewModel.kt), este visor deja de depender de Storage — muestra
 * las propias con opción de borrar (`posts_write_own`, 0002_rls.sql, ya es
 * `for all`, así que borrar la propia publicación ya estaba permitido a
 * nivel de RLS, solo faltaba el botón). Equivalente de MyPostsView.swift.
 */
class MyPostsViewModel : ViewModel() {
    private val _posts = MutableStateFlow<List<Post>>(emptyList())
    val posts: StateFlow<List<Post>> = _posts.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                _posts.value = SupabaseManager.client.from("posts")
                    .select {
                        filter { eq("author_id", userId) }
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus publicaciones."
            }
        }
    }

    fun delete(post: Post) {
        _posts.value = _posts.value.filter { it.id != post.id }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("posts").delete { filter { eq("id", post.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar la publicación."
            }
        }
    }

    /** Hallazgo real, comparado con Instagram: no había forma de editar el
     * caption de una publicación ya hecha, solo borrarla entera --
     * `posts_write_own` (0002_rls.sql) ya es `for all`, así que editar la
     * propia publicación ya estaba permitido a nivel de RLS, solo faltaba
     * el botón. Mismo límite real que `posts_caption_length`
     * (0023_text_length_limits.sql, 2200 caracteres). */
    fun editCaption(post: Post, newCaption: String) {
        if (newCaption.length > 2200) {
            _errorMessage.value = "El texto no puede tener más de 2200 caracteres."
            return
        }
        val trimmed = newCaption.ifBlank { null }
        _posts.value = _posts.value.map { if (it.id == post.id) it.copy(caption = trimmed) else it }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("posts")
                    .update({ set("caption", trimmed) }) { filter { eq("id", post.id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo editar la publicación."
                load()
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun MyPostsScreen(viewModel: MyPostsViewModel = viewModel()) {
    val posts by viewModel.posts.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // Hallazgo real, comparado con SOCIAL_APP.html ("Pubs de socials",
    // etiqueta "con Marta"): no había forma de ver solo las publicaciones
    // hechas CON un social -- 0051_post_social_tags.sql. Reutiliza la
    // misma lista de socials aceptados que NewPostSheet.kt ya usa para
    // etiquetar, para resolver el nombre real de la persona etiquetada.
    var showOnlyTagged by remember { mutableStateOf(false) }
    val socialsViewModel: SocialsListViewModel = viewModel()
    val socials by socialsViewModel.socials.collectAsState()
    LaunchedEffect(Unit) { socialsViewModel.load() }
    val socialNameById = remember(socials) { socials.associate { it.profileId to it.displayName } }
    val visiblePosts = if (showOnlyTagged) posts.filter { it.taggedProfileId != null } else posts
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    var fullScreenUrl by remember { mutableStateOf<String?>(null) }
    // Hallazgo real, comparado con Instagram: no había forma de editar el
    // caption de una publicación ya hecha, solo borrarla entera.
    var editingPost by remember { mutableStateOf<Post?>(null) }
    var editedCaption by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { viewModel.load() }

    // Hallazgo real, mismo criterio ya aplicado en Home/Match/ChatList/
    // Guardados: comparado con Instagram/Twitter/Facebook, esta pantalla
    // no tenía pull-to-refresh.
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
        Text("Tus publicaciones", style = MaterialTheme.typography.headlineSmall)
        androidx.compose.material3.TabRow(
            selectedTabIndex = if (showOnlyTagged) 1 else 0,
            modifier = Modifier.padding(top = 12.dp)
        ) {
            androidx.compose.material3.Tab(
                selected = !showOnlyTagged,
                onClick = { showOnlyTagged = false },
                text = { Text("Todas") }
            )
            androidx.compose.material3.Tab(
                selected = showOnlyTagged,
                onClick = { showOnlyTagged = true },
                text = { Text("Con tus socials") }
            )
        }
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (visiblePosts.isEmpty() && errorMessage == null) {
            Text(
                if (showOnlyTagged) "Ninguna publicación etiquetada con un social todavía." else "Todavía no has publicado nada.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        androidx.compose.foundation.layout.Box(modifier = Modifier.fillMaxWidth()) {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(visiblePosts, key = { it.id }) { post ->
                    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        // Hallazgo real, mismo hueco ya cerrado en
                        // Guardados: esta lista tampoco mostraba la
                        // imagen de la publicación, solo texto.
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
                        post.taggedProfileId?.let { taggedId ->
                            Text(
                                "con ${socialNameById[taggedId] ?: "alguien"}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.padding(top = 2.dp)
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(
                                "❤ ${post.likeCount} · 💬 ${post.commentCount}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row {
                                OutlinedButton(
                                    onClick = {
                                        editingPost = post
                                        editedCaption = post.caption ?: ""
                                    },
                                    modifier = Modifier.padding(end = 8.dp)
                                ) { Text("Editar") }
                                OutlinedButton(onClick = { viewModel.delete(post) }) { Text("Borrar") }
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
    editingPost?.let { post ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { editingPost = null },
            title = { Text("Editar publicación") },
            text = {
                Column {
                    androidx.compose.material3.OutlinedTextField(
                        value = editedCaption,
                        onValueChange = { editedCaption = it },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text(
                        "${editedCaption.length}/2200",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (editedCaption.length > 2200) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.editCaption(post, editedCaption)
                    editingPost = null
                }) { Text("Guardar") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { editingPost = null }) { Text("Cancelar") }
            }
        )
    }
}
