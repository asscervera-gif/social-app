//
//  HomeView.swift
//  Social
//
//  Feed de publicaciones (like y comentarios reales, ver 0007_likes.sql /
//  0008_comments.sql) y recomendados con % de compatibilidad. Sin scroll
//  infinito ni algoritmo de adicción — lista finita, igual que
//  HomeScreen.kt.
//
//  Corrección de honestidad (2026-08-25, mismo hallazgo ya corregido en
//  HomeScreen.kt): este docstring afirmaba que Historias seguía sin
//  implementar — falso, StoriesBar() (más abajo) ya está construida y
//  montada. Like, comentar, enviar (ShareLink nativo), guardar e
//  Historias son todos reales.
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
                    // Cabecera de marca real (antes: título de texto plano
                    // "Home" + iconos de sistema en la barra de navegación)
                    // — puesta en línea con el resto del rediseño visual
                    // (logo real, degradado de marca), mismo patrón que
                    // HomeScreen.kt. "Find" y "Buscar" (función real detrás,
                    // ver FindLocationsViewModel.swift/SearchViewModel.swift)
                    // se mantienen, solo cambia su presentación.
                    header
                        .padding(.horizontal)
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
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                // "Nuevo post" — antes un icono en la barra de navegación,
                // ahora un botón flotante (mismo cambio que
                // HomeScreen.kt: FloatingActionButton), ya que la cabecera
                // de marca no deja sitio para un tercer icono de sistema.
                Button {
                    showNewPost = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(radius: 4)
                }
                .padding()
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

    private var header: some View {
        HStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Color(red: 0.302, green: 0.671, blue: 0.969), Color(red: 0.647, green: 0.369, blue: 0.918)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 32, height: 32)
                .overlay(Text("F").foregroundStyle(.white).font(.headline))
                .onTapGesture { showFind = true }
            Spacer()
            Image("social_logo")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
            Spacer()
            // Hallazgo real: comparado con Instagram/TikTok/Snapchat, no
            // había ningún buscador de personas en la app (ver
            // SearchViewModel.swift).
            NavigationLink {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.primary)
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
                            // Hallazgo real, mismo hueco raíz ya cerrado en
                            // el feed principal: "Recomendados" tampoco
                            // llevaba a ningún perfil al tocarlo, comparado
                            // con "Sugeridos para ti" de Instagram.
                            NavigationLink {
                                ProfileViewerView(profileID: entry.profile.id)
                            } label: {
                                RecommendedCard(
                                    profile: entry.profile,
                                    compatibility: entry.compatibility,
                                    requestSent: entry.requestSent,
                                    onRequest: { Task { await viewModel.requestCompatibility(profileID: entry.profile.id) } }
                                )
                            }
                            .buttonStyle(.plain)
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
                let author = viewModel.authorProfiles[post.authorID]
                PostCard(
                    post: post,
                    author: author,
                    extraMedia: viewModel.extraMediaByPost[post.id] ?? [],
                    compatibility: author.flatMap { viewModel.compatibilityFor($0) },
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
                    onOpenHashtag: { tag in hashtagToOpen = tag },
                    onRequestCompat: {
                        Task { await viewModel.requestCompatibility(profileID: post.authorID) }
                    }
                )
            }
        }
        .padding(.horizontal)
    }
}

private struct RecommendedCard: View {
    let profile: Profile
    let compatibility: Int?
    let requestSent: Bool
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ActiveAvatarProvider.shared.avatarView(config: profile.avatarConfig ?? [:], size: 64)
            Text(profile.displayName)
                .font(.caption.bold())
                .lineLimit(1)
            CompatBadge(compatibility: compatibility, requestSent: requestSent, onRequest: onRequest)
        }
        .frame(width: 84)
    }
}

/// Hallazgo real, comparado con SOCIAL_APP.html (`reqCompat()`): "?%" era
/// texto fijo, sin ninguna forma de pedir ver la compatibilidad real
/// cuando es privada -- a diferencia de Match, que ya tenía este mismo
/// flujo (CompatBadge en MatchView.swift) desde antes. Mismos 3 estados
/// reales (público/pendiente/pedir), reutilizados aquí en Recomendados y
/// en la cabecera de cada post del feed. `Button` real (no Text+
/// onTapGesture) porque esta tarjeta vive dentro de la etiqueta de un
/// NavigationLink -- mismo criterio ya establecido en
/// MatchView.CompatBadge.
private struct CompatBadge: View {
    let compatibility: Int?
    let requestSent: Bool
    let onRequest: () -> Void

    var body: some View {
        if let compat = compatibility {
            Text("\(compat)% compat.")
                .font(.caption2.bold())
                .foregroundStyle(.green)
        } else if requestSent {
            Text("Pendiente")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Button(action: onRequest) {
                Text("?% · Pedir")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PostCard: View {
    let post: Post
    let author: Profile?
    var extraMedia: [String] = []
    var compatibility: Int? = nil
    let isSaved: Bool
    let isLiked: Bool
    let onLike: () -> Void
    let onCommentAdded: () -> Void
    var onCommentRemoved: () -> Void = {}
    let onToggleSave: () -> Void
    var onOpenHashtag: (String) -> Void = { _ in }
    var onRequestCompat: () -> Void = {}
    @State private var showComments = false
    // Hallazgo real, comparado con SOCIAL_APP.html: cada post del feed
    // muestra el % de compatibilidad con el autor en su cabecera, no solo
    // el carrusel de "Recomendados" -- estado local (no en el ViewModel,
    // a diferencia de Recomendados) porque aquí no hay una lista estable
    // de "entries" a la que atar el estado "pendiente" real.
    @State private var compatRequestSent = false
    // Hallazgo real: comparado con cualquier app grande, no había forma de
    // denunciar una publicación directamente — solo existía la denuncia
    // global de usuario. `reports.reported_id` no tiene columna de post_id,
    // así que se denuncia al autor con el id del post en los detalles.
    @State private var showReport = false
    @State private var myID: UUID?
    @State private var fullScreenURL: URL?
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat -- antes el icono ➤
    // solo abría el share sheet nativo del sistema (ShareLink), sin
    // ninguna forma de mandarla como mensaje real dentro de la propia app.
    @State private var showSendSheet = false
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/Twitter/TikTok -- distinto del NavigationLink de arriba
    // (siempre lleva al AUTOR del post): aquí el destino se resuelve en
    // tiempo real a partir del @usuario tocado dentro del propio caption.
    @State private var mentionProfileID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hallazgo real, comparado con cualquier app grande
            // (Instagram/TikTok/Twitter): la tarjeta no mostraba QUIÉN
            // publicó cada post, ni dejaba tocar para ver su perfil (ver
            // HomeViewModel.authorProfiles). Mismo patrón de navegación ya
            // usado en MatchView.swift.
            NavigationLink {
                ProfileViewerView(profileID: post.authorID)
            } label: {
                HStack(spacing: 8) {
                    ActiveAvatarProvider.shared.avatarView(config: author?.avatarConfig ?? [:], size: 32)
                    Text(author?.displayName ?? "…")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    // Hallazgo real, comparado con SOCIAL_APP.html
                    // (`.pcompat` en la cabecera de cada post): la app real
                    // solo mostraba el % de compatibilidad en
                    // "Recomendados", nunca junto al autor de una
                    // publicación normal del feed.
                    if let author, author.id != myID {
                        CompatBadge(
                            compatibility: compatibility,
                            requestSent: compatRequestSent,
                            onRequest: { compatRequestSent = true; onRequestCompat() }
                        )
                    }
                }
            }
            .buttonStyle(.plain)

            // Hallazgo real: esta caja gris con icono de foto era siempre
            // decorativa, para TODOS los posts, sin importar si tenían
            // media_url — no había ninguna integración de Storage. Ahora
            // se renderiza la imagen real si existe (ver StorageUploader.swift).
            // Comparado con Instagram/Facebook: publicaciones con varias
            // fotos (0055_post_media.sql) -- `post.mediaURL` es siempre la
            // primera, `extraMedia` trae el resto ya en orden. Con una sola
            // foto (el caso normal hasta ahora) se muestra igual que antes.
            if let firstURL = post.mediaURL {
                let allURLs = ([firstURL] + extraMedia).compactMap { URL(string: $0) }
                if allURLs.count > 1 {
                    ZStack(alignment: .topTrailing) {
                        TabView {
                            ForEach(allURLs, id: \.self) { url in
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.15))
                                }
                                .frame(height: 220)
                                .clipped()
                                .onTapGesture { fullScreenURL = url }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .frame(height: 220)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if let url = allURLs.first {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.15))
                    }
                    .frame(height: 220)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp:
                    // no había forma de tocar la imagen para verla a tamaño
                    // completo, solo el recorte fijo de 220pt.
                    .onTapGesture { fullScreenURL = url }
                }
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
                // versión Kotlin equivalente. @menciones reales
                // (0073_profile_username.sql + 0074_mentions.sql) añadidas
                // en esta misma pasada, comparado con Instagram/Twitter/
                // TikTok.
                MentionHashtagText(
                    text: caption,
                    onOpenHashtag: onOpenHashtag,
                    onOpenMention: { username in
                        Task { mentionProfileID = await MentionResolver.resolveProfileID(username: username) }
                    }
                )
            }
            Text(relativeTime(post.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                // Ocultar el número de "me gusta" real, comparado con
                // Instagram/Facebook -- el propio autor sigue viendo su
                // cifra real siempre, solo desaparece para los demás. Ver
                // 0094_hide_like_count.sql.
                let showLikeCount = !post.hideLikeCount || post.authorID == myID
                Button(action: onLike) {
                    if showLikeCount {
                        Label("\(post.likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                    } else {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                    }
                }
                .foregroundStyle(isLiked ? .red : .primary)
                Button {
                    showComments = true
                } label: {
                    Label("\(post.commentCount)", systemImage: "bubble.right")
                }
                Spacer()
                // Hallazgo real, comparado con Instagram/TikTok/Twitter/
                // Snapchat: en las cuatro apps, este icono abre un
                // selector interno de a quién enviar (un chat, un grupo)
                // -- el mecanismo de distribución más usado, más que el
                // share sheet externo. Antes solo abría ShareLink (share
                // sheet nativo), que ahora vive dentro del propio
                // selector como opción secundaria (SendPostView.swift).
                Button {
                    showSendSheet = true
                } label: {
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
                // Hallazgo real, comparado con Instagram/TikTok/Facebook:
                // antes esto era un texto libre editable; ahora una
                // referencia real (0045_reports_content_reference.sql).
                ReportSheet(userID: myID, reportedID: post.authorID, postID: post.id)
            }
        }
        .sheet(isPresented: $showSendSheet) {
            SendPostView(
                postID: post.id,
                shareText: post.caption.map { "Mira esto en SOCIAL: \($0)" } ?? "Mira esto en SOCIAL",
                onDismiss: { showSendSheet = false }
            )
        }
        // Mismo patrón Binding(get:set:) ya usado en HomeView.swift para
        // un URL? no Identifiable.
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenURL != nil },
            set: { isPresented in if !isPresented { fullScreenURL = nil } }
        )) {
            if let fullScreenURL {
                FullScreenImageView(url: fullScreenURL, onDismiss: { self.fullScreenURL = nil })
            }
        }
        // Mismo patrón `isPresented:` compatible con iOS 16 ya usado en
        // HomeView.swift para `hashtagToOpen` -- `navigationDestination(item:)`
        // exige iOS 17+, y el objetivo de despliegue de este proyecto es 16.0.
        .navigationDestination(isPresented: Binding(
            get: { mentionProfileID != nil },
            set: { isPresented in if !isPresented { mentionProfileID = nil } }
        )) {
            if let mentionProfileID {
                ProfileViewerView(profileID: mentionProfileID)
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
