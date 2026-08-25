//
//  MyPostsView.swift
//  Social
//
//  "Tus publicaciones" — antes un botón vacío (`{}`) en PerfilView.swift,
//  documentado como bloqueado por Supabase Storage igual que Reels/Pubs.
//  de socials/En directo. Ya no es cierto para el caso de texto: con
//  NewPostView (ver hallazgo en NewPostViewModel.swift), `posts.media_url`
//  opcional permite publicaciones reales sin Storage — este visor y el
//  borrado ya no dependen de esa infraestructura pendiente.
//

import SwiftUI

@MainActor
final class MyPostsViewModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var errorMessage: String?

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            posts = try await SupabaseManager.shared.client
                .from("posts")
                .select()
                .eq("author_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = "No se pudieron cargar tus publicaciones."
        }
    }

    /// `posts_write_own` (0002_rls.sql) es `for all`, así que borrar la
    /// propia publicación ya estaba permitido a nivel de RLS — solo
    /// faltaba el botón.
    func delete(_ post: Post) async {
        posts.removeAll { $0.id == post.id }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .delete()
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo borrar la publicación."
        }
    }
}

struct MyPostsView: View {
    @StateObject private var viewModel = MyPostsViewModel()
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    @State private var fullScreenURL: URL?

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.posts.isEmpty {
                Text("Todavía no has publicado nada.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.posts) { post in
                VStack(alignment: .leading, spacing: 4) {
                    // Hallazgo real, mismo hueco ya cerrado en Guardados:
                    // esta lista tampoco mostraba la imagen de la
                    // publicación, solo texto.
                    if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.15))
                        }
                        .frame(height: 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { fullScreenURL = url }
                    }
                    Text(post.caption ?? "")
                    Text("❤ \(post.likeCount) · 💬 \(post.commentCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Borrar", role: .destructive) {
                        Task { await viewModel.delete(post) }
                    }
                }
            }
        }
        .navigationTitle("Tus publicaciones")
        .task { await viewModel.load() }
        // Hallazgo real, mismo criterio ya aplicado en Home/Match/
        // ChatList/Guardados: comparado con Instagram/Twitter/Facebook,
        // esta pantalla no tenía pull-to-refresh. Ya construido en la
        // versión Kotlin equivalente.
        .refreshable { await viewModel.load() }
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
    }
}
