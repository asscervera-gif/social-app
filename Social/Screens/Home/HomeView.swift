//
//  HomeView.swift
//  Social
//
//  Feed de publicaciones (like y comentarios reales, ver 0007_likes.sql /
//  0008_comments.sql), recomendados con % de compatibilidad, y acceso a
//  "Find" (placeholder de mapa, sin implementar todavía). Sin scroll
//  infinito ni algoritmo de adicción: lista paginada y finita.
//
//  Corrección de honestidad: este comentario afirmaba antes "Historias,
//  comentar, enviar, guardar" como si existieran — like, comentar, enviar
//  (ShareLink nativo) y guardar ya son reales; solo Historias sigue sin
//  implementar en ninguna plataforma. Ver LOOP_STATE.md > Pendiente real.
//

import SwiftUI

struct HomeView: View {

    @StateObject private var viewModel = HomeViewModel()
    @State private var showFind = false
    @State private var hashtagToOpen: String?
    // Hallazgo real: no había ninguna forma de crear una publicación en
    // toda la app (ver NewPostViewModel.swift para el detalle completo).
    @State private var showNewPost = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Hallazgo real: no había ningún cliente para Historias
                    // en ninguna plataforma pese a que el esquema/RLS ya
                    // estaban completos desde el principio (ver
                    // StoriesViewModel.swift).
                    StoriesBar()
                        .padding(.horizontal)
                    Divider()
                    recommendedSection
                    Divider()
                    feedSection
                }
                .padding(.top, 8)
            }
            // Hallazgo real: comparado con Instagram/Twitter/Facebook,
            // ninguna pantalla de la app tenía pull-to-refresh, un gesto
            // básico esperado en cualquier app social.
            .refreshable {
                await viewModel.load()
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNewPost = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Hallazgo real: comparado con Instagram/TikTok/Snapchat,
                    // no había ningún buscador de personas en la app (ver
                    // SearchViewModel.swift).
                    NavigationLink {
                        SearchView()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFind = true
                    } label: {
                        Image(systemName: "map")
                    }
                }
            }
            .task { await viewModel.load() }
            // Hallazgo real (CI real, GitHub Actions, 2026-08-24):
            // `navigationDestination(item:destination:)` requiere iOS 17+,
            // pero el objetivo de despliegue del proyecto es iOS 16.0
            // (project.yml) — no compilaba. Mismo resultado con la
            // variante compatible desde iOS 16 (`isPresented:`), atada al
            // mismo estado opcional en vez de duplicar un Bool aparte.
            .navigationDestination(isPresented: Binding(
                get: { hashtagToOpen != nil },
                set: { isPresented in if !isPresented { hashtagToOpen = nil } }
            )) {
                if let tag = hashtagToOpen {
                    SearchView(initialHashtag: tag)
                }
            }
            .sheet(isPresented: $showFind) {
                // Hallazgo real: esto era un texto de relleno, nunca un
                // mapa real (ver FindMapView.swift/FindLocationsViewModel.swift).
                NavigationStack {
                    FindMapView()
                        .navigationTitle("Find")
                }
            }
            .sheet(isPresented: $showNewPost) {
                NewPostView(
                    onDismiss: { showNewPost = false },
                    onPosted: { Task { await viewModel.load() } }
                )
            }
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recomendados para ti")
                .font(.headline)
                .padding(.horizontal)

            if viewModel.recommended.isEmpty {
                Text("Aún no tenemos recomendaciones para ti.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(viewModel.recommended, id: \.profile.id) { entry in
                            RecommendedCard(profile: entry.profile, compatibility: entry.compatibility)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isLoading {
                ProgressView().padding(.horizontal)
            }
            ForEach(viewModel.feed) { post in
                PostCard(
                    post: post,
                    isSaved: viewModel.savedPostIDs.contains(post.id),
                    isLiked: viewModel.likedPostIDs.contains(post.id),
                    onLike: {
                        Task { await viewModel.toggleLike(post) }
                    },
                    onCommentAdded: {
                        viewModel.commentAdded(postID: post.id)
                    },
                    onCommentRemoved: {
                        viewModel.commentRemoved(postID: post.id)
                    },
                    onToggleSave: {
                        Task { await viewModel.toggleSave(post) }
                    },
                    onOpenHashtag: { tag in hashtagToOpen = tag }
                )
            }
        }
        .padding(.horizontal)
    }
}

/// Construye una etiqueta tocable dentro del caption usando
/// `AttributedString.link` con un esquema propio (`socialhashtag://tag`) —
/// no es una URL real, solo se usa como transporte para que
/// `.environment(\.openURL)` intercepte el toque, mismo criterio ya usado
/// en otros sitios de la app para acciones locales sin backend.
private func hashtagAttributedString(_ caption: String) -> AttributedString {
    var result = AttributedString("")
    let words = caption.split(separator: " ", omittingEmptySubsequences: false)
    for (index, word) in words.enumerated() {
        var piece = AttributedString(word)
        if word.hasPrefix("#"), word.count > 1 {
            let tag = word.dropFirst().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if let url = URL(string: "socialhashtag://\(tag)") {
                piece.link = url
                piece.foregroundColor = .accentColor
                piece.underlineStyle = .single
            }
        }
        result += piece
        if index != words.count - 1 { result += AttributedString(" ") }
    }
    return result
}

private struct RecommendedCard: View {
    let profile: Profile
    let compatibility: Int?

    var body: some View {
        VStack(spacing: 6) {
            ActiveAvatarProvider.shared.avatarView(config: profile.avatarConfig ?? [:], size: 64)
            Text(profile.displayName)
                .font(.caption.bold())
                .lineLimit(1)
            Text(compatibility.map { "\($0)%" } ?? "?%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 84)
    }
}

private struct PostCard: View {
    let post: Post
    let isSaved: Bool
    let isLiked: Bool
    let onLike: () -> Void
    let onCommentAdded: () -> Void
    var onCommentRemoved: () -> Void = {}
    let onToggleSave: () -> Void
    var onOpenHashtag: (String) -> Void = { _ in }
    @State private var showComments = false
    // Hallazgo real: comparado con cualquier app grande, no había forma de
    // denunciar una publicación directamente — solo existía la denuncia
    // global de usuario. `reports.reported_id` no tiene columna de post_id,
    // así que se denuncia al autor con el id del post en los detalles.
    @State private var showReport = false
    @State private var myID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hallazgo real: esta caja gris con icono de foto era siempre
            // decorativa, para TODOS los posts, sin importar si tenían
            // media_url — no había ninguna integración de Storage. Ahora
            // se renderiza la imagen real si existe (ver StorageUploader.swift).
            if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.15))
                }
                .frame(height: 220)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(.gray.opacity(0.15))
                .frame(height: 220)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
            }

            if let caption = post.caption {
                // Hallazgo real: el buscador ya sabía buscar posts por
                // "#etiqueta" (ver SearchViewModel.swift) pero no había
                // ninguna forma de llegar ahí desde una publicación real
                // del feed — había que teclear la etiqueta de memoria.
                // Mismo criterio ya construido y compiler-verificado en la
                // versión Kotlin equivalente (CaptionText en
                // HomeScreen.kt), aquí con `AttributedString.link` en vez
                // de `ClickableText` (no existe en SwiftUI).
                Text(hashtagAttributedString(caption))
                    .font(.subheadline)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "socialhashtag", let tag = url.host {
                            onOpenHashtag(tag)
                            return .handled
                        }
                        return .systemAction
                    })
            }
            Text(relativeTime(post.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Button(action: onLike) {
                    Label("\(post.likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                }
                .foregroundStyle(isLiked ? .red : .primary)
                Button {
                    showComments = true
                } label: {
                    Label("\(post.commentCount)", systemImage: "bubble.right")
                }
                Spacer()
                // Icono antes puramente decorativo — usa ShareLink nativo
                // (iOS 16+, coincide con el deploymentTarget del proyecto),
                // no hace falta infraestructura propia para "compartir".
                ShareLink(item: post.caption.map { "Mira esto en SOCIAL: \($0)" } ?? "Mira esto en SOCIAL") {
                    Image(systemName: "paperplane")
                }
                Button(action: onToggleSave) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                }
                Button {
                    showReport = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showComments) {
            CommentsView(postID: post.id, onCommentAdded: onCommentAdded, onCommentRemoved: onCommentRemoved)
        }
        .sheet(isPresented: $showReport) {
            if let myID {
                ReportSheet(userID: myID, reportedID: post.authorID, initialDetails: "Publicación \(post.id)")
            }
        }
        .task {
            myID = try? await SupabaseManager.shared.client.auth.session.user.id
        }
    }
}

/// Hora relativa ("hace 2h", "3d") — ningún post mostraba fecha/hora en
/// absoluto, comparado con cualquier app grande. `created_at` de Postgres
/// llega en ISO 8601. Equivalente de relativeTime() en HomeScreen.kt.
private func relativeTime(_ isoTimestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let then = formatter.date(from: isoTimestamp) ?? ISO8601DateFormatter().date(from: isoTimestamp) else {
        return ""
    }
    let seconds = Date().timeIntervalSince(then)
    switch seconds {
    case ..<60: return "ahora"
    case ..<3600: return "hace \(Int(seconds / 60))min"
    case ..<86400: return "hace \(Int(seconds / 3600))h"
    case ..<604800: return "hace \(Int(seconds / 86400))d"
    default: return "hace \(Int(seconds / 604800))sem"
    }
}
