package com.social.app.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import android.location.LocationManager
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.getSystemService
import com.social.app.backend.AnalyticsManager
import com.social.app.backend.SupabaseManager
import com.social.app.event.EventModeBanner
import com.social.app.event.EventModeViewModel
import com.social.app.proximity.SocialProximity
import com.social.app.safety.ReportSheet
import com.social.app.safety.SafetyManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.coroutines.launch
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Pantalla de inicio de SOCIAL en Android — equivalente a
 * SocialCameraView.swift: cámara en vivo, marcadores flotantes posicionados
 * por UWB, contador de densidad (nunca vacío sin explicación) y modo
 * invisible real en un toque.
 */
@Composable
fun SocialCameraScreen(proximity: SocialProximity, onOpenProfile: (String) -> Unit = {}) {
    val peers by proximity.peers.collectAsState()
    val discoveredCount by proximity.discoveredCount.collectAsState()
    val statusMessage by proximity.statusMessage.collectAsState()
    var isInvisible by remember { mutableStateOf(false) }
    var showReportSheet by remember { mutableStateOf(false) }
    var selectedPeer by remember { mutableStateOf<com.social.app.proximity.PeerProximity?>(null) }
    val socialLinks = remember { com.social.app.chat.SocialLinkManager() }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val currentUserId = SupabaseManager.client.auth.currentUserOrNull()?.id
    val safety: SafetyManager = viewModel()
    val eventMode: EventModeViewModel = viewModel()
    val context = LocalContext.current
    // Hallazgo real, reportado directamente por el usuario probando la
    // app de verdad: "el muñeco que sale en social al entrar no
    // significa nada" -- PeerMarker dibujaba un degradado aleatorio sin
    // relación con la persona detectada. Se resuelve el perfil real
    // (nombre + avatar) en cuanto el UWB identifica un profileId, mismo
    // patrón de caché que fetchActorProfiles en AvisosViewModel.kt.
    var peerProfiles by remember { mutableStateOf<Map<String, com.social.app.backend.model.Profile>>(emptyMap()) }
    LaunchedEffect(peers.values.mapNotNull { it.profileId }.toSet()) {
        val missing = peers.values.mapNotNull { it.profileId }.toSet() - peerProfiles.keys
        if (missing.isEmpty()) return@LaunchedEffect
        try {
            val fetched = SupabaseManager.client.from("profiles")
                .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("id,display_name,avatar_config")) {
                    filter { isIn("id", missing.toList()) }
                }
                .decodeList<com.social.app.backend.model.Profile>()
                .associateBy { it.id }
            peerProfiles = peerProfiles + fetched
        } catch (e: Exception) {
            // Sin perfil resuelto todavía, PeerMarker cae al estado
            // honesto "Alguien cerca" -- no bloquea el resto de la pantalla.
        }
    }

    // Ubicación mínima para Modo Evento — comprueba si el usuario está dentro
    // del radio de algún evento activo (mismo criterio que EventLocationProvider
    // en iOS). Usa LocationManager de plataforma directamente, sin añadir la
    // dependencia de Play Services Location solo para esto.
    //
    // Hallazgo real, alineado con growth_strategy.md sección 5
    // ("Fiabilidad del UWB por encima de todo... un usuario que prueba la
    // función estrella y no funciona no vuelve a abrir la app" — el mismo
    // criterio aplica aquí): antes esto se comprobaba UNA SOLA VEZ al
    // componer la pantalla, con `getLastKnownLocation` (puede ser nulo o
    // estar desactualizado si el GPS no se ha usado recientemente). Si el
    // usuario abría la cámara antes de llegar al recinto del evento, o el
    // caché de ubicación estaba vacío, Modo Evento nunca se activaba en
    // toda la sesión — ni siquiera acercándose después. Ahora se repite
    // cada 30s mientras la pantalla está abierta.
    LaunchedEffect(Unit) {
        val locationManager = context.getSystemService<LocationManager>() ?: return@LaunchedEffect
        while (true) {
            try {
                val lastKnown = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
                    .mapNotNull { runCatching { locationManager.getLastKnownLocation(it) }.getOrNull() }
                    .firstOrNull()
                lastKnown?.let { eventMode.checkForNearbyEvent(it) }
            } catch (e: SecurityException) {
                // Sin permiso de ubicación concedido todavía: Modo Evento
                // simplemente no se activa, el resto de la pantalla sigue
                // igual — se reintenta en el siguiente ciclo por si el
                // usuario concede el permiso mientras tanto.
            }
            kotlinx.coroutines.delay(30_000)
        }
    }

    // Carga los bloqueados (tabla `blocks`) y se los pasa al motor UWB para
    // que nunca se muestren como marcador, aunque estén físicamente cerca —
    // mismo refuerzo de seguridad que loadBlockedPeers() en SocialCameraView.swift.
    LaunchedEffect(Unit) {
        @Serializable
        data class BlockRow(@SerialName("blocked_id") val blockedId: String)
        try {
            // Optimización: BlockRow solo decodifica blocked_id, no la fila
            // completa (id, blocker_id, created_at) — mismo patrón que
            // MatchViewModel/HomeViewModel/DuelEntryPoint.
            val ids = SupabaseManager.client.from("blocks")
                .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("blocked_id"))
                .decodeList<BlockRow>()
            proximity.blockedPeerIds = ids.map { java.util.UUID.fromString(it.blockedId) }.toSet()
        } catch (e: Exception) {
            // Sin conexión al backend, se sigue funcionando sin la lista de
            // bloqueados — no es motivo para romper la detección UWB local.
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        CameraPreview(modifier = Modifier.fillMaxSize())

        // Radar de fondo -- comparado con el boceto real
        // (social_boceto.html, .radar/.sweep): refuerza visualmente que
        // SOCIAL está escaneando de verdad alrededor tuyo, la "brújula"
        // pedida directamente por el usuario. Anclado cerca del centro
        // inferior, detrás de los marcadores reales.
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
            RadarBackground(modifier = Modifier.padding(bottom = 70.dp))
        }

        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val widthPx = constraints.maxWidth.toFloat()
            val heightPx = constraints.maxHeight.toFloat()

            peers.values.forEach { proximityEntry ->
                val offset = proximityEntry.markerOffset(widthPx, heightPx) ?: return@forEach
                val density = androidx.compose.ui.platform.LocalDensity.current
                val xDp = with(density) { offset.x.toDp() }
                val yDp = with(density) { offset.y.toDp() }
                val resolvedProfile = proximityEntry.profileId?.let { peerProfiles[it] }
                Box(
                    modifier = Modifier
                        .padding(start = xDp - 28.dp, top = yDp - 28.dp)
                        .then(
                            if (proximityEntry.profileId != null)
                                Modifier.clickable { selectedPeer = proximityEntry }
                            else Modifier
                        )
                ) {
                    PeerMarker(
                        distanceMeters = proximityEntry.distanceMeters,
                        displayName = resolvedProfile?.displayName,
                        avatarConfig = resolvedProfile?.avatarConfig
                    )
                }
            }
        }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                modifier = Modifier.fillMaxSize().padding(0.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                DensityBanner(discoveredCount)
                Row {
                    IconButton(onClick = {
                        isInvisible = !isInvisible
                        proximity.setDiscoverable(!isInvisible)
                        currentUserId?.let { safety.setInvisible(isInvisible, it) }
                        AnalyticsManager.track("invisible_toggled")
                    }) {
                        Icon(
                            imageVector = if (isInvisible) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                            contentDescription = "Modo invisible",
                            tint = Color.White
                        )
                    }
                    IconButton(onClick = { showReportSheet = true }) {
                        Icon(Icons.Filled.Warning, contentDescription = "Denunciar", tint = Color.White)
                    }
                }
            }
            EventModeBanner(viewModel = eventMode, onOpenProfile = onOpenProfile)
            Spacer(modifier = Modifier)
        }

        if (statusMessage != null) {
            StatusOverlay(statusMessage!!)
        }

        // Hallazgo real, corregido esta pasada (bug de seguridad genuino):
        // este botón usaba currentUserId como "reportedId" -- dos toques
        // bastaban para denunciarse o BLOQUEARSE a uno mismo por
        // accidente. El toque a un marcador de peer real (más abajo, con
        // SendSocialSheet.onReportOrBlock) ya es el camino correcto con
        // un target real; este botón genérico ahora solo explica eso, sin
        // abrir un ReportSheet sin sentido.
        if (showReportSheet) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { showReportSheet = false },
                title = { Text("Denunciar o bloquear") },
                text = { Text("Toca a la persona que quieras denunciar o bloquear en la cámara para hacerlo con su perfil real.") },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = { showReportSheet = false }) { Text("Entendido") }
                }
            )
        }

        // Antes ningún marcador de peer era tocable en ninguna plataforma —
        // era imposible enviar un social de verdad desde la cámara, el
        // corazón del producto. Ver aviso de honestidad/seguridad sobre el
        // profileId real intercambiado por Nearby en SocialProximity.kt.
        selectedPeer?.profileId?.let { targetProfileId ->
            // Antes "Denunciar"/"Bloquear" solo eran alcanzables desde el FAB
            // global de la cámara, que usa currentUserId como objetivo — es
            // decir, denunciarse/bloquearse a uno mismo. Aquí sí se conoce
            // el profileId real del peer tocado, así que es el sitio
            // correcto para ofrecer estas dos acciones sobre esa persona.
            var showTargetReport by remember { mutableStateOf(false) }
            SendSocialSheet(
                onSend = {
                    currentUserId?.let { me ->
                        scope.launch { socialLinks.sendSocial(me, targetProfileId) }
                        AnalyticsManager.track("social_sent")
                    }
                    selectedPeer = null
                },
                onReportOrBlock = { showTargetReport = true },
                onDismiss = { selectedPeer = null }
            )
            if (showTargetReport && currentUserId != null) {
                ReportSheet(
                    reporterId = currentUserId,
                    reportedId = targetProfileId,
                    onDismiss = { showTargetReport = false; selectedPeer = null }
                )
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SendSocialSheet(onSend: () -> Unit, onReportOrBlock: () -> Unit, onDismiss: () -> Unit) {
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(modifier = Modifier.padding(24.dp)) {
            Text("Persona detectada cerca", style = MaterialTheme.typography.titleMedium)
            androidx.compose.material3.Button(onClick = onSend, modifier = Modifier.padding(top = 12.dp)) {
                Text("Enviar social")
            }
            androidx.compose.material3.OutlinedButton(onClick = onReportOrBlock, modifier = Modifier.padding(top = 8.dp)) {
                Text("Denunciar o bloquear")
            }
        }
    }
}

@Composable
private fun DensityBanner(count: Int) {
    val text = when {
        count == 0 -> "Buscando personas cerca de ti…"
        count == 1 -> "1 persona cerca de ti ahora"
        else -> "$count personas cerca de ti ahora"
    }
    Row(
        modifier = Modifier
            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(Icons.Filled.Group, contentDescription = null, tint = Color.White)
        Text(text, color = Color.White, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
private fun StatusOverlay(message: String) {
    Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = Color.Yellow)
            Text(message, color = Color.White, textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
        }
    }
}
