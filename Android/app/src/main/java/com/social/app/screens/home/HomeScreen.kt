package com.social.app.screens.home

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.util.relativeTime
import io.github.jan.supabase.gotrue.auth
import com.social.app.backend.model.Post

/**
 * Feed de publicaciones (like y comentarios reales, ver 0007_likes.sql /
 * 0008_comments.sql) y recomendados con % de compatibilidad. Sin scroll
 * infinito ni algoritmo de adicción — lista finita, igual que HomeView.swift.
 *
 * Corrección de honestidad (2026-08-24): el docstring anterior afirmaba
 * que Historias seguía sin implementar — falso, `StoriesBar()` (más abajo)
 * y `StoriesViewModel.kt` ya están construidos y montados. Like, comentar,
 * enviar (compartir con el share sheet nativo), guardar e Historias son
 * todos reales.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    viewModel: HomeViewModel = viewModel(),
    onOpenSearch: () -> Unit = {},
    onOpenFind: () -> Unit = {},
    onOpenHashtag: (String) -> Unit = {}
) {
    val feed by viewModel.feed.collectAsState()
    val recommended by viewModel.recommended.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val savedPostIds by viewModel.savedPostIds.collectAsState()
    val likedPostIds by viewModel.likedPostIds.collectAsState()
    var commentsPostId by remember { mutableStateOf<String?>(null) }
    // Hallazgo real: no había ninguna forma de crear una publicación en
    // toda la app (ver NewPostViewModel.kt para el detalle completo).
    var showNewPost by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = { showNewPost = true }) {
                // Sin "Add" en el set base de iconos usado por este proyecto
                // (mismo límite ya resuelto con texto en el icono de la
                // pestaña Social en RootTabView.kt) — texto en vez de icono.
                Text("+", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
            }
        }
    ) { padding ->
        // Hallazgo real: comparado con Instagram/Twitter/Facebook, ninguna
        // pantalla de la app tenía pull-to-refresh, un gesto básico
        // esperado en cualquier app social.
        val pullState = rememberPullToRefreshState()
        if (pullState.isRefreshing) {
            LaunchedEffect(Unit) {
                viewModel.load()
                pullState.endRefresh()
            }
        }
        Box(modifier = Modifier.fillMaxWidth().padding(padding).nestedScroll(pullState.nestedScrollConnection)) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                // Cabecera de marca real (antes: título de texto plano
                // "Home" + dos TextButton) — puesta en línea con el resto
                // del rediseño visual de esta pasada (logo real, degradado
                // de marca) en vez de dejar Home como la única pantalla sin
                // tocar. "Find" y "Buscar" (ambos con función real detrás,
                // ver FindLocationsViewModel.kt/SearchViewModel.kt) se
                // mantienen, solo cambia su presentación a iconos para que
                // quepan en la cabecera de marca sin perder la
                // funcionalidad ya construida.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .clip(RoundedCornerShape(9.dp))
                            .background(Brush.linearGradient(listOf(Color(0xFF4DABF7), Color(0xFFA55EEA))))
                            .clickable(onClick = onOpenFind),
                        contentAlignment = androidx.compose.ui.Alignment.Center
                    ) {
                        Text("F", color = Color.White, style = MaterialTheme.typography.titleMedium)
                    }
                    Image(
                        painter = painterResource(com.social.app.R.drawable.social_logo),
                        contentDescription = "SOCIAL",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.height(28.dp)
                    )
                    IconButton(onClick = onOpenSearch) {
                        Text("🔍")
                    }
                }
            }
            // Hallazgo real: no había ningún cliente para Historias en
            // ninguna plataforma pese a que el esquema/RLS ya estaban
            // completos desde el principio (ver StoriesViewModel.kt).
            item { StoriesBar() }
            if (isLoading) {
                item { CircularProgressIndicator() }
            }
            errorMessage?.let { message ->
                item { Text(message, color = androidx.compose.material3.MaterialTheme.colorScheme.error) }
            }
            if (recommended.isNotEmpty()) {
                item { Text("Recomendados", style = androidx.compose.material3.MaterialTheme.typography.titleMedium) }
                item {
                    androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(recommended) { entry -> RecommendedCard(entry) }
                    }
                }
            }
            items(feed) { post ->
                PostCard(
                    post = post,
                    isSaved = savedPostIds.contains(post.id),
                    isLiked = likedPostIds.contains(post.id),
                    onLike = { viewModel.toggleLike(post) },
                    onOpenComments = { commentsPostId = post.id },
                    onToggleSave = { viewModel.toggleSave(post) },
                    onOpenHashtag = onOpenHashtag
                )
            }
        }
        PullToRefreshContainer(
            state = pullState,
            modifier = Modifier.align(androidx.compose.ui.Alignment.TopCenter)
        )
        }
    }

    commentsPostId?.let { postId ->
        CommentsSheet(
            postId = postId,
            onDismiss = { commentsPostId = null },
            onCommentAdded = { viewModel.commentAdded(postId) },
            onCommentRemoved = { viewModel.commentRemoved(postId) }
        )
    }

    if (showNewPost) {
        NewPostSheet(
            onDismiss = { showNewPost = false },
            onPosted = { viewModel.load() }
        )
    }
}

/**
 * Etiquetas tocables dentro del texto de un caption — hasta esta pasada
 * el buscador ya sabía buscar posts por "#etiqueta" (ver
 * SearchViewModel.kt) pero no había ninguna forma de llegar ahí desde una
 * publicación real del feed: había que teclear la etiqueta de memoria.
 * Mismo criterio que Instagram/TikTok (tocar una etiqueta abre su
 * búsqueda).
 */
@Composable
private fun CaptionText(caption: String, onOpenHashtag: (String) -> Unit) {
    val linkColor = MaterialTheme.colorScheme.primary
    val baseColor = LocalContentColor.current
    val annotated = remember(caption) {
        buildAnnotatedStringWithHashtags(caption, linkColor, baseColor)
    }
    ClickableText(text = annotated) { offset ->
        annotated.getStringAnnotations(tag = "hashtag", start = offset, end = offset)
            .firstOrNull()
            ?.let { onOpenHashtag(it.item) }
    }
}

private fun buildAnnotatedStringWithHashtags(caption: String, linkColor: androidx.compose.ui.graphics.Color, baseColor: androidx.compose.ui.graphics.Color): AnnotatedString {
    return androidx.compose.ui.text.buildAnnotatedString {
        val words = caption.split(" ")
        words.forEachIndexed { index, word ->
            if (word.startsWith("#") && word.length > 1) {
                val tag = word.drop(1).trimEnd { !it.isLetterOrDigit() }
                pushStringAnnotation(tag = "hashtag", annotation = tag)
                withStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)) {
                    append(word)
                }
                pop()
            } else {
                withStyle(SpanStyle(color = baseColor)) { append(word) }
            }
            if (index != words.lastIndex) append(" ")
        }
    }
}

@Composable
private fun RecommendedCard(entry: HomeViewModel.Recommended) {
    Card(modifier = Modifier.padding(4.dp)) {
        Column(modifier = Modifier.padding(10.dp), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
            com.social.app.avatar.AvatarView(config = entry.profile.avatarConfig ?: emptyMap(), size = 56.dp)
            Text(entry.profile.displayName, style = androidx.compose.material3.MaterialTheme.typography.labelMedium)
            Text(entry.compatibility?.let { "$it%" } ?: "?%", style = androidx.compose.material3.MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun PostCard(
    post: Post,
    isSaved: Boolean,
    isLiked: Boolean,
    onLike: () -> Unit,
    onOpenComments: () -> Unit,
    onToggleSave: () -> Unit,
    onOpenHashtag: (String) -> Unit = {}
) {
    val context = LocalContext.current
    // Hallazgo real: comparado con cualquier app grande, no había forma de
    // denunciar una publicación directamente — solo existía la denuncia
    // global de usuario (SafetyToolbar). `reports.reported_id` no tiene
    // columna de post_id, así que se denuncia al autor con el id del post
    // en los detalles, para que moderación sepa cuál — no se inventa una
    // columna nueva para esto.
    var showReport by remember { mutableStateOf(false) }
    val myId = com.social.app.backend.SupabaseManager.client.auth.currentUserOrNull()?.id
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp)) {
            post.mediaUrl?.let { url ->
                androidx.compose.foundation.Image(
                    painter = coil.compose.rememberAsyncImagePainter(url),
                    contentDescription = null,
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth().height(220.dp)
                        .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                        .padding(bottom = 8.dp)
                )
            }
            post.caption?.let { CaptionText(it, onOpenHashtag) }
            if (post.createdAt.isNotBlank()) {
                Text(
                    relativeTime(post.createdAt),
                    style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(top = 8.dp)) {
                Text(
                    "${if (isLiked) "❤" else "🤍"} ${post.likeCount}",
                    modifier = Modifier.clickable(onClick = onLike).padding(end = 4.dp)
                )
                Text("💬 ${post.commentCount}", modifier = Modifier.clickable(onClick = onOpenComments))
                Text(
                    "➤",
                    modifier = Modifier.clickable {
                        // Icono antes puramente decorativo — mismo patrón que
                        // "guardar" antes de esta pasada. Usa el share sheet
                        // nativo de Android en vez de infraestructura propia
                        // (no hace falta tabla ni backend para "compartir").
                        val text = post.caption?.let { "Mira esto en SOCIAL: $it" } ?: "Mira esto en SOCIAL"
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                        }
                        context.startActivity(Intent.createChooser(intent, "Compartir publicación"))
                    }
                )
                Text(if (isSaved) "🔖" else "📑", modifier = Modifier.clickable(onClick = onToggleSave))
                Text("⋯", modifier = Modifier.clickable { showReport = true })
            }
        }
    }

    if (showReport && myId != null) {
        com.social.app.safety.ReportSheet(
            reporterId = myId,
            reportedId = post.authorId,
            initialDetails = "Publicación ${post.id}",
            onDismiss = { showReport = false }
        )
    }
}
