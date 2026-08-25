package com.social.app.screens.reels

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import com.social.app.ui.theme.SocialColors
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
fun ReelsScreen(viewModel: ReelsViewModel = viewModel(), onOpenProfile: (String) -> Unit = {}) {
    val reels by viewModel.reels.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()
    val likedReelIds by viewModel.likedReelIds.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var showUpload by remember { mutableStateOf(false) }
    var commentingReelId by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current

    LaunchedEffect(Unit) { viewModel.load() }

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
                LaunchedEffect(pagerState.currentPage, reels) {
                    val current = reels.getOrNull(pagerState.currentPage) ?: return@LaunchedEffect
                    exoPlayer.setMediaItem(MediaItem.fromUri(current.videoUrl))
                    exoPlayer.prepare()
                    exoPlayer.playWhenReady = true
                }
                VerticalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
                    val reel = reels[page]
                    ReelPage(
                        reel = reel,
                        author = authorProfiles[reel.authorId],
                        isLiked = likedReelIds.contains(reel.id),
                        isCurrent = page == pagerState.currentPage,
                        player = exoPlayer,
                        onLike = { viewModel.toggleLike(reel) },
                        onOpenProfile = { onOpenProfile(reel.authorId) },
                        onOpenComments = { commentingReelId = reel.id }
                    )
                }
            }
        }
    }

    if (showUpload) {
        UploadReelSheet(
            isUploading = viewModel.isUploading.collectAsState().value,
            onDismiss = { showUpload = false },
            onUpload = { uri, caption, isSocialOnly ->
                viewModel.upload(context, uri, caption, isSocialOnly) { success ->
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

@Composable
private fun ReelPage(
    reel: Reel,
    author: com.social.app.backend.model.Profile?,
    isLiked: Boolean,
    isCurrent: Boolean,
    player: ExoPlayer,
    onLike: () -> Unit,
    onOpenProfile: () -> Unit,
    onOpenComments: () -> Unit
) {
    Box(modifier = Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
        if (isCurrent) {
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
            reel.caption?.let {
                Text(it, color = androidx.compose.ui.graphics.Color.White, modifier = Modifier.padding(top = 6.dp))
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
                Text(
                    " ${reel.likeCount}   💬 ${reel.commentCount}",
                    modifier = Modifier.clickable(onClick = onOpenComments),
                    color = androidx.compose.ui.graphics.Color.White
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UploadReelSheet(isUploading: Boolean, onDismiss: () -> Unit, onUpload: (Uri, String, Boolean) -> Unit) {
    var videoUri by remember { mutableStateOf<Uri?>(null) }
    var caption by remember { mutableStateOf("") }
    var isSocialOnly by remember { mutableStateOf(false) }
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
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(checked = isSocialOnly, onCheckedChange = { isSocialOnly = it })
                Text("Solo visible para tus socials aceptados")
            }
            Button(
                onClick = { videoUri?.let { onUpload(it, caption, isSocialOnly) } },
                enabled = videoUri != null && !isUploading,
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = SocialColors.Ink),
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text(if (isUploading) "Publicando…" else "Publicar reel")
            }
        }
    }
}
