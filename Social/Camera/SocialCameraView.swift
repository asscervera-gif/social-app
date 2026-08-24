//
//  SocialCameraView.swift
//  Social
//
//  Pantalla de inicio de la app. Muestra la cámara en vivo con los marcadores
//  flotantes de las personas detectadas por UWB, el contador de densidad y
//  una guía de apuntado. Punto de entrada obligatorio según los principios
//  de producto de SOCIAL (nunca abre en un feed).
//

import SwiftUI

struct SocialCameraView: View {

    @StateObject private var proximity = SocialProximity()
    @StateObject private var camera = CameraController()
    @StateObject private var safety = SafetyManager()
    @StateObject private var eventLocation = EventLocationProvider()
    @StateObject private var eventMode = EventModeViewModel()
    @State private var currentUserID: UUID?
    @State private var isInvisible = false
    @State private var selectedPeer: PeerProximity?
    /// Distinto de selectedPeer a propósito: presentar dos .sheet() a la vez
    /// desde la misma vista es frágil en SwiftUI (el segundo puede no
    /// aparecer hasta que el primero se cierre), así que se cierra
    /// selectedPeer ANTES de fijar showReport para forzar la secuencia.
    /// UUID no conforma a Identifiable, así que se guarda aparte de la
    /// condición de presentación en vez de usar .sheet(item:).
    @State private var reportTargetID: UUID?
    @State private var showReport = false
    @StateObject private var socialLinks = SocialLinkManager()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.isAuthorized {
                    CameraPreviewView(session: camera.session)
                        .ignoresSafeArea()
                }

                // Marcadores flotantes posicionados por ángulo/distancia UWB.
                // Antes ningún marcador era tocable en ninguna plataforma —
                // era imposible enviar un social de verdad desde la cámara.
                // Solo se puede tocar si se conoce el profileID real del
                // peer (ver aviso de seguridad en PeerToken.swift).
                ForEach(Array(proximity.peers.values)) { peerProximity in
                    if let position = peerProximity.markerPosition(in: geo.size) {
                        PeerMarkerView(proximity: peerProximity)
                            .scaleEffect(position.scale)
                            .position(x: position.x, y: position.y)
                            .onTapGesture {
                                if peerProximity.profileID != nil {
                                    selectedPeer = peerProximity
                                }
                            }
                    }
                }

                VStack {
                    HStack {
                        densityBanner
                        Spacer()
                        invisibleToggle
                    }
                    if eventMode.activeEvent != nil {
                        EventModeView(viewModel: eventMode)
                    }
                    Spacer()
                    aimingGuide
                }
                .padding(.top, geo.safeAreaInsets.top + 8)
                .padding(.bottom, 40)
                .padding(.horizontal, 12)

                if !proximity.isUWBSupported || camera.statusMessage != nil || proximity.statusMessage != nil {
                    statusOverlay
                }
            }
        }
        .onAppear {
            camera.checkPermissionsAndStart()
            eventLocation.start()
            Task {
                currentUserID = try? await SupabaseManager.shared.client.auth.session.user.id
                proximity.localProfileID = currentUserID?.uuidString
                await loadBlockedPeers()
            }
            proximity.start()
        }
        .onDisappear {
            camera.stop()
            eventLocation.stop()
            proximity.stop()
        }
        // onReceive en vez de onChange(of:): CLLocation no confirma Equatable,
        // así que se suscribe directamente al publisher de Combine en vez de
        // depender de comparación de igualdad (que no he podido verificar sin
        // compilador real disponible para iOS en este entorno).
        .onReceive(eventLocation.$location.compactMap { $0 }) { newLocation in
            Task { await eventMode.checkForNearbyEvent(location: newLocation) }
        }
        .sheet(item: $selectedPeer) { peer in
            // Antes "Denunciar"/"Bloquear" solo eran alcanzables desde el
            // FAB global de la cámara, que usa currentUserID como objetivo
            // — es decir, denunciarse/bloquearse a uno mismo. Aquí sí se
            // conoce el profileID real del peer tocado.
            SendSocialSheet(
                onSend: {
                    guard let me = currentUserID, let targetIDString = peer.profileID,
                          let target = UUID(uuidString: targetIDString) else { return }
                    Task { await socialLinks.sendSocial(from: me, to: target) }
                    AnalyticsManager.track("social_sent")
                    selectedPeer = nil
                },
                onReportOrBlock: {
                    reportTargetID = peer.profileID.flatMap(UUID.init)
                    selectedPeer = nil
                    showReport = true
                },
                onDismiss: { selectedPeer = nil }
            )
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $showReport) {
            if let targetID = reportTargetID, let me = currentUserID {
                ReportSheet(userID: me, reportedID: targetID)
                    .environmentObject(safety)
            }
        }
        .statusBarHidden()
    }

    // MARK: - Contador de densidad

    /// Nunca se muestra una pantalla vacía sin explicación: siempre hay un
    /// contador, aunque sea 0, con un texto que oriente al usuario.
    ///
    /// Usa `discoveredCount`, no `peers.count`: en un evento concurrido, solo
    /// un subconjunto de la gente detectada tiene una NISession activa (ver
    /// `maxActiveNISessions` en SocialProximity), pero el contador debe
    /// reflejar a *todo el mundo* cerca, no solo a quienes ya se están midiendo.
    private var densityBanner: some View {
        let count = proximity.discoveredCount
        return HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
            Text(densityText(for: count))
        }
        .font(.subheadline.bold())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }

    private func densityText(for count: Int) -> String {
        switch count {
        case 0:
            return "Buscando personas cerca de ti…"
        case 1:
            return "1 persona cerca de ti ahora"
        default:
            return "\(count) personas cerca de ti ahora"
        }
    }

    // MARK: - Guía de apuntado

    private var aimingGuide: some View {
        Group {
            if let guideText = aimingGuideText {
                Text(guideText)
                    .font(.footnote.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
    }

    /// Texto de guía simple basado en si hay algún peer detectado pero fuera
    /// de encuadre (isInFrame == false pese a tener medición de distancia).
    private var aimingGuideText: String? {
        let outOfFrame = proximity.peers.values.first { $0.isActive && !$0.isInFrame && $0.distance != nil }
        guard let peer = outOfFrame, let angle = peer.horizontalAngle else { return nil }
        if angle < -0.1 {
            return "Gira a la izquierda"
        } else if angle > 0.1 {
            return "Gira a la derecha"
        } else {
            return "Apuntando…"
        }
    }

    // MARK: - Modo invisible

    /// Modo invisible en un toque, siempre accesible desde la pantalla de
    /// inicio (principio de producto no negociable). Actúa en dos capas:
    /// persiste la preferencia en Supabase (afecta a cómo te ven en Match/Home)
    /// y detiene el anuncio Multipeer local (afecta a la detección UWB en vivo).
    private var invisibleToggle: some View {
        Button {
            isInvisible.toggle()
            proximity.setDiscoverable(!isInvisible)
            if let currentUserID {
                Task { await safety.setInvisible(isInvisible, userID: currentUserID) }
            }
            AnalyticsManager.track("invisible_toggled")
        } label: {
            Image(systemName: isInvisible ? "eye.slash.fill" : "eye.slash")
                .padding(10)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
    }

    // MARK: - Bloqueados

    /// Carga la lista de IDs bloqueados por el usuario (tabla `blocks`, Fase 7)
    /// y se la pasa al motor UWB para que nunca los muestre como marcador,
    /// aunque estén físicamente cerca — ver security_checklist.md, sección 4.
    private func loadBlockedPeers() async {
        struct BlockRow: Decodable { let blocked_id: UUID }
        guard let ids: [BlockRow] = try? await SupabaseManager.shared.client
            .from("blocks")
            .select("blocked_id")
            .execute()
            .value
        else { return }
        proximity.blockedPeerIDs = Set(ids.map { $0.blocked_id })
    }

    // MARK: - Overlay de estado / error

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(proximity.statusMessage ?? camera.statusMessage ?? "Función no disponible en este dispositivo.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.8))
    }
}

/// Hoja mínima al tocar un marcador de peer — equivalente a
/// SendSocialSheet en SocialCameraScreen.kt (Android).
private struct SendSocialSheet: View {
    let onSend: () -> Void
    let onReportOrBlock: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Persona detectada cerca").font(.title3.bold())
            Button("Enviar social", action: onSend)
                .buttonStyle(.borderedProminent)
            Button("Denunciar o bloquear", action: onReportOrBlock)
                .buttonStyle(.bordered)
        }
        .padding(24)
    }
}

#Preview {
    SocialCameraView()
}
