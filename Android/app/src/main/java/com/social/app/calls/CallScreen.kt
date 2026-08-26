package com.social.app.calls

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Call
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.livekit.android.LiveKit
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.renderer.TextureViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.track.LocalVideoTrack
import io.livekit.android.room.track.Track
import io.livekit.android.room.track.VideoTrack
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado con
 * WhatsApp/Messenger/Instagram -- ver CallManager.kt para el hallazgo
 * completo. Overlay real montado en RootTabView.kt (visible sobre
 * cualquier pestaña, igual que un aviso), no una pantalla de navegación
 * normal: una llamada entrante no debe esperar a que el usuario navegue a
 * ningún sitio.
 */
@Composable
fun CallOverlay(callManager: CallManager, myId: String) {
    val call by callManager.activeCall.collectAsState()
    call?.let { c ->
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            when {
                c.status == "ringing" && c.calleeId == myId ->
                    IncomingCallScreen(call = c, onAccept = callManager::accept, onDecline = callManager::decline)
                c.status == "ringing" && c.callerId == myId ->
                    OutgoingCallScreen(call = c, onCancel = callManager::cancelOutgoing)
                c.status == "accepted" ->
                    LiveCallScreen(call = c, myId = myId, callManager = callManager, onEnd = callManager::end)
                else ->
                    TerminalCallScreen(call = c, onDismiss = callManager::dismiss)
            }
        }
    }
}

@Serializable
private data class NameRow(@SerialName("display_name") val displayName: String)

@Composable
private fun rememberProfileName(profileId: String): String {
    var name by remember(profileId) { mutableStateOf("…") }
    LaunchedEffect(profileId) {
        try {
            val row = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("display_name")) { filter { eq("id", profileId) } }
                .decodeSingleOrNull<NameRow>()
            name = row?.displayName ?: "Alguien"
        } catch (e: Exception) {
            // Se queda con "…" -- no crítico para poder aceptar/colgar.
        }
    }
    return name
}

@Composable
private fun IncomingCallScreen(call: Call, onAccept: () -> Unit, onDecline: () -> Unit) {
    val name = rememberProfileName(call.callerId)
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(top = 64.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                if (call.kind == "video") "Videollamada entrante" else "Llamada entrante",
                color = Color.White.copy(alpha = 0.7f),
                style = MaterialTheme.typography.labelLarge
            )
            Text(name, color = Color.White, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 8.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(48.dp), modifier = Modifier.padding(bottom = 48.dp)) {
            CallActionButton(icon = Icons.Filled.CallEnd, background = Color(0xFFE53935), onClick = onDecline)
            CallActionButton(icon = Icons.Filled.Call, background = Color(0xFF43A047), onClick = onAccept)
        }
    }
}

@Composable
private fun OutgoingCallScreen(call: Call, onCancel: () -> Unit) {
    val name = rememberProfileName(call.calleeId)
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(top = 64.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("Llamando…", color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelLarge)
            Text(name, color = Color.White, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 8.dp))
        }
        CallActionButton(icon = Icons.Filled.CallEnd, background = Color(0xFFE53935), onClick = onCancel, modifier = Modifier.padding(bottom = 48.dp))
    }
}

@Composable
private fun TerminalCallScreen(call: Call, onDismiss: () -> Unit) {
    val message = when (call.status) {
        "declined" -> "Llamada rechazada"
        "missed" -> "No contestó"
        else -> "Llamada finalizada"
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(message, color = Color.White, style = MaterialTheme.typography.headlineSmall)
        OutlinedButton(onClick = onDismiss, modifier = Modifier.padding(top = 24.dp)) {
            Text("Cerrar")
        }
    }
}

/**
 * Sala de llamada real -- mismo motor y misma API real que
 * LiveStreamRoomScreen.kt (verificada contra el código fuente de
 * client-sdk-android en GitHub), pero simétrica: las dos partes publican
 * cámara/micrófono (según `kind`) y se suscriben por igual, sin
 * distinción host/espectador.
 *
 * Aviso de honestidad, mismo criterio que "En directo": sin un proyecto
 * LiveKit Cloud real (LIVEKIT_API_KEY/SECRET/WS_URL como secretos de
 * Supabase), `call-token` no puede emitir un token válido y
 * `room.connect()` fallará limpiamente (capturado más abajo).
 */
@Composable
private fun LiveCallScreen(call: Call, myId: String, callManager: CallManager, onEnd: () -> Unit) {
    val context = LocalContext.current
    val room = remember { LiveKit.create(context) }
    val scope = rememberCoroutineScope()
    val otherId = if (call.callerId == myId) call.calleeId else call.callerId
    val name = rememberProfileName(otherId)
    var connecting by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var localVideoTrack by remember { mutableStateOf<VideoTrack?>(null) }
    var remoteVideoTrack by remember { mutableStateOf<VideoTrack?>(null) }
    var micEnabled by remember { mutableStateOf(true) }
    var cameraEnabled by remember { mutableStateOf(call.kind == "video") }

    val requestPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* si se deniega, connect() seguirá adelante sin cámara/micro real */ }

    DisposableEffect(Unit) {
        onDispose {
            room.disconnect()
            room.release()
        }
    }

    LaunchedEffect(call.id) {
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
                    is RoomEvent.Disconnected -> onEnd()
                    else -> {}
                }
            }
        }

        val permissions = if (call.kind == "video") {
            arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        } else {
            arrayOf(Manifest.permission.RECORD_AUDIO)
        }
        requestPermissions.launch(permissions)

        val tokenInfo = callManager.requestToken(call.id)
        if (tokenInfo == null) {
            errorMessage = "No se pudo conseguir el token real de la llamada -- revisa que LIVEKIT_API_KEY/SECRET/WS_URL estén configurados de verdad (ver call-token/index.ts)."
            connecting = false
            return@LaunchedEffect
        }
        try {
            room.connect(tokenInfo.wsUrl, tokenInfo.token)
            room.localParticipant.setMicrophoneEnabled(true)
            if (call.kind == "video") {
                room.localParticipant.setCameraEnabled(true)
                localVideoTrack = room.localParticipant.videoTrackPublications
                    .firstOrNull { (pub, _) -> pub.source == Track.Source.CAMERA }
                    ?.second as? LocalVideoTrack
            }
            connecting = false
        } catch (e: Exception) {
            errorMessage = "No se pudo conectar al servidor real de llamadas: ${e.message}"
            connecting = false
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (call.kind == "video" && remoteVideoTrack != null) {
            LiveCallVideoView(room = room, videoTrack = remoteVideoTrack!!, modifier = Modifier.fillMaxSize())
        } else if (!connecting && errorMessage == null) {
            Column(modifier = Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    modifier = Modifier.size(96.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center
                ) { Text(name.take(1).uppercase(), style = MaterialTheme.typography.headlineLarge) }
                Text(name, color = Color.White, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 12.dp))
                if (call.kind == "video") {
                    Text("Esperando el vídeo…", color = Color.White.copy(alpha = 0.7f), modifier = Modifier.padding(top = 4.dp))
                }
            }
        }

        // Vista propia en miniatura, mismo sitio que cualquier app de
        // videollamada (esquina superior derecha).
        if (call.kind == "video" && cameraEnabled && localVideoTrack != null) {
            LiveCallVideoView(
                room = room,
                videoTrack = localVideoTrack!!,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
                    .size(width = 100.dp, height = 140.dp)
                    .clip(MaterialTheme.shapes.medium)
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
            modifier = Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(32.dp),
            horizontalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            CallActionButton(
                icon = if (micEnabled) Icons.Filled.Mic else Icons.Filled.MicOff,
                background = Color.White.copy(alpha = 0.2f),
                onClick = {
                    micEnabled = !micEnabled
                    scope.launch { room.localParticipant.setMicrophoneEnabled(micEnabled) }
                }
            )
            if (call.kind == "video") {
                CallActionButton(
                    icon = if (cameraEnabled) Icons.Filled.Videocam else Icons.Filled.VideocamOff,
                    background = Color.White.copy(alpha = 0.2f),
                    onClick = {
                        cameraEnabled = !cameraEnabled
                        scope.launch { room.localParticipant.setCameraEnabled(cameraEnabled) }
                    }
                )
            }
            CallActionButton(icon = Icons.Filled.CallEnd, background = Color(0xFFE53935), onClick = onEnd)
        }
    }
}

@Composable
private fun CallActionButton(icon: androidx.compose.ui.graphics.vector.ImageVector, background: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(
        onClick = onClick,
        modifier = modifier.size(64.dp).clip(CircleShape).background(background)
    ) {
        Icon(icon, contentDescription = null, tint = Color.White)
    }
}

/** Mismo interop mínimo Compose/View que LiveStreamRoomScreen.kt.LiveVideoView. */
@Composable
private fun LiveCallVideoView(room: Room, videoTrack: VideoTrack, modifier: Modifier = Modifier) {
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
