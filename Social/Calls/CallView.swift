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
                if call.groupChatID != nil {
                    let myStatus = callManager.participants.first(where: { $0.userID == myID })?.status
                    switch myStatus {
                    case "ringing":
                        IncomingGroupCallView(call: call, onAccept: callManager.acceptGroupCall, onDecline: callManager.declineGroupCall)
                    case "accepted":
                        LiveGroupCallView(call: call, myID: myID, callManager: callManager, onEnd: callManager.leaveGroupCall)
                    case .some(let status):
                        TerminalGroupCallView(myStatus: status, onDismiss: callManager.dismiss)
                    case nil:
                        // Todavía cargando la lista real de participantes
                        // tras crear la llamada -- un spinner breve es
                        // preferible a parpadear a un estado terminal
                        // falso.
                        ProgressView().tint(.white)
                    }
                } else if call.status == "ringing" && call.calleeID == myID {
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

private struct GroupNameRow: Decodable { let name: String }

@MainActor
private final class GroupNameLoader: ObservableObject {
    @Published var name = "…"

    func load(groupChatID: UUID) async {
        if let row: GroupNameRow = try? await SupabaseManager.shared.client
            .from("group_chats")
            .select("name")
            .eq("id", value: groupChatID)
            .single()
            .execute()
            .value {
            name = row.name
        } else {
            name = "Grupo"
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

/// Llamada de GRUPO entrante real (0083_group_calls.sql), comparado con
/// WhatsApp/Messenger/Telegram -- a diferencia de la 1:1, no hay un único
/// "destinatario" (el propio emisor ya entra 'accepted' de inmediato,
/// nunca ve esta vista): esto lo ve cualquier OTRO miembro real del grupo
/// mientras su propia fila de call_participants siga en 'ringing'.
/// Equivalente de IncomingGroupCallScreen (CallScreen.kt).
private struct IncomingGroupCallView: View {
    let call: Call
    let onAccept: () -> Void
    let onDecline: () -> Void
    @StateObject private var callerLoader = ProfileNameLoader()
    @StateObject private var groupLoader = GroupNameLoader()

    var body: some View {
        VStack {
            VStack(spacing: 8) {
                Text(call.kind == "video" ? "Videollamada de grupo entrante" : "Llamada de grupo entrante")
                    .foregroundStyle(.white.opacity(0.7))
                Text(groupLoader.name)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("\(callerLoader.name) está llamando")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 64)
            Spacer()
            HStack(spacing: 48) {
                CallActionButton(systemImage: "phone.down.fill", background: Color(red: 0.9, green: 0.22, blue: 0.21), action: onDecline)
                CallActionButton(systemImage: "phone.fill", background: Color(red: 0.26, green: 0.65, blue: 0.28), action: onAccept)
            }
            .padding(.bottom, 48)
        }
        .task { await callerLoader.load(profileID: call.callerID) }
        .task { await groupLoader.load(groupChatID: call.groupChatID ?? UUID()) }
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
        // calleeID es opcional en el modelo desde 0083_group_calls.sql
        // (una llamada de grupo no tiene destinatario único), pero esta
        // vista solo se muestra para 1:1 -- nunca debería llegar nil aquí
        // de verdad.
        .task { if let calleeID = call.calleeID { await loader.load(profileID: calleeID) } }
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

/// Estado final real de MI PROPIA participación en una llamada de grupo
/// (0083_group_calls.sql) -- a diferencia de TerminalCallView, el mensaje
/// depende de mi propia fila de call_participants, no de `calls.status`
/// global (que sigue 'accepted' para el resto aunque yo ya haya colgado).
private struct TerminalGroupCallView: View {
    let myStatus: String
    let onDismiss: () -> Void

    private var message: String {
        switch myStatus {
        case "declined": return "Rechazaste la llamada"
        default: return "Saliste de la llamada"
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

    // calleeID es opcional en el modelo desde 0083_group_calls.sql, pero
    // LiveCallView es exclusiva de 1:1 (las de grupo usan
    // LiveGroupCallView) -- nunca debería llegar nil aquí de verdad.
    private var otherID: UUID { call.callerID == myID ? (call.calleeID ?? myID) : call.callerID }

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

/// Mismo patrón real que CallRoomCoordinator, pero generalizado a N
/// participantes reales en vez de uno solo -- las pistas remotas se
/// indexan por identidad de LiveKit (== user_id real, el mismo `identity`
/// que firma call-token/index.ts) en minúsculas, para que coincidan de
/// verdad con `CallParticipant.userID.uuidString` (Swift genera
/// `UUID.uuidString` en MAYÚSCULAS por defecto, pero Postgres/PostgREST
/// devuelven el uuid real en minúsculas -- sin normalizar, las pistas de
/// vídeo nunca emparejarían con su participante real).
///
/// Aviso de honestidad: `participant.identity?.stringValue` no se puede
/// verificar contra un compilador Swift real en este entorno (sin
/// Mac/Xcode, mismo límite ya documentado para RoomDelegate más arriba)
/// -- si el CI real de GitHub Actions lo rechaza, se corrige desde el log
/// real del error, nunca adivinando una segunda vez.
@MainActor
private final class GroupCallRoomCoordinator: NSObject, ObservableObject, RoomDelegate {
    @Published var remoteVideoTracks: [String: VideoTrack] = [:]

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? VideoTrack, let identity = participant.identity?.stringValue else { return }
        Task { @MainActor in self.remoteVideoTracks[identity.lowercased()] = track }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard let identity = participant.identity?.stringValue else { return }
        Task { @MainActor in
            if publication.track == nil { self.remoteVideoTracks.removeValue(forKey: identity.lowercased()) }
        }
    }
}

/// Sala de llamada de GRUPO real (0083_group_calls.sql), comparado con
/// WhatsApp/Messenger/Telegram -- mismo motor LiveKit exacto que
/// LiveCallView (una sala admite de sobra más de dos participantes sin
/// cambio de infraestructura), pero generalizada a N vídeos en vez de uno
/// solo. Alcance deliberadamente simple para este primer corte: una lista
/// vertical de participantes en vez de una cuadrícula real que calcule
/// columnas -- funciona igual de bien con 3 que con 12 personas reales.
/// Equivalente de LiveGroupCallScreen (CallScreen.kt).
private struct LiveGroupCallView: View {
    let call: Call
    let myID: UUID
    @ObservedObject var callManager: CallManager
    let onEnd: () -> Void

    @StateObject private var room = Room()
    @StateObject private var coordinator = GroupCallRoomCoordinator()
    @StateObject private var groupLoader = GroupNameLoader()
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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(groupLoader.name)
                    .foregroundStyle(.white)
                    .font(.headline)
                    .padding()
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(callManager.participants.filter { $0.userID != myID }) { participant in
                            ParticipantTileView(
                                videoTrack: coordinator.remoteVideoTracks[participant.userID.uuidString.lowercased()],
                                isVideoCall: call.kind == "video",
                                participant: participant
                            )
                        }
                    }
                    .padding(.horizontal, 8)
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
        .task { await groupLoader.load(groupChatID: call.groupChatID ?? UUID()) }
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

private struct ParticipantTileView: View {
    let videoTrack: VideoTrack?
    let isVideoCall: Bool
    let participant: CallParticipant
    @StateObject private var loader = ProfileNameLoader()

    private var statusLabel: String {
        switch participant.status {
        case "ringing": return "\(loader.name) · llamando…"
        case "declined": return "\(loader.name) · rechazó"
        case "ended": return "\(loader.name) · salió"
        default: return loader.name
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(red: 0.11, green: 0.11, blue: 0.12))
            if isVideoCall, let videoTrack {
                SwiftUIVideoView(videoTrack)
            } else {
                Circle().fill(.white.opacity(0.15)).frame(width: 64, height: 64)
                    .overlay(Text(loader.name.prefix(1).uppercased()).font(.title2).foregroundStyle(.white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(8)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await loader.load(profileID: participant.userID) }
    }
}
