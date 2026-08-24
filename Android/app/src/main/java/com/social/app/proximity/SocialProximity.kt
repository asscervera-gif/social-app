package com.social.app.proximity

import android.content.Context
import android.os.Build
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbClientSessionScope
import androidx.core.uwb.UwbComplexChannel
import androidx.core.uwb.UwbControleeSessionScope
import androidx.core.uwb.UwbControllerSessionScope
import androidx.core.uwb.UwbDevice
import androidx.core.uwb.UwbManager
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.atan2

/**
 * Motor de proximidad Android — equivalente a SocialProximity.swift (iOS).
 *
 * Usa Nearby Connections únicamente como canal de arranque para intercambiar
 * direcciones UWB (igual que MultipeerConnectivity en iOS: la medición
 * visible viene siempre del ranging UWB, no de Nearby). Aplica las mismas
 * protecciones que la versión iOS, para que ambas plataformas se sientan
 * igual de fiables:
 *   1. Filtro de paso bajo sobre distancia/ángulo (jitter de UWB crudo).
 *   2. Vigilancia de datos obsoletos (watchdog cada 1s).
 *   3. Límite de sesiones UWB activas simultáneas (batería en eventos).
 *   4. Reintento automático si el ranging se invalida sin perder Nearby.
 *   5. Filtrado de usuarios bloqueados a nivel de motor.
 *   6. Rate-limit de reconexión por peer.
 *
 * Rol controller/controlee: CONFIG_UNICAST_DS_TWR de Jetpack UWB exige que
 * de cada dos dispositivos, uno sea controller y el otro controlee — antes
 * ambos lados llamaban a `controleeSessionScope()`, lo que en hardware real
 * nunca habría llegado a medir nada. El rol se decide de forma determinista
 * comparando los UUID de ambos peers (el menor es controller), así que
 * ambos lados llegan a la misma conclusión sin necesidad de negociarlo.
 * El controller obtiene su `UwbComplexChannel` (canal + índice de preámbulo)
 * directamente de `UwbControllerSessionScope.uwbComplexChannel` — lo asigna
 * el propio framework, no hay que inventarlo — y se lo envía al controlee
 * por Nearby Connections antes de que este arranque el ranging. También se
 * deriva un `sessionId` compartido a partir de ambos UUID (antes cada lado
 * calculaba el hash del UUID *ajeno*, así que nunca coincidía entre los dos
 * extremos). Verificado contra el bytecode real de androidx.core.uwb
 * 1.0.0-alpha08, no contra documentación.
 *
 * Requiere: Android 12+ (API 31) con chip UWB. Sin chip, degrada con un
 * mensaje claro (statusMessage), igual que en iOS con `isUWBSupported`.
 */
class SocialProximity(
    private val context: Context,
    private val localPeerId: SocialPeerId = SocialPeerId(UUID.randomUUID())
) {
    private val scope = CoroutineScope(SupervisorJob())

    private val _peers = MutableStateFlow<Map<SocialPeerId, PeerProximity>>(emptyMap())
    val peers: StateFlow<Map<SocialPeerId, PeerProximity>> = _peers.asStateFlow()

    private val _discoveredCount = MutableStateFlow(0)
    val discoveredCount: StateFlow<Int> = _discoveredCount.asStateFlow()

    /** false en cuanto se comprueba que el dispositivo no llega a Android 12
     * (API 31, mínimo real de androidx.core.uwb) o no reporta el chip UWB —
     * ver `isApiSupported` y `start()`. La app entera no depende de esto:
     * solo la pestaña Social pierde la detección física, el resto funciona
     * igual en cualquier Android 8+ (minSdk 26). */
    private val isApiSupported = Build.VERSION.SDK_INT >= 31
    private val _isUwbSupported = MutableStateFlow(isApiSupported)
    val isUwbSupported: StateFlow<Boolean> = _isUwbSupported.asStateFlow()

    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    /** IDs bloqueados (tabla `blocks`); ver security_checklist.md #4. */
    var blockedPeerIds: Set<UUID> = emptySet()
        set(value) {
            val newlyBlocked = value - field
            field = value
            if (newlyBlocked.isNotEmpty()) {
                newlyBlocked.forEach { blockedId ->
                    activeSessions.keys.filter { it.id == blockedId }.forEach(::teardownSession)
                }
                pendingEndpoints.removeAll { newlyBlocked.contains(it.peerId.id) }
            }
        }

    private val uwbManager by lazy { UwbManager.createInstance(context) }
    private val connectionsClient: ConnectionsClient by lazy { Nearby.getConnectionsClient(context) }

    private val serviceId = "com.social.app.uwb"
    private val strategy = Strategy.P2P_CLUSTER // permite N conexiones simultáneas, no solo 1 a 1

    private data class ActiveSession(val job: Job)

    private val activeSessions = ConcurrentHashMap<SocialPeerId, ActiveSession>()

    /** Scope UWB ya creado para este peer (controller o controlee, ver nota
     * de rol arriba) — se crea una única vez por conexión y se reutiliza,
     * en vez de recrearlo (como ocurría antes al llamar a
     * `controleeSessionScope()` dos veces por la misma conexión). */
    private data class PeerSession(
        val isController: Boolean,
        val controllerScope: UwbControllerSessionScope? = null,
        val controleeScope: UwbControleeSessionScope? = null
    ) {
        val clientScope: UwbClientSessionScope get() = controllerScope ?: controleeScope!!
    }
    private val peerSessions = ConcurrentHashMap<SocialPeerId, PeerSession>()

    /** (peerId, endpointId, dirección UWB en CSV, canal si somos controlee)
     * — se cachea para que promoteNextPendingIfNeeded() pueda arrancar el
     * ranging real al liberarse un hueco, sin depender de que vuelva a
     * llegar el payload. */
    private data class PendingPeer(
        val peerId: SocialPeerId,
        val endpointId: String,
        val addressCsv: String,
        val channel: Int?,
        val preambleIndex: Int?,
        val remoteProfileId: String?
    )
    private val pendingEndpoints = mutableListOf<PendingPeer>()
    private val allDiscoveredIds = mutableSetOf<SocialPeerId>()
    private val lastUpdateAt = ConcurrentHashMap<SocialPeerId, Long>()
    private val invalidationRetries = ConcurrentHashMap<SocialPeerId, Int>()
    private val inviteAttempts = ConcurrentHashMap<String, MutableList<Long>>()

    private val maxActiveSessions = 8
    private val maxInvalidationRetries = 3
    private val staleTimeoutMs = 3_000L
    private val smoothingFactor = 0.35f
    private val maxInvitesPerWindow = 5
    private val inviteWindowMs = 60_000L

    private var watchdogJob: Job? = null

    fun start() {
        if (!isApiSupported) {
            _statusMessage.value = "Este dispositivo tiene una versión de Android anterior a la 12, así que no puede usar la detección de proximidad de SOCIAL. El resto de la app funciona igual; solo la pestaña Social queda desactivada."
            return
        }
        _statusMessage.value = null
        connectionsClient.startAdvertising(
            localPeerId.id.toString(),
            serviceId,
            connectionLifecycleCallback,
            com.google.android.gms.nearby.connection.AdvertisingOptions.Builder().setStrategy(strategy).build()
        )
        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            com.google.android.gms.nearby.connection.DiscoveryOptions.Builder().setStrategy(strategy).build()
        )
        startWatchdog()
    }

    /** Modo invisible real: deja de anunciarse, no solo de mostrarse en la UI. */
    fun setDiscoverable(discoverable: Boolean) {
        if (discoverable) {
            connectionsClient.startAdvertising(
                localPeerId.id.toString(), serviceId, connectionLifecycleCallback,
                com.google.android.gms.nearby.connection.AdvertisingOptions.Builder().setStrategy(strategy).build()
            )
        } else {
            connectionsClient.stopAdvertising()
        }
    }

    fun stop() {
        watchdogJob?.cancel()
        connectionsClient.stopAdvertising()
        connectionsClient.stopDiscovery()
        connectionsClient.stopAllEndpoints()
        activeSessions.keys.toList().forEach(::teardownSession)
        pendingEndpoints.clear()
        allDiscoveredIds.clear()
        lastUpdateAt.clear()
        invalidationRetries.clear()
        _peers.value = emptyMap()
        _discoveredCount.value = 0
    }

    private fun startWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            while (true) {
                kotlinx.coroutines.delay(1_000)
                checkForStalePeers()
            }
        }
    }

    private fun checkForStalePeers() {
        val now = System.currentTimeMillis()
        val updated = _peers.value.mapValues { (id, proximity) ->
            val lastSeen = lastUpdateAt[id] ?: return@mapValues proximity
            if (now - lastSeen > staleTimeoutMs) proximity.copy(isActive = false, isInFrame = false) else proximity
        }
        _peers.value = updated
    }

    // -------- Nearby Connections: canal de arranque --------

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            // info.endpointName es el UUID que el otro lado anunció — se
            // captura aquí también porque este callback es el único que ve
            // el lado que hace de advertiser (nunca pasa por onEndpointFound).
            runCatching { UUID.fromString(info.endpointName) }.getOrNull()?.let {
                endpointToPeerId[endpointId] = SocialPeerId(it)
            }
            if (!shouldInvite(endpointId)) {
                connectionsClient.rejectConnection(endpointId)
                return
            }
            connectionsClient.acceptConnection(endpointId, payloadCallback)
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.isSuccess) {
                val remotePeerId = endpointToPeerId[endpointId] ?: return
                // Rol determinista: el UUID menor actúa de controller UWB.
                // Ambos lados llegan a la misma conclusión sin negociarlo.
                val isController = localPeerId.id < remotePeerId.id
                startUwbAndSendAddress(endpointId, remotePeerId, isController)
            }
        }

        override fun onDisconnected(endpointId: String) {
            removePeerForEndpoint(endpointId)
        }
    }

    private val endpointDiscoveryCallback = object : com.google.android.gms.nearby.connection.EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: com.google.android.gms.nearby.connection.DiscoveredEndpointInfo) {
            // info.endpointName es el UUID que el otro lado anuncia (ver
            // startAdvertising más abajo) — se conoce el peerId remoto ya
            // aquí, antes de intercambiar nada por UWB.
            runCatching { UUID.fromString(info.endpointName) }.getOrNull()?.let {
                endpointToPeerId[endpointId] = SocialPeerId(it)
            }
            connectionsClient.requestConnection(localPeerId.id.toString(), endpointId, connectionLifecycleCallback)
        }

        override fun onEndpointLost(endpointId: String) {
            removePeerForEndpoint(endpointId)
        }
    }

    private val endpointToPeerId = ConcurrentHashMap<String, SocialPeerId>()

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            val bytes = payload.asBytes() ?: return
            val message = String(bytes, StandardCharsets.UTF_8)
            // Protocolo con tag explícito para no depender de contar campos:
            // "A|peerId|address|profileId" (controlee) o
            // "C|peerId|address|canal|preámbulo|profileId" (controller).
            // profileId es el id REAL de perfil en Supabase del remitente
            // (autenticado en su sesión) — antes solo se intercambiaba el
            // peerId efímero de esta clase, así que no había forma de saber
            // a qué perfil real enviar un social al tocar un marcador.
            //
            // Aviso de honestidad/seguridad: el servidor sigue validando
            // `requester_id = auth.uid()` en la tabla `socials` (RLS), así
            // que nadie puede enviar un social en nombre de otro. El único
            // riesgo real es que un cliente modificado mienta sobre SU
            // PROPIO profileId, lo que dirigiría un social hacia la persona
            // equivocada (no un fallo de account-takeover, sí de integridad
            // social) — mismo nivel de confianza que ya existe en el resto
            // del intercambio Nearby (la dirección UWB tampoco se firma).
            val parts = message.split("|")
            if (parts.size < 2) return
            when (parts[0]) {
                "A" -> {
                    if (parts.size < 4) return
                    val remotePeerId = SocialPeerId(UUID.fromString(parts[1]))
                    endpointToPeerId[endpointId] = remotePeerId
                    startRangingWithRemoteInfo(remotePeerId, endpointId, parts[2], null, null, parts[3])
                }
                "C" -> {
                    if (parts.size < 6) return
                    val remotePeerId = SocialPeerId(UUID.fromString(parts[1]))
                    endpointToPeerId[endpointId] = remotePeerId
                    startRangingWithRemoteInfo(remotePeerId, endpointId, parts[2], parts[3].toIntOrNull(), parts[4].toIntOrNull(), parts[5])
                }
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }

    private fun startUwbAndSendAddress(endpointId: String, remotePeerId: SocialPeerId, isController: Boolean) {
        scope.launch {
            try {
                val myProfileId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: ""
                if (isController) {
                    val controllerScope = uwbManager.controllerSessionScope()
                    peerSessions[remotePeerId] = PeerSession(isController = true, controllerScope = controllerScope)
                    val addr = controllerScope.localAddress.address.joinToString(",")
                    val ch = controllerScope.uwbComplexChannel
                    val message = "C|${localPeerId.id}|$addr|${ch.channel}|${ch.preambleIndex}|$myProfileId"
                    connectionsClient.sendPayload(endpointId, Payload.fromBytes(message.toByteArray(StandardCharsets.UTF_8)))
                } else {
                    val controleeScope = uwbManager.controleeSessionScope()
                    peerSessions[remotePeerId] = PeerSession(isController = false, controleeScope = controleeScope)
                    val addr = controleeScope.localAddress.address.joinToString(",")
                    val message = "A|${localPeerId.id}|$addr|$myProfileId"
                    connectionsClient.sendPayload(endpointId, Payload.fromBytes(message.toByteArray(StandardCharsets.UTF_8)))
                }
            } catch (e: Exception) {
                _statusMessage.value = "Este dispositivo no tiene chip UWB compatible. SOCIAL necesita un Android 12+ con banda ultraancha."
                _isUwbSupported.value = false
            }
        }
    }

    // -------- Arranque de ranging UWB tras el intercambio de direcciones --------

    private fun startRangingWithRemoteInfo(peerId: SocialPeerId, endpointId: String, addressCsv: String, channel: Int?, preambleIndex: Int?, remoteProfileId: String?) {
        if (blockedPeerIds.contains(peerId.id)) return // ver security_checklist.md #4

        allDiscoveredIds.add(peerId)
        _discoveredCount.value = allDiscoveredIds.size

        if (activeSessions.size >= maxActiveSessions) {
            pendingEndpoints.add(PendingPeer(peerId, endpointId, addressCsv, channel, preambleIndex, remoteProfileId))
            return
        }
        activateRanging(peerId, endpointId, addressCsv, channel, preambleIndex, remoteProfileId)
    }

    /** Sesión compartida por ambos UUID (orden fijo) — antes cada lado
     * calculaba el hash del UUID *del otro*, así que controller y controlee
     * nunca coincidían en sessionId y el ranging no podía enlazar. */
    private fun sharedSessionId(remotePeerId: SocialPeerId): Int {
        val (low, high) = if (localPeerId.id < remotePeerId.id) localPeerId.id to remotePeerId.id else remotePeerId.id to localPeerId.id
        return "$low:$high".hashCode()
    }

    private fun activateRanging(peerId: SocialPeerId, endpointId: String, addressCsv: String, channel: Int?, preambleIndex: Int?, remoteProfileId: String?) {
        val peerSession = peerSessions[peerId]
        if (peerSession == null) {
            handleRangingFailure(peerId, endpointId, addressCsv, channel, preambleIndex, remoteProfileId)
            return
        }
        val job = scope.launch {
            try {
                val remoteAddress = UwbAddress(addressCsv.split(",").map { it.toByte() }.toByteArray())
                // UwbDevice.createForAddress(String) espera la dirección como texto;
                // ya tenemos un UwbAddress construido, así que se usa el constructor
                // directo UwbDevice(UwbAddress) en vez de esa factory (verificado
                // contra el bytecode real de androidx.core.uwb 1.0.0-alpha08).
                val remoteDevice = UwbDevice(remoteAddress)

                // El controller lee su propio canal ya asignado por el
                // framework; el controlee usa el que le llegó del controller
                // por Nearby (ver payloadCallback). Sin canal real no hay
                // fallback honesto: si falta, se trata como fallo de ranging.
                val complexChannel = if (peerSession.isController) {
                    peerSession.controllerScope!!.uwbComplexChannel
                } else if (channel != null && preambleIndex != null) {
                    UwbComplexChannel(channel, preambleIndex)
                } else {
                    null
                } ?: throw IllegalStateException("Canal UWB no disponible todavía para $peerId")

                val params = RangingParameters(
                    uwbConfigType = RangingParameters.CONFIG_UNICAST_DS_TWR,
                    sessionId = sharedSessionId(peerId),
                    subSessionId = 0,
                    sessionKeyInfo = null,
                    subSessionKeyInfo = null,
                    complexChannel = complexChannel,
                    peerDevices = listOf(remoteDevice),
                    updateRateType = RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC
                )

                peerSession.clientScope.prepareSession(params).onEach { result ->
                    handleRangingResult(peerId, result)
                }.launchIn(this)

                _peers.value = _peers.value + (peerId to PeerProximity(peerId = peerId, isActive = true, profileId = remoteProfileId))
                lastUpdateAt[peerId] = System.currentTimeMillis()
            } catch (e: Exception) {
                handleRangingFailure(peerId, endpointId, addressCsv, channel, preambleIndex, remoteProfileId)
            }
        }
        activeSessions[peerId] = ActiveSession(job = job)
    }

    private fun handleRangingResult(peerId: SocialPeerId, result: RangingResult) {
        if (result !is RangingResult.RangingResultPosition) return
        val position = result.position
        val distance = position.distance?.value
        val azimuth = position.azimuth?.value // grados; equivalente al object.direction de iOS

        _peers.value = _peers.value.toMutableMap().apply {
            val previous = this[peerId] ?: PeerProximity(peerId = peerId)
            val smoothedDistance = distance?.let { smoothed(previous.distanceMeters, it) }
            val smoothedAngle = azimuth?.let { smoothed(previous.horizontalAngleRad, Math.toRadians(it.toDouble()).toFloat()) }
            this[peerId] = previous.copy(
                distanceMeters = smoothedDistance ?: previous.distanceMeters,
                horizontalAngleRad = smoothedAngle ?: previous.horizontalAngleRad,
                isInFrame = azimuth != null,
                isActive = true
            )
        }
        lastUpdateAt[peerId] = System.currentTimeMillis()
        invalidationRetries[peerId] = 0
    }

    private fun handleRangingFailure(peerId: SocialPeerId, endpointId: String, addressCsv: String, channel: Int?, preambleIndex: Int?, remoteProfileId: String?) {
        activeSessions.remove(peerId)
        val retries = invalidationRetries.getOrDefault(peerId, 0)
        if (allDiscoveredIds.contains(peerId) && retries < maxInvalidationRetries) {
            invalidationRetries[peerId] = retries + 1
            activateRanging(peerId, endpointId, addressCsv, channel, preambleIndex, remoteProfileId)
        } else {
            _peers.value = _peers.value - peerId
            invalidationRetries.remove(peerId)
            peerSessions.remove(peerId)
            promoteNextPendingIfNeeded()
        }
    }

    private fun teardownSession(peerId: SocialPeerId) {
        activeSessions.remove(peerId)?.job?.cancel()
        peerSessions.remove(peerId)
        _peers.value = _peers.value - peerId
        lastUpdateAt.remove(peerId)
        invalidationRetries.remove(peerId)
    }

    private fun removePeerForEndpoint(endpointId: String) {
        val peerId = endpointToPeerId.remove(endpointId) ?: return
        teardownSession(peerId)
        pendingEndpoints.removeAll { it.peerId == peerId }
        allDiscoveredIds.remove(peerId)
        _discoveredCount.value = allDiscoveredIds.size
        promoteNextPendingIfNeeded()
    }

    /// Promueve al siguiente peer en cola (FIFO — misma aproximación honesta
    /// que en iOS: no se conoce la distancia de nadie en cola hasta medirlo,
    /// así que no hay forma real de priorizar "el más cercano" sin ya haber
    /// ocupado el hueco). La dirección UWB queda cacheada en `PendingPeer`
    /// desde que se recibió, así que esto sí reactiva el ranging de verdad.
    private fun promoteNextPendingIfNeeded() {
        if (activeSessions.size >= maxActiveSessions || pendingEndpoints.isEmpty()) return
        val next = pendingEndpoints.removeAt(0)
        activateRanging(next.peerId, next.endpointId, next.addressCsv, next.channel, next.preambleIndex, next.remoteProfileId)
    }

    private fun smoothed(previous: Float?, new: Float): Float {
        if (previous == null) return new
        return previous + smoothingFactor * (new - previous)
    }

    private fun shouldInvite(endpointId: String): Boolean {
        val now = System.currentTimeMillis()
        val attempts = inviteAttempts.getOrPut(endpointId) { mutableListOf() }
        attempts.removeAll { now - it > inviteWindowMs }
        if (attempts.size >= maxInvitesPerWindow) return false
        attempts.add(now)
        return true
    }
}
