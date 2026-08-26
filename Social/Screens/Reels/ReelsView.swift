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
    // Aviso de honestidad: tiene que ser `var`, no `let` -- una propiedad
    // `let` CON valor por defecto queda excluida del init memberwise
    // sintetizado por Swift (se trata como una constante fija, no como un
    // parámetro con valor por defecto), lo que dejaba el init sin ningún
    // argumento real utilizable desde fuera -- confirmado con el propio
    // error real de compilador en CI ("argument passed to call that takes
    // no arguments") al intentar `ReelsView(initialReelID:)` desde
    // AvisosView.swift.
    var initialReelID: UUID? = nil
    @State private var hasJumpedToInitial = false
    // Desactivar los comentarios de un reel propio, comparado con
    // Instagram/TikTok -- el control solo tiene sentido sobre el reel
    // propio (0086_disable_comments.sql).
    @State private var myID: UUID?

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
                        row(for: reel)
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
        .task { myID = try? await SupabaseManager.shared.client.auth.session.user.id }
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

    // Extraído aparte real: el compilador de Swift real (CI, fallo real
    // visto en el log) no podía type-checkear `body` en tiempo razonable
    // con esta llamada (7 argumentos, dos closures) inlineada dentro del
    // `ForEach` -- mismo hallazgo de por qué SwiftUI a veces exige romper
    // una expresión grande en sub-expresiones más pequeñas, no un error de
    // lógica.
    private func row(for reel: Reel) -> some View {
        ReelRow(
            reel: reel,
            author: viewModel.authorProfiles[reel.authorID],
            isLiked: viewModel.likedReelIDs.contains(reel.id),
            isMine: reel.authorID == myID,
            onLike: { Task { await viewModel.toggleLike(reel) } },
            onOpenComments: { commentingReelID = reel.id },
            onToggleCommentsDisabled: { Task { await viewModel.toggleCommentsDisabled(reel) } }
        )
    }
}

private struct ReelRow: View {
    let reel: Reel
    let author: Profile?
    let isLiked: Bool
    // Desactivar los comentarios de un reel propio, comparado con
    // Instagram/TikTok -- el control solo tiene sentido sobre el reel
    // propio (0086_disable_comments.sql).
    let isMine: Bool
    let onLike: () -> Void
    let onOpenComments: () -> Void
    let onToggleCommentsDisabled: () -> Void
    @State private var player: AVPlayer?
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/TikTok -- esta pantalla ni siquiera tenía etiquetas
    // tocables (a diferencia del feed, HomeView.swift.PostCard), solo
    // texto plano; se corrige de paso al construir el componente
    // compartido MentionHashtagText.swift.
    @State private var mentionProfileID: UUID?

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
                MentionHashtagText(
                    text: caption,
                    onOpenMention: { username in
                        Task { mentionProfileID = await MentionResolver.resolveProfileID(username: username) }
                    }
                )
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
                // Desactivar los comentarios de este reel propio, comparado
                // con Instagram/TikTok -- los comentarios previos se
                // quedan, solo se cierra la puerta a comentarios nuevos
                // (0086_disable_comments.sql).
                if isMine {
                    Button(action: onToggleCommentsDisabled) {
                        Text(reel.commentsDisabled ? "🔕" : "🔔")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .padding(.bottom, 8)
        // Mismo patrón `isPresented:` compatible con iOS 16 ya usado en
        // HomeView.swift.PostCard -- ReelsView() siempre se presenta
        // dentro de un NavigationStack propio del que la llama
        // (PerfilView.swift/AvisosView.swift), así que este modificador
        // funciona igual aquí aunque ReelsView.body no declare el suyo.
        .navigationDestination(isPresented: Binding(
            get: { mentionProfileID != nil },
            set: { isPresented in if !isPresented { mentionProfileID = nil } }
        )) {
            if let mentionProfileID {
                ProfileViewerView(profileID: mentionProfileID)
            }
        }
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
