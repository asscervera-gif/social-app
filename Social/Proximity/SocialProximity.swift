//
//  SocialProximity.swift
//  Social
//
//  Motor de proximidad. Usa MultipeerConnectivity únicamente como canal de
//  arranque para intercambiar NIDiscoveryToken (paso obligatorio de Apple:
//  NearbyInteraction no puede descubrir peers por sí solo). Toda la
//  experiencia visible (distancia, ángulo, "en cámara") viene de UWB
//  a través de NISession.
//
//  Esta es la función diferencial de SOCIAL frente a cualquier red social
//  basada en feed: la fiabilidad de estas mediciones es lo que hace o
//  deshace el producto. Cosas que se cuidan aquí más allá del ejemplo mínimo
//  de la Fase 1:
//    1. Filtrado de señal (paso bajo) — el UWB crudo tiene jitter perceptible
//       en distancia/ángulo; sin suavizado el marcador tiembla en pantalla.
//    2. Vigilancia de datos obsoletos — si NISession deja de emitir
//       actualizaciones sin invalidar la sesión (puede pasar, p.ej. el peer
//       se aleja del alcance UWB sin perder Multipeer), hay que detectarlo
//       igualmente y marcar al peer como inactivo.
//    3. Límite de sesiones NI simultáneas — una `NISession` por persona tiene
//       coste real de CPU/batería. En un evento con decenas de personas
//       (Fase 7, Modo Evento) arrancar una sesión por cada una agotaría la
//       batería en minutos. `maxActiveNISessions` limita cuántas se miden
//       con precisión a la vez; el resto queda en cola y solo cuenta para el
//       contador de densidad ("37 personas cerca de ti"), que se alimenta de
//       *todos* los peers descubiertos por Multipeer, no solo de los medidos.
//
//  Requiere: dispositivo con chip U1/U2 (iPhone 11 o superior).
//

import Foundation
import Combine
import MultipeerConnectivity
import NearbyInteraction

/// Motor de descubrimiento y medición de proximidad para SOCIAL.
final class SocialProximity: NSObject, ObservableObject {

    // MARK: - Estado publicado

    /// Proximidad de cada peer detectado, indexada por su identificador estable.
    /// Solo contiene a quienes están dentro del límite de sesiones NI activas
    /// (ver `maxActiveNISessions`) — para el total real de gente cerca, usa
    /// `discoveredCount`, que cuenta también a los que están en cola.
    @Published private(set) var peers: [SocialPeerID: PeerProximity] = [:]

    /// Total de personas descubiertas por Multipeer, medidas por UWB o no.
    /// Es la cifra correcta para el contador de densidad: nunca debe bajar
    /// solo porque el límite de sesiones NI activas esté lleno.
    @Published private(set) var discoveredCount: Int = 0

    /// true si el dispositivo actual soporta NearbyInteraction (chip U1/U2).
    @Published private(set) var isUWBSupported: Bool = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement

    /// Mensaje de error legible para mostrar en pantalla, p. ej. si no hay soporte UWB.
    @Published private(set) var statusMessage: String?

    /// IDs de usuarios bloqueados (tabla `blocks`, Fase 7). Un usuario bloqueado
    /// nunca debe aparecer como marcador, aunque esté físicamente cerca —
    /// ver security_checklist.md, sección 4. Inyectado desde fuera (se
    /// sincroniza con Supabase al iniciar sesión y al bloquear a alguien).
    ///
    /// El didSet cubre el caso en que alguien bloquea a un peer que YA está
    /// siendo medido en ese momento: sin esto, el filtrado solo actuaba al
    /// arrancar una sesión nueva (startNISession) y el marcador bloqueado
    /// seguía visible hasta la siguiente reconexión — justo el escenario que
    /// más importa (bloquear a alguien que tienes delante ahora mismo).
    var blockedPeerIDs: Set<UUID> = [] {
        didSet {
            let newlyBlocked = blockedPeerIDs.subtracting(oldValue)
            guard !newlyBlocked.isEmpty else { return }
            for socialID in peers.keys where newlyBlocked.contains(socialID.id) {
                niSessions[socialID]?.invalidate()
                niSessions.removeValue(forKey: socialID)
                peers.removeValue(forKey: socialID)
                lastUpdateAt.removeValue(forKey: socialID)
            }
            pendingTokens.removeAll { newlyBlocked.contains($0.0.id) }
            promoteNextPendingIfNeeded()
        }
    }

    // MARK: - Ajuste de señal

    /// Coeficiente del filtro de paso bajo aplicado a distancia y ángulo.
    /// Más bajo = más suave pero más lento en seguir el movimiento real;
    /// 0.35 es un punto medio razonable para caminar a paso normal.
    private let smoothingFactor: Double = 0.35

    /// Si no llega una actualización de un peer en este intervalo, se marca
    /// inactivo aunque NISession no haya emitido `didRemove`/`didInvalidate`.
    private let staleTimeout: TimeInterval = 3.0

    private var lastUpdateAt: [SocialPeerID: Date] = [:]
    private var watchdogTimer: Timer?

    // MARK: - Multipeer (solo intercambio de tokens)

    private let serviceType = "social-uwb"
    private let localPeerID: SocialPeerID
    private let mcPeerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    // MARK: - NearbyInteraction

    /// Una sesión NI por cada peer remoto: NearbyInteraction mide un peer a la vez por sesión.
    private var niSessions: [SocialPeerID: NISession] = [:]

    /// Asocia cada MCPeerID con nuestro identificador social estable.
    private var mcToSocialID: [MCPeerID: SocialPeerID] = [:]

    /// Cuántas NISession se permiten a la vez. Por encima de esto, los nuevos
    /// peers descubiertos entran en `pendingTokens` y se promueven en cuanto
    /// se libera un hueco (alguien sale de rango, se bloquea, etc.).
    private let maxActiveNISessions = 8
    private var pendingTokens: [(SocialPeerID, NIDiscoveryToken)] = []
    private var allDiscoveredIDs: Set<SocialPeerID> = []

    /// Último token conocido de cada peer, para poder reintentar la sesión NI
    /// si se invalida (error, timeout) mientras la conexión Multipeer sigue
    /// viva — sin esto, un fallo de NI dejaba a la persona "perdida" hasta
    /// que se reconectara físicamente, incluso estando delante todo el rato.
    private var lastTokens: [SocialPeerID: NIDiscoveryToken] = [:]
    private var invalidationRetries: [SocialPeerID: Int] = [:]
    private let maxInvalidationRetries = 3

    /// profile_id real de cada peer, recibido en su DiscoveryTokenMessage —
    /// ver aviso de seguridad en PeerToken.swift. Se guarda aparte (en vez
    /// de threading por todas las firmas como en el motor Android) porque
    /// aquí el token y el profileID llegan siempre juntos en el mismo
    /// mensaje, antes de que exista ninguna PeerProximity para ese peer.
    private var remoteProfileIDs: [SocialPeerID: String] = [:]

    /// El profile_id real del usuario autenticado en ESTE dispositivo — se
    /// asigna desde SocialCameraView.swift tras el login, porque
    /// SupabaseManager.auth.session es async y sendOwnToken() no lo es.
    var localProfileID: String?

    // MARK: - Init

    init(localPeerID: SocialPeerID = SocialPeerID(id: UUID())) {
        self.localPeerID = localPeerID
        self.mcPeerID = MCPeerID(displayName: localPeerID.id.uuidString.prefix(8).description)
        super.init()

        guard isUWBSupported else {
            statusMessage = "Este dispositivo no tiene chip de banda ultraancha (U1/U2) y no puede usar la detección de proximidad de SOCIAL. Se requiere iPhone 11 o superior."
            return
        }

        session = MCSession(peer: mcPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(peer: mcPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self

        browser = MCNearbyServiceBrowser(peer: mcPeerID, serviceType: serviceType)
        browser.delegate = self
    }

    // MARK: - Control

    /// Empieza a anunciarse y buscar peers cercanos por Multipeer (canal de arranque).
    func start() {
        guard isUWBSupported else { return }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startWatchdog()
    }

    /// Modo invisible real (no solo de UI): al desactivar el anuncio Multipeer,
    /// nadie más puede iniciar el intercambio de token con este dispositivo,
    /// así que no se le puede medir por UWB — ver security_checklist.md #1.
    /// Se sigue pudiendo ver a los demás (solo deja de ser visible uno mismo).
    func setDiscoverable(_ discoverable: Bool) {
        guard isUWBSupported else { return }
        if discoverable {
            advertiser.startAdvertisingPeer()
        } else {
            advertiser.stopAdvertisingPeer()
        }
    }

    func stop() {
        guard isUWBSupported else { return }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        niSessions.values.forEach { $0.invalidate() }
        niSessions.removeAll()
        session.disconnect()
        peers.removeAll()
        lastUpdateAt.removeAll()
        pendingTokens.removeAll()
        allDiscoveredIDs.removeAll()
        discoveredCount = 0
        lastTokens.removeAll()
        invalidationRetries.removeAll()
    }

    /// Comprueba periódicamente si algún peer dejó de emitir actualizaciones
    /// sin que NISession lo notificara explícitamente (ver cabecera del archivo).
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForStalePeers()
        }
    }

    private func checkForStalePeers() {
        let now = Date()
        for (socialID, lastSeen) in lastUpdateAt {
            guard now.timeIntervalSince(lastSeen) > staleTimeout else { continue }
            peers[socialID]?.isActive = false
            peers[socialID]?.isInFrame = false
        }
    }

    // MARK: - Arranque de sesión NI tras el intercambio de tokens

    /// Se llama cuando llega el token del peer remoto por Multipeer.
    /// A partir de aquí arranca la sesión UWB real con ese peer, o lo pone en
    /// cola si ya se alcanzó `maxActiveNISessions` (ver cabecera del archivo).
    private func startNISession(with socialPeerID: SocialPeerID, remoteToken: NIDiscoveryToken) {
        guard !blockedPeerIDs.contains(socialPeerID.id) else {
            // Un usuario bloqueado nunca debe medirse ni mostrarse, aunque
            // haya completado el intercambio de tokens por Multipeer.
            return
        }

        allDiscoveredIDs.insert(socialPeerID)
        discoveredCount = allDiscoveredIDs.count

        guard niSessions.count < maxActiveNISessions else {
            pendingTokens.append((socialPeerID, remoteToken))
            return
        }

        activateNISession(socialPeerID: socialPeerID, token: remoteToken)
    }

    private func activateNISession(socialPeerID: SocialPeerID, token: NIDiscoveryToken) {
        let niSession = NISession()
        niSession.delegate = self
        niSessions[socialPeerID] = niSession
        lastTokens[socialPeerID] = token

        let config = NINearbyPeerConfiguration(peerToken: token)
        niSession.run(config)

        peers[socialPeerID] = PeerProximity(
            peerID: socialPeerID,
            distance: nil,
            horizontalAngle: nil,
            isInFrame: false,
            deviceHeading: nil,
            isActive: true,
            profileID: remoteProfileIDs[socialPeerID]
        )
        lastUpdateAt[socialPeerID] = Date()
    }

    /// Se llama cada vez que se libera un hueco de NISession, para dar paso
    /// al siguiente peer en cola (orden de llegada — una prioridad por
    /// distancia real requeriría medir primero, que es justo lo que no se
    /// puede hacer sin ocupar ya el hueco; FIFO es la aproximación honesta).
    private func promoteNextPendingIfNeeded() {
        guard niSessions.count < maxActiveNISessions, !pendingTokens.isEmpty else { return }
        let (socialPeerID, token) = pendingTokens.removeFirst()
        activateNISession(socialPeerID: socialPeerID, token: token)
    }

    /// Envía nuestro propio token de descubrimiento al peer recién conectado por Multipeer.
    private func sendOwnToken(to mcPeer: MCPeerID) {
        // Se crea una NISession "puente" solo para obtener nuestro discoveryToken;
        // la sesión real de medición se arranca en startNISession una vez tengamos
        // también el token remoto.
        let bridgeSession = NISession()
        guard let myToken = bridgeSession.discoveryToken else { return }

        do {
            let message = try DiscoveryTokenMessage(peerID: localPeerID, token: myToken, profileID: localProfileID)
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: [mcPeer], with: .reliable)
        } catch {
            statusMessage = "No se pudo intercambiar el token de proximidad: \(error.localizedDescription)"
        }
    }

    /// Filtro de paso bajo simple: suaviza el valor nuevo hacia el anterior
    /// en vez de sustituirlo de golpe. Reduce el temblor visible del marcador
    /// que produce el ruido normal de una medición UWB cruda.
    private func smoothed(previous: Float?, new: Float) -> Float {
        guard let previous else { return new }
        return previous + Float(smoothingFactor) * (new - previous)
    }

    // MARK: - Rate limit de reconexión Multipeer

    private var inviteAttempts: [MCPeerID: [Date]] = [:]
    private let maxInvitesPerWindow = 5
    private let inviteWindow: TimeInterval = 60

    private func shouldInvite(_ peerID: MCPeerID) -> Bool {
        let now = Date()
        var attempts = (inviteAttempts[peerID] ?? []).filter { now.timeIntervalSince($0) < inviteWindow }
        guard attempts.count < maxInvitesPerWindow else {
            inviteAttempts[peerID] = attempts
            return false
        }
        attempts.append(now)
        inviteAttempts[peerID] = attempts
        return true
    }
}

// MARK: - MCSessionDelegate

extension SocialProximity: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            sendOwnToken(to: peerID)
        } else if state == .notConnected {
            removePeer(forMCPeer: peerID)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let message = try JSONDecoder().decode(DiscoveryTokenMessage.self, from: data)
            let remoteToken = try message.decodedToken()
            mcToSocialID[peerID] = message.peerID
            if let profileID = message.profileID {
                remoteProfileIDs[message.peerID] = profileID
            }
            DispatchQueue.main.async {
                self.startNISession(with: message.peerID, remoteToken: remoteToken)
            }
        } catch {
            statusMessage = "Token de proximidad inválido recibido de un peer."
        }
    }

    // Requeridos por el protocolo, sin uso en SOCIAL (no se transfieren streams ni recursos).
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    private func removePeer(forMCPeer mcPeer: MCPeerID) {
        guard let socialID = mcToSocialID[mcPeer] else { return }
        niSessions[socialID]?.invalidate()
        niSessions.removeValue(forKey: socialID)
        peers.removeValue(forKey: socialID)
        lastUpdateAt.removeValue(forKey: socialID)
        mcToSocialID.removeValue(forKey: mcPeer)
        pendingTokens.removeAll { $0.0 == socialID }
        allDiscoveredIDs.remove(socialID)
        discoveredCount = allDiscoveredIDs.count
        lastTokens.removeValue(forKey: socialID)
        invalidationRetries.removeValue(forKey: socialID)
        promoteNextPendingIfNeeded()
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension SocialProximity: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension SocialProximity: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Invita automáticamente: el descubrimiento visible ya lo controla la UI de SOCIAL,
        // aquí solo se establece el canal de intercambio de tokens. El filtrado de
        // bloqueados ocurre después, en startNISession, en cuanto se conoce el
        // SocialPeerID real (el MCPeerID por sí solo no lo identifica con certeza).
        //
        // Rate-limit de reintentos (security_checklist.md #1): sin esto, alguien
        // podría intentar reconectar de forma agresiva con un MCPeerID concreto
        // para forzar mediciones repetidas de una persona específica.
        guard shouldInvite(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        removePeer(forMCPeer: peerID)
    }
}

// MARK: - NISessionDelegate

extension SocialProximity: NISessionDelegate {

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let socialID = niSessions.first(where: { $0.value === session })?.key else { return }

        for object in nearbyObjects {
            var proximity = peers[socialID] ?? PeerProximity(
                peerID: socialID, distance: nil, horizontalAngle: nil,
                isInFrame: false, deviceHeading: nil, isActive: true,
                profileID: remoteProfileIDs[socialID]
            )

            if let distance = object.distance {
                proximity.distance = smoothed(previous: proximity.distance, new: distance)
            }

            let rawAngle = object.direction.map { atan2($0.x, $0.z) } ?? object.horizontalAngle
            if let rawAngle {
                proximity.horizontalAngle = smoothed(previous: proximity.horizontalAngle, new: rawAngle)
            }

            // object.direction == nil no siempre significa "lejos": puede ser
            // que el teléfono del peer esté en un bolsillo o mal orientado.
            // isInFrame refleja eso con precisión; la UI decide cómo guiar
            // al usuario en ese caso (ver aimingGuideText en SocialCameraView).
            proximity.isInFrame = object.direction != nil
            proximity.isActive = true
            peers[socialID] = proximity
            lastUpdateAt[socialID] = Date()
            invalidationRetries[socialID] = 0 // una medición buena resetea el contador de reintentos
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let socialID = niSessions.first(where: { $0.value === session })?.key else { return }
        peers[socialID]?.isActive = false
        peers[socialID]?.isInFrame = false
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let socialID = niSessions.first(where: { $0.value === session })?.key else { return }
        peers[socialID]?.isActive = false
    }

    func sessionSuspensionEnded(_ session: NISession) {
        // Al reanudar hace falta volver a compartir tokens y correr la config;
        // en SOCIAL el flujo completo se reintenta reconectando por Multipeer.
        // El watchdog (checkForStalePeers) cubre el hueco mientras tanto,
        // marcando al peer como inactivo si no llegan datos nuevos a tiempo.
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let socialID = niSessions.first(where: { $0.value === session })?.key else { return }
        niSessions.removeValue(forKey: socialID)
        lastUpdateAt.removeValue(forKey: socialID)

        // Si el peer sigue conectado por Multipeer (allDiscoveredIDs) y no ha
        // agotado sus reintentos, se reactiva la medición en vez de darlo por
        // perdido — el fallo típico es una invalidación puntual de NI, no una
        // pérdida real de proximidad física.
        let retries = invalidationRetries[socialID, default: 0]
        if let token = lastTokens[socialID], allDiscoveredIDs.contains(socialID), retries < maxInvalidationRetries {
            invalidationRetries[socialID] = retries + 1
            activateNISession(socialPeerID: socialID, token: token)
        } else {
            peers.removeValue(forKey: socialID)
            invalidationRetries.removeValue(forKey: socialID)
            promoteNextPendingIfNeeded()
        }
    }
}
