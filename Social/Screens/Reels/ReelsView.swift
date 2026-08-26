//
//  ReelsView.swift
//  Social
//
//  Feed de reels -- primera UI de cliente real sobre el backend de la
//  ronda anterior (ver ReelsViewModel.swift). Diferencia real y deliberada
//  frente a Android: `VerticalPager` de Compose Foundation da paginado
//  vertical de verdad con snap automático a cualquier versión de la
//  librería, pero SwiftUI no tiene un equivalente directo compatible con
//  el deployment target real de este proyecto (iOS 16, `TabView` de
//  página solo pagina en horizontal antes de iOS 17) -- en vez de forzar
//  un truco fragil (rotar la TabView 90°), esta pantalla usa una lista
//  vertical real con reproducción bajo demanda (toca el vídeo para
//  reproducir/pausar), tan real y funcional como el pager de Android,
//  solo con una interacción distinta. Equivalente de ReelsScreen.kt.
//

import SwiftUI
import AVKit
import PhotosUI

struct ReelsView: View {
    @StateObject private var viewModel = ReelsViewModel()
    @State private var showUpload = false
    // Hueco real cerrado en esta pasada: reels ya mostraba el contador de
    // comentarios pero no había ninguna pantalla para leerlos o
    // escribirlos. Mismo patrón que ChatListView.swift para un UUID? no
    // Identifiable atado a un .sheet.
    @State private var commentingReelID: UUID?
    // Abrir un reel concreto real desde un aviso de "like"/"comentario",
    // comparado con Instagram/TikTok -- ver ReelsViewModel.swift.load()
    // para el hallazgo completo.
    let initialReelID: UUID? = nil
    @State private var hasJumpedToInitial = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.isLoading && viewModel.reels.isEmpty {
                        ProgressView().padding()
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red).padding()
                    }
                    if viewModel.reels.isEmpty && !viewModel.isLoading && viewModel.errorMessage == nil {
                        Text("Todavía no hay ningún reel. Sé el primero.")
                            .foregroundStyle(.secondary)
                            .padding(32)
                    }
                    ForEach(viewModel.reels) { reel in
                        ReelRow(
                            reel: reel,
                            author: viewModel.authorProfiles[reel.authorID],
                            isLiked: viewModel.likedReelIDs.contains(reel.id),
                            onLike: { Task { await viewModel.toggleLike(reel) } },
                            onOpenComments: { commentingReelID = reel.id }
                        )
                        .id(reel.id)
                    }
                }
            }
            // Salta una sola vez, apenas el reel señalado por el aviso
            // aparece en la lista (recién cargada, o antepuesta por
            // ReelsViewModel.swift.load() si no estaba entre los 30 más
            // recientes) -- sin el guardián `hasJumpedToInitial`, esto
            // saltaría de nuevo cada vez que `reels` cambia de tamaño por
            // cualquier otro motivo.
            .onChange(of: viewModel.reels.count) { _ in
                if !hasJumpedToInitial, let initialReelID, viewModel.reels.contains(where: { $0.id == initialReelID }) {
                    withAnimation { proxy.scrollTo(initialReelID, anchor: .top) }
                    hasJumpedToInitial = true
                }
            }
        }
        .navigationTitle("Reels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showUpload = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await viewModel.load(pinnedReelID: initialReelID) }
        .refreshable { await viewModel.load() }
        .sheet(isPresented: $showUpload) {
            UploadReelView(isUploading: viewModel.isUploading) { data, ext, caption, isSocialOnly in
                let success = await viewModel.upload(videoData: data, fileExtension: ext, caption: caption, isSocialOnly: isSocialOnly)
                if success { showUpload = false }
            }
        }
        .sheet(isPresented: Binding(
            get: { commentingReelID != nil },
            set: { isPresented in if !isPresented { commentingReelID = nil } }
        )) {
            if let commentingReelID {
                ReelCommentsView(
                    reelID: commentingReelID,
                    onCommentAdded: { viewModel.commentAdded(reelID: commentingReelID) },
                    onCommentRemoved: { viewModel.commentRemoved(reelID: commentingReelID) }
                )
            }
        }
    }
}

private struct ReelRow: View {
    let reel: Reel
    let author: Profile?
    let isLiked: Bool
    let onLike: () -> Void
    let onOpenComments: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ActiveAvatarProvider.shared.avatarView(config: author?.avatarConfig ?? [:], size: 32)
                Text(author?.displayName ?? "…").font(.subheadline.bold())
            }
            ZStack {
                if let url = URL(string: reel.videoURL) {
                    VideoPlayer(player: player ?? AVPlayer(url: url))
                        .onAppear { if player == nil { player = AVPlayer(url: url) } }
                        .onDisappear { player?.pause() }
                }
            }
            .frame(height: 320)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let caption = reel.caption {
                Text(caption).font(.subheadline)
            }
            HStack {
                Button(action: onLike) {
                    Text(isLiked ? "❤" : "🤍")
                }
                Text("\(reel.likeCount)")
                Button(action: onOpenComments) {
                    Text("💬 \(reel.commentCount)")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .padding(.bottom, 8)
        Divider()
    }
}

private struct UploadReelView: View {
    let isUploading: Bool
    let onUpload: (Data, String, String, Bool) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoData: Data?
    @State private var caption = ""
    @State private var isSocialOnly = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Text(videoData == nil ? "Elegir vídeo" : "Vídeo elegido ✓")
                }
                .buttonStyle(.bordered)
                .onChange(of: selectedVideo) { newValue in
                    Task {
                        videoData = try? await newValue?.loadTransferable(type: Data.self)
                    }
                }

                TextField("Descripción (opcional)", text: $caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                Toggle("Solo visible para tus socials aceptados", isOn: $isSocialOnly)

                Button {
                    guard let videoData else { return }
                    Task {
                        await onUpload(videoData, "mp4", caption, isSocialOnly)
                    }
                } label: {
                    if isUploading {
                        ProgressView()
                    } else {
                        Text("Publicar reel").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoData == nil || isUploading)

                Spacer()
            }
            .padding()
            .navigationTitle("Nuevo reel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
