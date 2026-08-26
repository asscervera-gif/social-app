//
//  LiveStreamRoomView.swift
//  Social
//
//  Sala de un directo real -- host publica cámara+micrófono, espectadores
//  se suscriben y ven su vídeo. Motor real: LiveKit (elegido por el
//  usuario, ver 0056_live_streams.sql y live-token/index.ts). API
//  verificada contra el código fuente real de client-sdk-swift en GitHub
//  (Room.connect/localParticipant.setCamera/RoomDelegate.didSubscribeTrack/
//  SwiftUIVideoView -- ver LOOP_STATE.md para el detalle de qué se
//  verificó y cómo), no adivinada de memoria. Equivalente de
//  LiveStreamRoomScreen.kt (Android usa Flow de RoomEvent; Swift usa el
//  patrón delegate real del SDK, RoomDelegate).
//
//  Aviso de honestidad, mismo criterio que push (APNs/FCM)/duel-ai: sin un
//  proyecto LiveKit Cloud real (LIVEKIT_API_KEY/SECRET/WS_URL como
//  secretos de Supabase), `live-token` no puede emitir un token válido y
//  `room.connect()` fallará limpiamente (capturado más abajo) -- no hay
//  forma de probar una conexión real de vídeo en este entorno sin esas
//  credenciales.
//

import SwiftUI
import LiveKit

@MainActor
private final class LiveStreamRoomCoordinator: NSObject, ObservableObject, RoomDelegate {
    @Published var remoteVideoTrack: VideoTrack?
    @Published var viewerCount: Int = 0

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in
            self.remoteVideoTrack = track
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if self.remoteVideoTrack == nil || publication.track == nil {
                self.remoteVideoTrack = nil
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.viewerCount = room.remoteParticipants.count
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.viewerCount = room.remoteParticipants.count
        }
    }
}

struct LiveStreamRoomView: View {
    let stream: LiveStream
    let isHost: Bool
    @ObservedObject var viewModel: LiveStreamsViewModel
    let onClose: () -> Void

    @StateObject private var room = Room()
    @StateObject private var coordinator = LiveStreamRoomCoordinator()
    @State private var localVideoTrack: VideoTrack?
    @State private var connecting = true
    @State private var errorMessage: String?

    // Chat en vivo real (0059_live_stream_messages.sql), comparado con
    // Instagram/TikTok Live -- antes solo había vídeo, nadie podía
    // escribir mientras veía un directo.
    @StateObject private var chatViewModel: LiveStreamChatViewModel
    @State private var chatDraft = ""

    init(stream: LiveStream, isHost: Bool, viewModel: LiveStreamsViewModel, onClose: @escaping () -> Void) {
        self.stream = stream
        self.isHost = isHost
        self.viewModel = viewModel
        self.onClose = onClose
        self._chatViewModel = StateObject(wrappedValue: LiveStreamChatViewModel(streamID: stream.id))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isHost, let localVideoTrack {
                SwiftUIVideoView(localVideoTrack)
                    .ignoresSafeArea()
            } else if !isHost, let remoteVideoTrack = coordinator.remoteVideoTrack {
                SwiftUIVideoView(remoteVideoTrack)
                    .ignoresSafeArea()
            } else if !connecting && errorMessage == nil {
                Text(isHost ? "Cámara conectándose…" : "Esperando el vídeo del host…")
                    .foregroundStyle(.white)
            }

            if connecting {
                ProgressView().tint(.white)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .padding(24)
                    .multilineTextAlignment(.center)
            }

            VStack {
                HStack {
                    Text("👁 \(coordinator.viewerCount)").foregroundStyle(.white).bold()
                    Spacer()
                    Text(stream.title ?? "Directo").foregroundStyle(.white).bold()
                }
                .padding()

                Spacer()

                // Chat en vivo real, comparado con Instagram/TikTok Live:
                // lista de mensajes que se desplaza sobre el vídeo (abajo
                // a la izquierda, mismo sitio que esas apps).
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(chatViewModel.messages) { message in
                                (Text(chatViewModel.senderNames[message.senderID] ?? "…").bold() + Text(": \(message.body)"))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .id(message.id)
                            }
                        }
                    }
                    .frame(maxWidth: 260, maxHeight: 180)
                    .onChange(of: chatViewModel.messages.count) { _ in
                        if let last = chatViewModel.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)

                if stream.status == "live" {
                    HStack {
                        TextField("Comenta…", text: $chatDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                chatViewModel.sendMessage(chatDraft)
                                chatDraft = ""
                            }
                        Button("➤") {
                            chatViewModel.sendMessage(chatDraft)
                            chatDraft = ""
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                Button(isHost ? "Terminar directo" : "Salir") {
                    Task {
                        if isHost {
                            await viewModel.endStream(stream)
                        } else {
                            await viewModel.leaveStream(stream)
                        }
                        onClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 32)
            }
        }
        .task {
            await chatViewModel.load()
        }
        .task {
            room.add(delegate: coordinator)

            let tokenInfo = isHost ? await viewModel.requestHostToken(stream) : await viewModel.joinAndGetToken(stream)
            guard let tokenInfo else {
                errorMessage = "No se pudo conseguir el token real del directo -- revisa que LIVEKIT_API_KEY/SECRET/WS_URL estén configurados de verdad (ver live-token/index.ts)."
                connecting = false
                return
            }
            do {
                try await room.connect(url: tokenInfo.wsUrl, token: tokenInfo.token)
                if isHost {
                    try await room.localParticipant.setCamera(enabled: true)
                    try await room.localParticipant.setMicrophone(enabled: true)
                    localVideoTrack = room.localParticipant.videoTracks.first?.track as? VideoTrack
                }
                connecting = false
            } catch {
                errorMessage = "No se pudo conectar al servidor real de directos: \(error.localizedDescription)"
                connecting = false
            }
        }
        .onDisappear {
            Task { await room.disconnect() }
        }
    }
}
