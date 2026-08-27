//
//  PostDetailView.swift
//  Social
//
//  Publicación individual real ("permalink"), comparado con Instagram/
//  Twitter/Facebook: ninguna de las dos apps tenía una pantalla que
//  mostrara UNA publicación fuera del feed -- ni el feed la tenía, ni
//  tocar un aviso de "like"/"comentario" llevaba a ningún sitio (tap
//  muerto, ver AvisosView.swift/AvisosViewModel.swift, a pesar de que
//  `notifications.payload.post_id` ya existe desde 0007/0008). Mismo
//  patrón de carga autocontenida ya usado en ProfileViewerView.swift (sin
//  ObservableObject propio) en vez de reutilizar HomeViewModel, que muta
//  su lista `feed` entera y no es reutilizable tal cual para un solo post.
//  Equivalente de PostDetailScreen.kt.
//

import SwiftUI

struct PostDetailView: View {
    let postID: UUID
    var onOpenProfile: ((UUID) -> Void)? = nil

    @State private var post: Post?
    @State private var author: Profile?
    @State private var extraMedia: [String] = []
    @State private var isLiked = false
    @State private var isSaved = false
    @State private var errorMessage: String?
    @State private var showComments = false
    @State private var fullScreenURL: URL?
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/Twitter/Facebook -- esta pantalla ni siquiera tenía
    // etiquetas tocables (a diferencia del feed, HomeView.swift.PostCard),
    // solo texto plano; se corrige de paso al construir el componente
    // compartido MentionHashtagText.swift.
    @State private var mentionProfileID: UUID?
    // Ocultar el número de "me gusta" real, comparado con Instagram/
    // Facebook -- ver 0094_hide_like_count.sql.
    @State private var myID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                if let post {
                    Group {
                        if let onOpenProfile {
                            Button { onOpenProfile(post.authorID) } label: { authorRow }
                                .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                ProfileViewerView(profileID: post.authorID)
                            } label: { authorRow }
                            .buttonStyle(.plain)
                        }
                    }

                    if let firstURL = post.mediaURL {
                        // Carrusel de varias fotos (post_media), mismo
                        // patrón exacto que HomeView.swift.PostCard.
                        let allURLs = ([firstURL] + extraMedia).compactMap { URL(string: $0) }
                        if allURLs.count > 1 {
                            TabView {
                                ForEach(allURLs, id: \.self) { url in
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.15))
                                    }
                                    .frame(height: 320)
                                    .clipped()
                                    .onTapGesture { fullScreenURL = url }
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else if let url = allURLs.first {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.15))
                            }
                            .frame(height: 320)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .onTapGesture { fullScreenURL = url }
                        }
                    }
                    if let caption = post.caption {
                        MentionHashtagText(
                            text: caption,
                            onOpenMention: { username in
                                Task {
                                    guard let id = await MentionResolver.resolveProfileID(username: username) else { return }
                                    if let onOpenProfile {
                                        onOpenProfile(id)
                                    } else {
                                        mentionProfileID = id
                                    }
                                }
                            }
                        )
                    }
                    Text(relativeTime(post.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        // Ocultar el número de "me gusta" real, comparado
                        // con Instagram/Facebook -- el propio autor sigue
                        // viendo su cifra real siempre, solo desaparece
                        // para los demás. Ver 0094_hide_like_count.sql.
                        let showLikeCount = !post.hideLikeCount || post.authorID == myID
                        Button { toggleLike() } label: {
                            if showLikeCount {
                                Label("\(post.likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                            } else {
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                            }
                        }
                        .foregroundStyle(isLiked ? .red : .primary)
                        Button { showComments = true } label: {
                            Label("\(post.commentCount)", systemImage: "bubble.right")
                        }
                        Spacer()
                        Button { toggleSave() } label: {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .navigationTitle("Publicación")
        .task { await load() }
        .sheet(isPresented: $showComments) {
            CommentsView(
                postID: postID,
                onCommentAdded: { post?.commentCount += 1 },
                onCommentRemoved: { post?.commentCount = max(0, (post?.commentCount ?? 1) - 1) }
            )
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenURL != nil },
            set: { isPresented in if !isPresented { fullScreenURL = nil } }
        )) {
            if let fullScreenURL {
                FullScreenImageView(url: fullScreenURL, onDismiss: { self.fullScreenURL = nil })
            }
        }
        // Solo aplica cuando `onOpenProfile` no viene dado (esta vista se
        // presenta sola, con su propio NavigationLink de autor) -- mismo
        // patrón `isPresented:` compatible con iOS 16 ya usado en
        // HomeView.swift.PostCard.
        .navigationDestination(isPresented: Binding(
            get: { mentionProfileID != nil },
            set: { isPresented in if !isPresented { mentionProfileID = nil } }
        )) {
            if let mentionProfileID {
                ProfileViewerView(profileID: mentionProfileID)
            }
        }
    }

    private var authorRow: some View {
        HStack(spacing: 8) {
            ActiveAvatarProvider.shared.avatarView(config: author?.avatarConfig ?? [:], size: 36)
            Text(author?.displayName ?? "…").font(.subheadline.bold()).foregroundStyle(.primary)
        }
    }

    private func load() async {
        do {
            let post: Post = try await SupabaseManager.shared.client
                .from("posts")
                .select()
                .eq("id", value: postID)
                .single()
                .execute()
                .value
            self.post = post

            author = try? await SupabaseManager.shared.client
                .from("profiles")
                .select()
                .eq("id", value: post.authorID)
                .single()
                .execute()
                .value

            // Carrusel de varias fotos (post_media), mismo patrón exacto
            // que HomeViewModel.swift.load().
            let media: [PostMedia] = (try? await SupabaseManager.shared.client
                .from("post_media")
                .select()
                .eq("post_id", value: postID)
                .order("position", ascending: true)
                .execute()
                .value) ?? []
            extraMedia = media.map { $0.mediaURL }

            if let userID = try? await SupabaseManager.shared.client.auth.session.user.id {
                myID = userID
                struct LikeRow: Decodable { let post_id: UUID }
                let likes: [LikeRow] = (try? await SupabaseManager.shared.client
                    .from("likes")
                    .select("post_id")
                    .eq("post_id", value: postID)
                    .eq("user_id", value: userID)
                    .execute()
                    .value) ?? []
                isLiked = !likes.isEmpty

                struct SavedRow: Decodable { let post_id: UUID }
                let saved: [SavedRow] = (try? await SupabaseManager.shared.client
                    .from("saved_posts")
                    .select("post_id")
                    .eq("post_id", value: postID)
                    .eq("user_id", value: userID)
                    .execute()
                    .value) ?? []
                isSaved = !saved.isEmpty
            }
        } catch {
            errorMessage = "No se pudo cargar la publicación."
        }
    }

    /// Mismo criterio exacto que HomeViewModel.swift.toggleLike(), operando
    /// sobre `post` en vez de una lista completa.
    private func toggleLike() {
        guard let current = post else { return }
        let currentlyLiked = isLiked
        isLiked.toggle()
        post?.likeCount = max(0, current.likeCount + (currentlyLiked ? -1 : 1))
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                if currentlyLiked {
                    try await SupabaseManager.shared.client
                        .from("likes")
                        .delete()
                        .eq("post_id", value: current.id)
                        .eq("user_id", value: userID)
                        .execute()
                } else {
                    struct NewLike: Encodable { let post_id: UUID; let user_id: UUID }
                    try await SupabaseManager.shared.client
                        .from("likes")
                        .insert(NewLike(post_id: current.id, user_id: userID))
                        .execute()
                    AnalyticsManager.track("post_liked")
                }
            } catch {
                // Restricción unique(post_id, user_id): el estado deseado ya
                // se cumple, mismo criterio que HomeViewModel.swift.toggleLike().
            }
        }
    }

    private func toggleSave() {
        guard let current = post else { return }
        let currentlySaved = isSaved
        isSaved.toggle()
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                if currentlySaved {
                    try await SupabaseManager.shared.client
                        .from("saved_posts")
                        .delete()
                        .eq("post_id", value: current.id)
                        .eq("user_id", value: userID)
                        .execute()
                } else {
                    struct NewSavedPost: Encodable { let post_id: UUID; let user_id: UUID }
                    try await SupabaseManager.shared.client
                        .from("saved_posts")
                        .insert(NewSavedPost(post_id: current.id, user_id: userID))
                        .execute()
                    AnalyticsManager.track("post_saved")
                }
            } catch {
                // Restricción unique(post_id, user_id): el estado deseado ya
                // se cumple, mismo criterio que HomeViewModel.swift.toggleSave().
            }
        }
    }
}

/// Hora relativa ("hace 2h", "3d") -- duplicado de HomeView.swift.relativeTime()
/// a propósito, no compartido: esa función es `private` a su propio
/// archivo, mismo criterio ya usado en GroupAudioMessageBubble
/// (GroupChatView.swift).
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
