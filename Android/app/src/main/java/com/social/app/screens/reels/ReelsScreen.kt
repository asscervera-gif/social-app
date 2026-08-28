package com.social.app.screens.reels

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import io.github.jan.supabase.gotrue.auth
import com.social.app.util.MentionHashtagText
import com.social.app.util.MentionResolver
import com.social.app.util.relativeTime
import kotlinx.coroutines.launch

/**
 * Feed vertical de reels -- primera UI de cliente real sobre el backend de
 * la ronda anterior (ver ReelsViewModel.kt). Un solo ExoPlayer real
 * reutilizado entre páginas (se cambia el `MediaItem` al pasar de reel, no
 * se crea un reproductor nuevo por cada uno) -- mismo criterio de cuidar
 * los recursos del dispositivo ya aplicado al emulador/Gradle en esta sesión.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReelsScreen(
    // Abrir un reel concreto real desde un aviso de "like"/"comentario",
    // comparado con Instagram/TikTok -- ver ReelsViewModel.kt.load() para
    // el hallazgo completo.
    initialReelId: String? = null,
    viewModel: ReelsViewModel = viewModel(),
    onOpenProfile: (String) -> Unit = {}
) {
    val reels by viewModel.reels.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()
    val likedReelIds by viewModel.likedReelIds.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var showUpload by remember { mutableStateOf(false) }
    var commentingReelId by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    var hasJumpedToInitial by remember { mutableStateOf(false) }
    val myId = com.social.app.backend.SupabaseManager.client.auth.currentUserOrNull()?.id

    LaunchedEffect(Unit) { viewModel.load(pinnedReelId = initialReelId) }

    val exoPlayer = remember { ExoPlayer.Builder(context).build() }
    DisposableEffect(Unit) {
        onDispose { exoPlayer.release() }
    }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = { showUpload = true }) {
                Text("+", style = MaterialTheme.typography.headlineSmall)
            }
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            if (isLoading && reels.isEmpty()) {
                CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
            }
            errorMessage?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.align(Alignment.TopCenter).padding(16.dp))
            }
            if (reels.isEmpty() && !isLoading && errorMessage == null) {
                Text(
                    "Todavía no hay ningún reel. Sé el primero.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.align(Alignment.Center).padding(24.dp)
                )
            }
            if (reels.isNotEmpty()) {
                val pagerState = rememberPagerState(pageCount = { reels.size })
                // Abrir un reel concreto real desde un aviso, comparado
                // con Instagram/TikTok -- salta una sola vez, apenas el
                // reel señalado por el aviso aparece en la lista (recién
                // cargada, o antepuesto por ReelsViewModel.kt.load() si no
                // estaba entre los 30 más recientes). Sin esto, un
                // `LaunchedEffect(reels)` saltaría de nuevo cada vez que
                // `reels` cambia por cualquier otro motivo (dar like,
                // comentar), devolviendo al usuario al reel del aviso sin
                // querer.
                LaunchedEffect(reels) {
                    if (!hasJumpedToInitial && initialReelId != null) {
                        val index = reels.indexOfFirst { it.id == initialReelId }
                        if (index >= 0) {
                            pagerState.scrollToPage(index)
                            hasJumpedToInitial = true
                        }
                    }
                }
                LaunchedEffect(pagerState.currentPage, reels) {
                    val current = reels.getOrNull(pagerState.currentPage) ?: return@LaunchedEffect
                    exoPlayer.setMediaItem(MediaItem.fromUri(current.videoUrl))
                    exoPlayer.prepare()
                    exoPlayer.playWhenReady = true
                    // Contador real de vistas, comparado con TikTok/
                    // Instagram Reels -- ver ReelsViewModel.trackView(),
                    // 0131_reel_view_count.sql. No cuenta las vistas del
                    // propio autor sobre su propio reel.
                    if (current.authorId != myId) {
                        viewModel.trackView(current)
                    }
                }
                VerticalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
                    val reel = reels[page]
                    ReelPage(
                        reel = reel,
                        author = authorProfiles[reel.authorId],
                        isLiked = likedReelIds.contains(reel.id),
                        isCurrent = page == pagerState.currentPage,
                        isMine = reel.authorId == myId,
                        player = exoPlayer,
                        onLike = { viewModel.toggleLike(reel) },
                        onOpenProfile = { onOpenProfile(reel.authorId) },
                        onOpenMentionProfile = onOpenProfile,
                        onOpenComments = { commentingReelId = reel.id },
                        // Desactivar los comentarios de este reel propio,
                        // comparado con Instagram/TikTok -- ver
                        // ReelsViewModel.toggleCommentsDisabled(),
                        // 0086_disable_comments.sql.
                        onToggleCommentsDisabled = { viewModel.toggleCommentsDisabled(reel) },
                        onToggleHideLikeCount = { viewModel.toggleHideLikeCount(reel) },
                        onToggleSensitive = { viewModel.toggleSensitive(reel) },
                        onCycleReplyAudience = { viewModel.cycleReplyAudience(reel) }
                    )
                }
            }
        }
    }

    if (showUpload) {
        UploadReelSheet(
            isUploading = viewModel.isUploading.collectAsState().value,
            onDismiss = { showUpload = false },
            onUpload = { uri, caption, isSocialOnly, locationName ->
                viewModel.upload(context, uri, caption, isSocialOnly, locationName) { success ->
                    if (success) showUpload = false
                }
            }
        )
    }

    // Hueco real cerrado en esta pasada: reels ya mostraba el contador de
    // comentarios (reel.commentCount) pero no había ninguna pantalla para
    // leerlos o escribirlos. Mismo patrón que CommentsSheet.kt (posts).
    commentingReelId?.let { reelId ->
        com.social.app.screens.reels.ReelCommentsSheet(
            reelId = reelId,
            onDismiss = { commentingReelId = null },
            onCommentAdded = { viewModel.commentAdded(reelId) },
            onCommentRemoved = { viewModel.commentRemoved(reelId) },
            onOpenProfile = { profileId -> commentingReelId = null; onOpenProfile(profileId) }
        )
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ReelPage(
    reel: Reel,
    author: com.social.app.backend.model.Profile?,
    isLiked: Boolean,
    isCurrent: Boolean,
    // Desactivar los comentarios de un reel propio, comparado con
    // Instagram/TikTok -- el control solo tiene sentido sobre el reel
    // propio (0086_disable_comments.sql).
    isMine: Boolean,
    player: ExoPlayer,
    onLike: () -> Unit,
    onOpenProfile: () -> Unit,
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/TikTok -- mismo criterio que
    // HomeScreen.kt.PostCard.onOpenMentionProfile.
    onOpenMentionProfile: (String) -> Unit = {},
    onOpenComments: () -> Unit,
    onToggleCommentsDisabled: () -> Unit,
    onToggleHideLikeCount: () -> Unit,
    onToggleSensitive: () -> Unit,
    onCycleReplyAudience: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val mentionResolver = remember { MentionResolver() }
    // Marcar contenido como sensible, comparado con Instagram/Twitter/
    // TikTok -- estado local de la propia pantalla, ver
    // 0096_sensitive_content.sql.
    var sensitiveRevealed by remember(reel.id) { mutableStateOf(false) }
    val needsSensitiveWarning = reel.isSensitive && !isMine && !sensitiveRevealed
    Box(modifier = Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
        if (isCurrent && !needsSensitiveWarning) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        this.player = player
                    }
                },
                modifier = Modifier.fillMaxSize()
            )
        }
        // Doble toque para dar "me gusta", comparado con Instagram/
        // TikTok/Facebook -- mismo hueco real ya cerrado en el feed de
        // publicaciones (HomeScreen.kt), ahora también en reels. Doble
        // toque SIEMPRE da like (nunca lo quita).
        var showReelDoubleTapHeart by remember(reel.id) { mutableStateOf(false) }
        if (isCurrent && !needsSensitiveWarning) {
            Box(
                modifier = Modifier.fillMaxSize().combinedClickable(
                    onClick = {},
                    onDoubleClick = {
                        if (!isLiked) onLike()
                        showReelDoubleTapHeart = true
                    },
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null
                ),
                contentAlignment = Alignment.Center
            ) {
                androidx.compose.animation.AnimatedVisibility(
                    visible = showReelDoubleTapHeart,
                    enter = androidx.compose.animation.scaleIn(),
                    exit = androidx.compose.animation.fadeOut()
                ) {
                    Text("❤", style = MaterialTheme.typography.displayLarge, color = androidx.compose.ui.graphics.Color.White)
                }
            }
            if (showReelDoubleTapHeart) {
                LaunchedEffect(showReelDoubleTapHeart) {
                    kotlinx.coroutines.delay(600)
                    showReelDoubleTapHeart = false
                }
            }
        }
        if (needsSensitiveWarning) {
            Column(
                modifier = Modifier.fillMaxSize().clickable { sensitiveRevealed = true },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text("⚠️ Puede contener contenido sensible", color = androidx.compose.ui.graphics.Color.White, style = MaterialTheme.typography.bodyMedium)
                Text("Toca para ver", color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelSmall)
            }
        }
        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.Bottom
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable(onClick = onOpenProfile)
            ) {
                com.social.app.avatar.AvatarView(config = author?.avatarConfig ?: emptyMap(), size = 36.dp)
                Text(
                    author?.displayName ?: "…",
                    color = androidx.compose.ui.graphics.Color.White,
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }
            // @menciones reales (0073_profile_username.sql +
            // 0074_mentions.sql), comparado con Instagram/TikTok --
            // `baseColor`/`linkColor` en blanco fijo, igual que el resto de
            // esta pantalla sobre el vídeo (no el esquema normal de la app).
            reel.caption?.let { caption ->
                MentionHashtagText(
                    text = caption,
                    modifier = Modifier.padding(top = 6.dp),
                    baseColor = androidx.compose.ui.graphics.Color.White,
                    linkColor = androidx.compose.ui.graphics.Color.White,
                    onOpenMention = { username ->
                        scope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenMentionProfile) }
                    }
                )
            }
            // Etiqueta de ubicación real, comparado con Instagram/TikTok
            // -- mismo diseño exacto que posts.locationName
            // (HomeScreen.kt), ver 0114_reel_location_tag.sql.
            reel.locationName?.let { location ->
                Text(
                    "📍 $location",
                    style = MaterialTheme.typography.labelSmall,
                    color = androidx.compose.ui.graphics.Color.White,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
            Text(
                relativeTime(reel.createdAt),
                color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.7f),
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.padding(top = 2.dp)
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 10.dp)
            ) {
                Text(
                    if (isLiked) "❤" else "🤍",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.clickable(onClick = onLike)
                )
                // Ocultar el número de "me gusta" real, comparado con
                // Instagram/Facebook -- el propio autor (isMine) sigue
                // viendo su cifra real siempre, solo desaparece para los
                // demás. Ver 0094_hide_like_count.sql.
                val showLikeCount = !reel.hideLikeCount || isMine
                Text(
                    if (showLikeCount) " ${reel.likeCount}   💬 ${reel.commentCount}" else "💬 ${reel.commentCount}",
                    modifier = Modifier.clickable(onClick = onOpenComments),
                    color = androidx.compose.ui.graphics.Color.White
                )
                // Contador real de vistas, comparado con TikTok/Instagram
                // Reels -- ver ReelsViewModel.trackView(),
                // 0131_reel_view_count.sql.
                Text(
                    "   👁 ${reel.viewCount}",
                    color = androidx.compose.ui.graphics.Color.White
                )
                // Desactivar los comentarios de este reel propio,
                // comparado con Instagram/TikTok -- los comentarios
                // previos se quedan, solo se cierra la puerta a
                // comentarios nuevos (0086_disable_comments.sql).
                if (isMine) {
                    Text(
                        if (reel.commentsDisabled) "🔕💬" else "🔔💬",
                        modifier = Modifier
                            .padding(start = 10.dp)
                            .clickable(onClick = onToggleCommentsDisabled),
                        color = androidx.compose.ui.graphics.Color.White
                    )
                    // Ocultar el número de "me gusta" real, comparado
                    // con Instagram/Facebook -- ver
                    // ReelsViewModel.toggleHideLikeCount(),
                    // 0094_hide_like_count.sql.
                    Text(
                        if (reel.hideLikeCount) "🙈❤" else "👁❤",
                        modifier = Modifier
                            .padding(start = 10.dp)
                            .clickable(onClick = onToggleHideLikeCount),
                        color = androidx.compose.ui.graphics.Color.White
                    )
                    // Marcar contenido como sensible, comparado con
                    // Instagram/Twitter/TikTok -- ver
                    // ReelsViewModel.toggleSensitive(),
                    // 0096_sensitive_content.sql.
                    Text(
                        if (reel.isSensitive) "⚠️✅" else "⚠️",
                        modifier = Modifier
                            .padding(start = 10.dp)
                            .clickable(onClick = onToggleSensitive),
                        color = androidx.compose.ui.graphics.Color.White
                    )
                    // "¿Quién puede comentar?" real, comparado con
                    // Twitter/X/TikTok -- ver
                    // ReelsViewModel.cycleReplyAudience(),
                    // 0097_reply_audience.sql.
                    Text(
                        when (reel.replyAudience) {
                            "followers" -> "💬🧑‍🤝‍🧑"
                            "mentioned" -> "💬@"
                            else -> "💬🌐"
                        },
                        modifier = Modifier
                            .padding(start = 10.dp)
                            .clickable(onClick = onCycleReplyAudience),
                        color = androidx.compose.ui.graphics.Color.White
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UploadReelSheet(isUploading: Boolean, onDismiss: () -> Unit, onUpload: (Uri, String, Boolean, String) -> Unit) {
    var videoUri by remember { mutableStateOf<Uri?>(null) }
    var caption by remember { mutableStateOf("") }
    var isSocialOnly by remember { mutableStateOf(false) }
    // Etiqueta de ubicación real, comparado con Instagram/TikTok -- ver
    // ReelsViewModel.upload(), 0114_reel_location_tag.sql.
    var locationName by remember { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState()

    val pickVideo = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        videoUri = uri
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            Text("Nuevo reel", style = MaterialTheme.typography.titleLarge)
            OutlinedButton(
                onClick = { pickVideo.launch("video/*") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            ) {
                Text(if (videoUri == null) "Elegir vídeo" else "Cambiar vídeo")
            }
            OutlinedTextField(
                value = caption,
                onValueChange = { caption = it },
                label = { Text("Descripción (opcional)") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            OutlinedTextField(
                value = locationName,
                onValueChange = { locationName = it },
                label = { Text("📍 Añadir ubicación (opcional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(checked = isSocialOnly, onCheckedChange = { isSocialOnly = it })
                Text("Solo visible para tus socials aceptados")
            }
            Button(
                onClick = { videoUri?.let { onUpload(it, caption, isSocialOnly, locationName) } },
                enabled = videoUri != null && !isUploading,
                // Mismo criterio de modo oscuro que PerfilScreen.kt: colores
                // de rol de tema, no un literal fijo que se volvería
                // invisible en fondo oscuro.
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.onBackground,
                    contentColor = MaterialTheme.colorScheme.background
                ),
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text(if (isUploading) "Publicando…" else "Publicar reel")
            }
        }
    }
}
