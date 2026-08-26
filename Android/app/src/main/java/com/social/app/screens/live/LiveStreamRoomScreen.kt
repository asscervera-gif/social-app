package com.social.app.screens.live

import android.Manifest
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import io.livekit.android.LiveKit
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.renderer.TextureViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.track.LocalVideoTrack
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.VideoTrack
import kotlinx.coroutines.launch

/**
 * Sala de un directo real -- host publica cámara+micrófono, espectadores
 * se suscriben y ven su vídeo. Motor real: LiveKit (elegido por el
 * usuario, ver 0056_live_streams.sql y live-token/index.ts). API
 * verificada contra el código fuente real de client-sdk-android en GitHub
 * (LiveKit.create/Room.connect/initVideoRenderer/RoomEvent.TrackSubscribed
 * -- ver LOOP_STATE.md para el detalle de qué se verificó y cómo), no
 * adivinada de memoria.
 *
 * Aviso de honestidad, mismo criterio que push (APNs/FCM)/duel-ai: sin un
 * proyecto LiveKit Cloud real (LIVEKIT_API_KEY/SECRET/WS_URL como secretos
 * de Supabase), `live-token` no puede emitir un token válido y `room.connect()`
 * fallará limpiamente (capturado más abajo, mismo patrón ya usado en toda
 * la sesión) -- no hay forma de probar una conexión real de vídeo en este
 * entorno sin esas credenciales, igual que push no puede enviar un aviso
 * real todavía.
 */
@Composable
fun LiveStreamRoomScreen(
    stream: LiveStream,
    isHost: Boolean,
    viewModel: LiveStreamsViewModel = viewModel(),
    onClose: () -> Unit
) {
    val context = LocalContext.current
    val room = remember { LiveKit.create(context) }
    var connecting by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var localVideoTrack by remember { mutableStateOf<VideoTrack?>(null) }
    var remoteVideoTrack by remember { mutableStateOf<VideoTrack?>(null) }
    var viewerCount by remember { mutableStateOf(stream.viewerCount) }

    // Chat en vivo real (0059_live_stream_messages.sql), comparado con
    // Instagram/TikTok Live -- antes solo había vídeo, nadie podía
    // escribir mientras veía un directo.
    val chatViewModel = remember(stream.id) { LiveStreamChatViewModel(stream.id) }
    val chatMessages by chatViewModel.messages.collectAsState()
    val senderNames by chatViewModel.senderNames.collectAsState()
    var chatDraft by remember { mutableStateOf("") }
    val chatListState = rememberLazyListState()
    LaunchedEffect(stream.id) { chatViewModel.load() }
    LaunchedEffect(chatMessages.size) {
        if (chatMessages.isNotEmpty()) chatListState.animateScrollToItem(chatMessages.size - 1)
    }

    val requestPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* si se deniega, connect() de más abajo seguirá adelante sin cámara/micro real */ }

    DisposableEffect(Unit) {
        onDispose {
            room.disconnect()
            room.release()
        }
    }

    LaunchedEffect(stream.id) {
        launch {
            room.events.collect { event ->
                when (event) {
                    is RoomEvent.TrackSubscribed -> {
                        val track = event.track
                        if (track is VideoTrack) remoteVideoTrack = track
                    }
                    is RoomEvent.TrackUnsubscribed -> {
                        if (event.track === remoteVideoTrack) remoteVideoTrack = null
                    }
                    is RoomEvent.ParticipantConnected, is RoomEvent.ParticipantDisconnected -> {
                        viewerCount = room.remoteParticipants.size
                    }
                    else -> {}
                }
            }
        }

        requestPermissions.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))

        val tokenInfo = if (isHost) viewModel.requestHostToken(stream) else viewModel.joinAndGetToken(stream)
        if (tokenInfo == null) {
            errorMessage = "No se pudo conseguir el token real del directo -- revisa que LIVEKIT_API_KEY/SECRET/WS_URL estén configurados de verdad (ver live-token/index.ts)."
            connecting = false
            return@LaunchedEffect
        }
        try {
            room.connect(tokenInfo.wsUrl, tokenInfo.token)
            if (isHost) {
                room.localParticipant.setCameraEnabled(true)
                room.localParticipant.setMicrophoneEnabled(true)
                localVideoTrack = room.localParticipant.videoTrackPublications
                    .firstOrNull { (pub, _) -> pub.source == Track.Source.CAMERA }
                    ?.second as? LocalVideoTrack
            }
            connecting = false
        } catch (e: Exception) {
            errorMessage = "No se pudo conectar al servidor real de directos: ${e.message}"
            connecting = false
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        val trackToShow = if (isHost) localVideoTrack else remoteVideoTrack
        if (trackToShow != null) {
            LiveVideoView(room = room, videoTrack = trackToShow, modifier = Modifier.fillMaxSize())
        } else if (!connecting && errorMessage == null) {
            Text(
                if (isHost) "Cámara conectándose…" else "Esperando el vídeo del host…",
                color = Color.White,
                modifier = Modifier.align(Alignment.Center)
            )
        }

        if (connecting) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.Center), color = Color.White)
        }

        errorMessage?.let {
            Text(
                it,
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.align(Alignment.Center).padding(24.dp)
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter).padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("👁 $viewerCount", color = Color.White, style = MaterialTheme.typography.labelLarge)
            Text(stream.title ?: "Directo", color = Color.White, style = MaterialTheme.typography.labelLarge)
        }

        // Chat en vivo real, comparado con Instagram/TikTok Live: lista de
        // mensajes que se desplaza sobre el vídeo (abajo a la izquierda,
        // mismo sitio que esas apps), más el compositor para escribir.
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth(0.68f)
                .padding(start = 16.dp, end = 8.dp, bottom = 96.dp)
        ) {
            LazyColumn(
                state = chatListState,
                modifier = Modifier.height(180.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                items(chatMessages, key = { it.id }) { message ->
                    Text(
                        buildString {
                            append(senderNames[message.senderId] ?: "…")
                            append(": ")
                            append(message.body)
                        },
                        color = Color.White,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.Black.copy(alpha = 0.35f))
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                    )
                }
            }
        }

        Column(modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(16.dp)) {
            if (stream.status == "live") {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 12.dp)) {
                    OutlinedTextField(
                        value = chatDraft,
                        onValueChange = { chatDraft = it },
                        modifier = Modifier.weight(1f).height(52.dp),
                        placeholder = { Text("Comenta…", color = Color.White.copy(alpha = 0.6f)) },
                        colors = TextFieldDefaults.colors(
                            focusedTextColor = Color.White,
                            unfocusedTextColor = Color.White,
                            focusedContainerColor = Color.Black.copy(alpha = 0.3f),
                            unfocusedContainerColor = Color.Black.copy(alpha = 0.3f)
                        )
                    )
                    Text(
                        "➤",
                        color = Color.White,
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .clip(RoundedCornerShape(50))
                            .background(MaterialTheme.colorScheme.primary)
                            .clickable {
                                if (chatDraft.isNotBlank()) {
                                    chatViewModel.sendMessage(chatDraft)
                                    chatDraft = ""
                                }
                            }
                            .padding(12.dp)
                    )
                }
            }
            Button(onClick = {
                if (isHost) viewModel.endStream(stream) else viewModel.leaveStream(stream)
                onClose()
            }) {
                Text(if (isHost) "Terminar directo" else "Salir")
            }
        }
    }
}

/** Interop Compose/View mínimo para [TextureViewRenderer] -- versión
 * simplificada de `VideoRenderer.kt` del propio sample-app-compose de
 * LiveKit (sin seguimiento de visibilidad ni pinch-zoom, no esenciales
 * para esta primera versión). `addRenderer(view)` de un solo argumento
 * funciona igual para pistas locales y remotas (comprobado en el código
 * fuente real de `RemoteVideoTrack.kt`: sin `autoManageVideo`, cae al
 * mismo `addRenderer` base que usa `LocalVideoTrack`). */
@Composable
private fun LiveVideoView(room: Room, videoTrack: VideoTrack, modifier: Modifier = Modifier) {
    var view: TextureViewRenderer? by remember { mutableStateOf(null) }
    var boundTrack: VideoTrack? by remember { mutableStateOf(null) }

    DisposableEffect(room, videoTrack) {
        onDispose {
            view?.let { boundTrack?.removeRenderer(it) }
            view?.release()
        }
    }

    AndroidView(
        factory = { ctx ->
            TextureViewRenderer(ctx).apply {
                room.initVideoRenderer(this)
                videoTrack.addRenderer(this)
                boundTrack = videoTrack
                view = this
            }
        },
        update = { v ->
            if (boundTrack !== videoTrack) {
                boundTrack?.removeRenderer(v)
                videoTrack.addRenderer(v)
                boundTrack = videoTrack
            }
        },
        modifier = modifier
    )
}
