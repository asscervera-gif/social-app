//
//  CallView.swift
//  Social
//
//  Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado con
//  WhatsApp/Messenger/Instagram -- ver CallManager.swift para el hallazgo
//  completo. Equivalente de CallScreen.kt.
//
//  Aviso de honestidad, mismo criterio que "En directo": sin un proyecto
//  LiveKit Cloud real (LIVEKIT_API_KEY/SECRET/WS_URL como secretos de
//  Supabase), `call-token` no puede emitir un token válido y
//  `room.connect()` fallará limpiamente (capturado más abajo).
//

import SwiftUI
import LiveKit

/// Overlay real montado en RootTabView.swift (visible sobre cualquier
/// pestaña, igual que un aviso), no una pantalla de navegación normal:
/// una llamada entrante no debe esperar a que el usuario navegue a
/// ningún sitio.
struct CallOverlayView: View {
    @ObservedObject var callManager: CallManager
    let myID: UUID

    var body: some View {
        if let call = callManager.activeCall {
            ZStack {
                Color.black.ignoresSafeArea()
                if call.status == "ringing" && call.calleeID == myID {
                    IncomingCallView(call: call, onAccept: callManager.accept, onDecline: callManager.decline)
                } else if call.status == "ringing" && call.callerID == myID {
                    OutgoingCallView(call: call, onCancel: callManager.cancelOutgoing)
                } else if call.status == "accepted" {
                    LiveCallView(call: call, myID: myID, callManager: callManager, onEnd: callManager.end)
                } else {
                    TerminalCallView(call: call, onDismiss: callManager.dismiss)
                }
            }
        }
    }
}

private struct NameRow: Decodable { let display_name: String }

@MainActor
private final class ProfileNameLoader: ObservableObject {
    @Published var name = "…"

    func load(profileID: UUID) async {
        if let row: NameRow = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name")
            .eq("id", value: profileID)
            .single()
            .execute()
            .value {
            name = row.display_name
        } else {
            name = "Alguien"
        }
    }
}

private struct IncomingCallView: View {
    let call: Call
    let onAccept: () -> Void
    let onDecline: () -> Void
    @StateObject private var loader = ProfileNameLoader()

    var body: some View {
        VStack {
            VStack(spacing: 8) {
                Text(call.kind == "video" ? "Videollamada entrante" : "Llamada entrante")
                    .foregroundStyle(.white.opacity(0.7))
                Text(loader.name)
                    .font(.title.bold())
                    .foregroundStyle(.white)
            }
            .padding(.top, 64)
            Spacer()
            HStack(spacing: 48) {
                CallActionButton(systemImage: "phone.down.fill", background: Color(red: 0.9, green: 0.22, blue: 0.21), action: onDecline)
                CallActionButton(systemImage: "phone.fill", background: Color(red: 0.26, green: 0.65, blue: 0.28), action: onAccept)
            }
            .padding(.bottom, 48)
        }
        .task { await loader.load(profileID: call.callerID) }
    }
}

private struct OutgoingCallView: View {
    let call: Call
    let onCancel: () -> Void
    @StateObject private var loader = ProfileNameLoader()

    var body: some View {
        VStack {
            VStack(spacing: 8) {
                Text("Llamando…").foregroundStyle(.white.opacity(0.7))
                Text(loader.name).font(.title.bold()).foregroundStyle(.white)
            }
            .padding(.top, 64)
            Spacer()
            CallActionButton(systemImage: "phone.down.fill", background: Color(red: 0.9, green: 0.22, blue: 0.21), action: onCancel)
                .padding(.bottom, 48)
        }
        .task { await loader.load(profileID: call.calleeID) }
    }
}

private struct TerminalCallView: View {
    let call: Call
    let onDismiss: () -> Void

    private var message: String {
        switch call.status {
        case "declined": return "Llamada rechazada"
        case "missed": return "No contestó"
        default: return "Llamada finalizada"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(message).font(.title2.bold()).foregroundStyle(.white)
            Button("Cerrar", action: onDismiss)
                .buttonStyle(.bordered)
                .tint(.white)
        }
    }
}

private struct CallActionButton: View {
    let systemImage: String
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(.white)
                .font(.title2)
                .frame(width: 64, height: 64)
                .background(Circle().fill(background))
        }
    }
}

/// Mismo patrón real que LiveStreamRoomCoordinator (LiveStreamRoomView.swift):
/// RoomDelegate real del SDK, API verificada contra el código fuente de
/// client-sdk-swift en GitHub.
@MainActor
private final class CallRoomCoordinator: NSObject, ObservableObject, RoomDelegate {
    @Published var remoteVideoTrack: VideoTrack?

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = track }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if publication.track == nil { self.remoteVideoTrack = nil }
        }
    }
}

/// Sala de llamada real -- mismo motor y misma API real que
/// LiveStreamRoomView.swift, pero simétrica: las dos partes publican
/// cámara/micrófono (según `kind`) y se suscriben por igual, sin
/// distinción host/espectador.
///
/// Aviso de honestidad: a diferencia de CallScreen.kt (donde
/// `RoomEvent.Disconnected` SÍ quedó verificado por el compilador real de
/// Kotlin al compilar), aquí se evita deliberadamente adivinar el nombre
/// exacto de un método de `RoomDelegate` para el cambio de estado de
/// conexión sin poder verificarlo con un compilador Swift real en este
/// entorno -- no hace falta: colgar de verdad ya actualiza `calls.status`
/// en Postgres, y ese cambio llega a las dos partes por Realtime
/// (CallManager.swift), que es lo que de verdad saca a esta vista de la
/// llamada -- el room de LiveKit se desconecta solo al desaparecer la
/// vista (`.onDisappear`).
private struct LiveCallView: View {
    let call: Call
    let myID: UUID
    @ObservedObject var callManager: CallManager
    let onEnd: () -> Void

    @StateObject private var room = Room()
    @StateObject private var coordinator = CallRoomCoordinator()
    @StateObject private var loader = ProfileNameLoader()
    @State private var localVideoTrack: VideoTrack?
    @State private var connecting = true
    @State private var errorMessage: String?
    @State private var micEnabled = true
    @State private var cameraEnabled: Bool

    init(call: Call, myID: UUID, callManager: CallManager, onEnd: @escaping () -> Void) {
        self.call = call
        self.myID = myID
        self.callManager = callManager
        self.onEnd = onEnd
        _cameraEnabled = State(initialValue: call.kind == "video")
    }

    private var otherID: UUID { call.callerID == myID ? call.calleeID : call.callerID }

    var body: some View {
        ZStack {
            if call.kind == "video", let remoteVideoTrack = coordinator.remoteVideoTrack {
                SwiftUIVideoView(remoteVideoTrack).ignoresSafeArea()
            } else if !connecting && errorMessage == nil {
                VStack(spacing: 12) {
                    Circle().fill(.white.opacity(0.15)).frame(width: 96, height: 96)
                        .overlay(Text(loader.name.prefix(1).uppercased()).font(.largeTitle).foregroundStyle(.white))
                    Text(loader.name).foregroundStyle(.white).font(.title3.bold())
                    if call.kind == "video" {
                        Text("Esperando el vídeo…").foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            if call.kind == "video", cameraEnabled, let localVideoTrack {
                VStack {
                    HStack {
                        Spacer()
                        SwiftUIVideoView(localVideoTrack)
                            .frame(width: 100, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                    Spacer()
                }
            }

            if connecting {
                ProgressView().tint(.white)
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }

            VStack {
                Spacer()
                HStack(spacing: 24) {
                    CallActionButton(systemImage: micEnabled ? "mic.fill" : "mic.slash.fill", background: .white.opacity(0.2)) {
                        micEnabled.toggle()
                        Task { try? await room.localParticipant.setMicrophone(enabled: micEnabled) }
                    }
                    if call.kind == "video" {
                        CallActionButton(systemImage: cameraEnabled ? "video.fill" : "video.slash.fill", background: .white.opacity(0.2)) {
                            cameraEnabled.toggle()
                            Task { try? await room.localParticipant.setCamera(enabled: cameraEnabled) }
                        }
                    }
                    CallActionButton(systemImage: "phone.down.fill", background: Color(red: 0.9, green: 0.22, blue: 0.21), action: onEnd)
                }
                .padding(.bottom, 32)
            }
        }
        .task { await loader.load(profileID: otherID) }
        .task {
            room.add(delegate: coordinator)
            guard let tokenInfo = await callManager.requestToken(callID: call.id) else {
                errorMessage = "No se pudo conseguir el token real de la llamada -- revisa que LIVEKIT_API_KEY/SECRET/WS_URL estén configurados de verdad (ver call-token/index.ts)."
                connecting = false
                return
            }
            do {
                try await room.connect(url: tokenInfo.wsUrl, token: tokenInfo.token)
                try await room.localParticipant.setMicrophone(enabled: true)
                if call.kind == "video" {
                    try await room.localParticipant.setCamera(enabled: true)
                    localVideoTrack = room.localParticipant.videoTracks.first?.track as? VideoTrack
                }
                connecting = false
            } catch {
                errorMessage = "No se pudo conectar al servidor real de llamadas: \(error.localizedDescription)"
                connecting = false
            }
        }
        .onDisappear {
            Task { await room.disconnect() }
        }
    }
}
