package com.social.app.util

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView

/**
 * Vídeo real en el chat (0121_video_messages.sql), comparado con
 * WhatsApp/Telegram/iMessage -- mismo criterio de visor mínimo ya usado en
 * FullScreenImageViewer.kt, con controles nativos de ExoPlayer (ya
 * dependencia real del proyecto, usada en ReelsScreen.kt) en vez de
 * construir controles propios.
 */
@Composable
fun FullScreenVideoViewer(url: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val player = remember { ExoPlayer.Builder(context).build().apply { setMediaItem(MediaItem.fromUri(url)); prepare(); playWhenReady = true } }
    DisposableEffect(Unit) { onDispose { player.release() } }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView(
                factory = { ctx -> PlayerView(ctx).apply { useController = true; this.player = player } },
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}
