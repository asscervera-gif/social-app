//
//  LiveStreamsView.swift
//  Social
//
//  Lista de directos activos + arrancar el propio. Ronda de cliente sobre
//  el backend ya construido y verificado (0056_live_streams.sql). Mismo
//  patrón visual que StoriesBar.swift/ReelsView.swift. Equivalente de
//  LiveStreamsScreen.kt.
//

import SwiftUI

struct LiveStreamsView: View {
    @StateObject private var viewModel = LiveStreamsViewModel()
    @State private var showStartSheet = false
    @State private var activeRoom: (stream: LiveStream, isHost: Bool)?
    @State private var myID: UUID?

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.streams.isEmpty {
                ProgressView()
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !viewModel.isLoading && viewModel.streams.isEmpty && viewModel.errorMessage == nil {
                Text("Nadie está en directo ahora mismo.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.streams) { stream in
                Button {
                    activeRoom = (stream, stream.hostID == myID)
                } label: {
                    HStack {
                        ActiveAvatarProvider.shared.avatarView(
                            config: viewModel.hostProfiles[stream.hostID]?.avatarConfig ?? [:],
                            size: 40
                        )
                        VStack(alignment: .leading) {
                            Text(viewModel.hostProfiles[stream.hostID]?.displayName ?? "…")
                                .font(.subheadline.bold())
                            Text(stream.title ?? "Directo")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("🔴 \(stream.viewerCount)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Directos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStartSheet = true
                } label: {
                    Text("🔴").font(.title3)
                }
            }
        }
        .task {
            await viewModel.load()
            myID = try? await SupabaseManager.shared.client.auth.session.user.id
        }
        .sheet(isPresented: $showStartSheet) {
            StartLiveStreamView(viewModel: viewModel) { stream in
                showStartSheet = false
                activeRoom = (stream, true)
            }
        }
        .fullScreenCover(item: Binding(
            get: { activeRoom.map { RoomWrapper(stream: $0.stream, isHost: $0.isHost) } },
            set: { newValue in activeRoom = newValue.map { ($0.stream, $0.isHost) } }
        )) { wrapper in
            LiveStreamRoomView(stream: wrapper.stream, isHost: wrapper.isHost, viewModel: viewModel) {
                activeRoom = nil
                Task { await viewModel.load() }
            }
        }
    }
}

/// `.fullScreenCover(item:)` necesita `Identifiable` -- envoltorio simple
/// para la tupla (stream, isHost) que ya usa `activeRoom`.
private struct RoomWrapper: Identifiable {
    let stream: LiveStream
    let isHost: Bool
    var id: UUID { stream.id }
}

private struct StartLiveStreamView: View {
    @ObservedObject var viewModel: LiveStreamsViewModel
    let onStarted: (LiveStream) -> Void
    @State private var title = ""
    @State private var isSocialOnly = false
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Título (opcional)", text: $title)
                Toggle("Solo visible para tus socials aceptados", isOn: $isSocialOnly)
                Button {
                    starting = true
                    Task {
                        let stream = await viewModel.startStream(title: title, isSocialOnly: isSocialOnly)
                        starting = false
                        if let stream {
                            onStarted(stream)
                        }
                    }
                } label: {
                    if starting {
                        ProgressView()
                    } else {
                        Text("Empezar directo").frame(maxWidth: .infinity)
                    }
                }
                .disabled(starting)
            }
            .navigationTitle("Empezar un directo")
        }
    }
}
