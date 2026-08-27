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
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.ui.theme.SocialColors
import com.social.app.util.MentionHashtagText
import com.social.app.util.MentionResolver
import com.social.app.util.relativeTime
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch
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
    onOpenHashtag: (String) -> Unit = {},
    onOpenProfile: (String) -> Unit = {}
) {
    val feed by viewModel.feed.collectAsState()
    val recommended by viewModel.recommended.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val savedPostIds by viewModel.savedPostIds.collectAsState()
    val likedPostIds by viewModel.likedPostIds.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()
    val extraMediaByPost by viewModel.extraMediaByPost.collectAsState()
    val postPolls by viewModel.postPolls.collectAsState()
    val myPostPollVotes by viewModel.myPostPollVotes.collectAsState()
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
                        items(recommended) { entry ->
                            RecommendedCard(
                                entry,
                                onClick = { onOpenProfile(entry.profile.id) },
                                onRequest = { viewModel.requestCompatibility(entry.profile.id) }
                            )
                        }
                    }
                }
            }
            items(feed) { post ->
                val author = authorProfiles[post.authorId]
                val poll = postPolls[post.id]
                PostCard(
                    post = post,
                    author = author,
                    extraMedia = extraMediaByPost[post.id] ?: emptyList(),
                    compatibility = author?.let { viewModel.compatibilityFor(it) },
                    isSaved = savedPostIds.contains(post.id),
                    isLiked = likedPostIds.contains(post.id),
                    onLike = { viewModel.toggleLike(post) },
                    onOpenComments = { commentsPostId = post.id },
                    onToggleSave = { viewModel.toggleSave(post) },
                    onOpenHashtag = onOpenHashtag,
                    onOpenProfile = { onOpenProfile(post.authorId) },
                    onOpenMentionProfile = onOpenProfile,
                    onRequestCompat = { viewModel.requestCompatibility(post.authorId) },
                    poll = poll,
                    myPollVote = poll?.let { myPostPollVotes[it.id] },
                    onVotePoll = { optionIndex -> poll?.let { viewModel.voteOnPostPoll(it.id, optionIndex) } }
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
            onCommentRemoved = { viewModel.commentRemoved(postId) },
            onOpenProfile = { authorId -> commentsPostId = null; onOpenProfile(authorId) }
        )
    }

    if (showNewPost) {
        NewPostSheet(
            onDismiss = { showNewPost = false },
            onPosted = { viewModel.load() }
        )
    }
}

@Composable
private fun RecommendedCard(entry: HomeViewModel.Recommended, onClick: () -> Unit, onRequest: () -> Unit) {
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed principal
    // (PostCard sin onOpenProfile): "Recomendados" tampoco llevaba a
    // ningún perfil al tocarlo, comparado con "Sugeridos para ti" de
    // Instagram (siempre tocable).
    Card(modifier = Modifier.padding(4.dp).clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(10.dp), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
            com.social.app.avatar.AvatarView(config = entry.profile.avatarConfig ?: emptyMap(), size = 56.dp)
            Text(entry.profile.displayName, style = androidx.compose.material3.MaterialTheme.typography.labelMedium)
            CompatBadge(compatibility = entry.compatibility, requestSent = entry.requestSent, onRequest = onRequest)
        }
    }
}

/**
 * Hallazgo real, comparado con SOCIAL_APP.html (`reqCompat()`): "?%" era
 * texto fijo, sin ninguna forma de pedir ver la compatibilidad real cuando
 * es privada -- a diferencia de Match, que ya tenía este mismo flujo
 * (`MatchViewModel.requestCompatibility`/`MatchScreen.MatchCard`) desde
 * antes. Mismos 3 estados reales (público/pendiente/pedir), reutilizados
 * aquí en Recomendados y en la cabecera de cada post del feed.
 */
@Composable
private fun CompatBadge(compatibility: Int?, requestSent: Boolean, onRequest: () -> Unit) {
    val (text, clickable) = when {
        compatibility != null -> "$compatibility% compat." to false
        requestSent -> "Pendiente" to false
        else -> "?% · Pedir" to true
    }
    Text(
        text,
        style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
        color = if (compatibility != null) SocialColors.Green else androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .padding(top = 2.dp)
            .let { if (clickable) it.clickable(onClick = onRequest) else it }
    )
}

@Composable
private fun PostCard(
    post: Post,
    author: com.social.app.backend.model.Profile?,
    extraMedia: List<String> = emptyList(),
    compatibility: Int?,
    isSaved: Boolean,
    isLiked: Boolean,
    onLike: () -> Unit,
    onOpenComments: () -> Unit,
    onToggleSave: () -> Unit,
    onOpenHashtag: (String) -> Unit = {},
    onOpenProfile: () -> Unit = {},
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/Twitter/TikTok -- distinto de onOpenProfile (siempre abre
    // al AUTOR del post): aquí el perfil de destino se resuelve en tiempo
    // real a partir del @usuario tocado dentro del propio caption.
    onOpenMentionProfile: (String) -> Unit = {},
    onRequestCompat: () -> Unit = {},
    // Encuesta real en una publicación normal, comparado con Twitter/X/
    // Facebook -- ver HomeViewModel.postPolls()/voteOnPostPoll(),
    // 0113_post_polls.sql.
    poll: HomeViewModel.PostPollRow? = null,
    myPollVote: Int? = null,
    onVotePoll: (Int) -> Unit = {}
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val mentionResolver = remember { MentionResolver() }
    // Hallazgo real: comparado con cualquier app grande, no había forma de
    // denunciar una publicación directamente — solo existía la denuncia
    // global de usuario (SafetyToolbar). `reports.reported_id` no tiene
    // columna de post_id, así que se denuncia al autor con el id del post
    // en los detalles, para que moderación sepa cuál — no se inventa una
    // columna nueva para esto.
    var showReport by remember { mutableStateOf(false) }
    // Hallazgo real, comparado con SOCIAL_APP.html: cada post del feed
    // muestra el % de compatibilidad con el autor en su cabecera, no solo
    // el carrusel de "Recomendados" -- estado local (no en el ViewModel,
    // a diferencia de Recomendados) porque aquí no hay una lista estable
    // de "entries" que sobreviva a la recomposición del feed a la que
    // atar el estado "pendiente" real.
    var compatRequestSent by remember(post.id) { mutableStateOf(false) }
    // Marcar contenido como sensible, comparado con Instagram/Twitter/
    // TikTok -- estado local de la propia pantalla (no se guarda quién
    // lo destapó), ver 0096_sensitive_content.sql.
    var sensitiveRevealed by remember(post.id) { mutableStateOf(false) }
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // forma de tocar una imagen para verla a tamaño completo, solo el
    // recorte fijo de la miniatura.
    var fullScreenUrl by remember { mutableStateOf<String?>(null) }
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat -- antes el icono ➤
    // solo abría el share sheet nativo del sistema, sin ninguna forma de
    // mandarla como mensaje real dentro de la propia app.
    var showSendSheet by remember { mutableStateOf(false) }
    val myId = com.social.app.backend.SupabaseManager.client.auth.currentUserOrNull()?.id
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp)) {
            // Hallazgo real, comparado con cualquier app grande
            // (Instagram/TikTok/Twitter): la tarjeta no mostraba QUIÉN
            // publicó cada post, ni dejaba tocar para ver su perfil — la
            // única pantalla con listado sin esa navegación (ver
            // HomeViewModel.authorProfiles).
            Row(
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenProfile).padding(bottom = 8.dp)
            ) {
                com.social.app.avatar.AvatarView(config = author?.avatarConfig ?: emptyMap(), size = 32.dp)
                Text(
                    author?.displayName ?: "…",
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(start = 8.dp).weight(1f)
                )
                // Hallazgo real, comparado con SOCIAL_APP.html (`.pcompat`
                // en la cabecera de cada post): la app real solo mostraba
                // el % de compatibilidad en "Recomendados", nunca junto al
                // autor de una publicación normal del feed.
                if (author != null && author.id != myId) {
                    CompatBadge(
                        compatibility = compatibility,
                        requestSent = compatRequestSent,
                        onRequest = { compatRequestSent = true; onRequestCompat() }
                    )
                }
            }
            // Etiqueta de ubicación real (texto libre, no geocodificado),
            // comparado con Instagram/Facebook/Twitter/Snapchat -- ver
            // 0095_post_location_tag.sql.
            post.locationName?.let { location ->
                Text(
                    "📍 $location",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp)
                )
            }
            post.mediaUrl?.let { firstUrl ->
                // Marcar contenido como sensible, comparado con
                // Instagram/Twitter/TikTok -- se sustituye la foto por un
                // aviso real hasta que quien la ve toca a propósito para
                // revelarla; el propio autor siempre la ve con
                // normalidad. Ver 0096_sensitive_content.sql.
                val needsSensitiveWarning = post.isSensitive && post.authorId != myId && !sensitiveRevealed
                if (needsSensitiveWarning) {
                    Column(
                        modifier = Modifier.fillMaxWidth().height(220.dp)
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(bottom = 8.dp)
                            .clickable { sensitiveRevealed = true },
                        horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text("⚠️ Puede contener contenido sensible", style = MaterialTheme.typography.bodyMedium)
                        Text("Toca para ver", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    return@let
                }
                // Comparado con Instagram/Facebook: publicaciones con varias
                // fotos (0055_post_media.sql) -- `post.mediaUrl` es siempre
                // la primera, `extraMedia` trae el resto ya en orden. Con
                // una sola foto (el caso normal hasta ahora) se muestra
                // igual que antes, sin pager ni indicador de más.
                val allUrls = remember(firstUrl, extraMedia) { listOf(firstUrl) + extraMedia }
                if (allUrls.size == 1) {
                    androidx.compose.foundation.Image(
                        painter = coil.compose.rememberAsyncImagePainter(firstUrl),
                        contentDescription = null,
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                        modifier = Modifier.fillMaxWidth().height(220.dp)
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                            .padding(bottom = 8.dp)
                            .clickable { fullScreenUrl = firstUrl }
                    )
                } else {
                    val pagerState = androidx.compose.foundation.pager.rememberPagerState(pageCount = { allUrls.size })
                    Box(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
                        androidx.compose.foundation.pager.HorizontalPager(
                            state = pagerState,
                            modifier = Modifier.fillMaxWidth().height(220.dp)
                                .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                        ) { page ->
                            val url = allUrls[page]
                            androidx.compose.foundation.Image(
                                painter = coil.compose.rememberAsyncImagePainter(url),
                                contentDescription = null,
                                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                modifier = Modifier.fillMaxSize().clickable { fullScreenUrl = url }
                            )
                        }
                        Text(
                            "${pagerState.currentPage + 1}/${allUrls.size}",
                            style = MaterialTheme.typography.labelSmall,
                            color = androidx.compose.ui.graphics.Color.White,
                            modifier = Modifier
                                .align(androidx.compose.ui.Alignment.TopEnd)
                                .padding(8.dp)
                                .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.5f))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    }
                }
            }
            post.caption?.let { caption ->
                MentionHashtagText(
                    text = caption,
                    onOpenHashtag = onOpenHashtag,
                    onOpenMention = { username ->
                        scope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenMentionProfile) }
                    }
                )
            }
            // Encuesta real en una publicación normal, comparado con
            // Twitter/X/Facebook -- ver HomeViewModel.postPolls()/
            // voteOnPostPoll(), 0113_post_polls.sql. Mismo patrón visual
            // que la encuesta de historias (StoriesBar.kt): botones antes
            // de votar, barras de porcentaje después.
            poll?.let { p ->
                Column(modifier = Modifier.padding(top = 8.dp).fillMaxWidth()) {
                    Text(p.question, style = MaterialTheme.typography.titleSmall)
                    val totalVotes = p.voteCounts.sum()
                    p.options.forEachIndexed { optionIndex, optionText ->
                        if (myPollVote != null) {
                            val votesForOption = p.voteCounts.getOrElse(optionIndex) { 0 }
                            val percent = if (totalVotes == 0) 0 else (votesForOption * 100) / totalVotes
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 6.dp)
                                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth(percent / 100f)
                                        .background(
                                            if (optionIndex == myPollVote) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                                            androidx.compose.foundation.shape.RoundedCornerShape(8.dp)
                                        )
                                )
                                Text("$optionText · $percent%", modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                            }
                        } else {
                            androidx.compose.material3.OutlinedButton(
                                onClick = { onVotePoll(optionIndex) },
                                modifier = Modifier.fillMaxWidth().padding(top = 6.dp)
                            ) { Text(optionText) }
                        }
                    }
                }
            }
            if (post.createdAt.isNotBlank()) {
                Text(
                    relativeTime(post.createdAt),
                    style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(top = 8.dp)) {
                // Ocultar el número de "me gusta" real, comparado con
                // Instagram/Facebook -- el propio autor sigue viendo su
                // cifra real siempre, solo desaparece para los demás. Ver
                // 0094_hide_like_count.sql.
                val showLikeCount = !post.hideLikeCount || post.authorId == myId
                Text(
                    if (showLikeCount) "${if (isLiked) "❤" else "🤍"} ${post.likeCount}" else if (isLiked) "❤" else "🤍",
                    modifier = Modifier.clickable(onClick = onLike).padding(end = 4.dp)
                )
                Text("💬 ${post.commentCount}", modifier = Modifier.clickable(onClick = onOpenComments))
                Text(
                    "➤",
                    // Hallazgo real, comparado con Instagram/TikTok/Twitter/
                    // Snapchat: en las cuatro apps, este icono abre un
                    // selector interno de a quién enviar (un chat, un
                    // grupo) -- el mecanismo de distribución más usado,
                    // más que el share sheet externo. Antes solo abría el
                    // share sheet nativo (ver onShareExternal más abajo,
                    // que conserva ese mismo comportamiento como opción
                    // secundaria).
                    modifier = Modifier.clickable { showSendSheet = true }
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
            // Hallazgo real, comparado con Instagram/TikTok/Facebook:
            // antes esto era un texto libre editable ("Publicación
            // ${post.id}"); ahora una referencia real
            // (0045_reports_content_reference.sql) que un admin puede
            // ver de verdad en ModerationScreen.
            postId = post.id,
            onDismiss = { showReport = false }
        )
    }
    fullScreenUrl?.let { url ->
        com.social.app.util.FullScreenImageViewer(url = url, onDismiss = { fullScreenUrl = null })
    }
    if (showSendSheet) {
        com.social.app.chat.SendPostSheet(
            postId = post.id,
            onShareExternal = {
                val text = post.caption?.let { "Mira esto en SOCIAL: $it" } ?: "Mira esto en SOCIAL"
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                }
                context.startActivity(Intent.createChooser(intent, "Compartir publicación"))
            },
            onDismiss = { showSendSheet = false }
        )
    }
}
