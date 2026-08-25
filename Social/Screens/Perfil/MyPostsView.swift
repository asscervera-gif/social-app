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

    /// Hallazgo real, comparado con Instagram: no había forma de editar el
    /// caption de una publicación ya hecha, solo borrarla entera --
    /// `posts_write_own` (0002_rls.sql) ya es `for all`, así que editar la
    /// propia publicación ya estaba permitido a nivel de RLS, solo faltaba
    /// el botón. Mismo límite real que `posts_caption_length`
    /// (0023_text_length_limits.sql, 2200 caracteres). Equivalente de
    /// MyPostsViewModel.kt.editCaption().
    func editCaption(_ post: Post, newCaption: String) async {
        guard newCaption.count <= 2200 else {
            errorMessage = "El texto no puede tener más de 2200 caracteres."
            return
        }
        let trimmed = newCaption.isEmpty ? nil : newCaption
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].caption = trimmed
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["caption": trimmed])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo editar la publicación."
            await load()
        }
    }
}

struct MyPostsView: View {
    @StateObject private var viewModel = MyPostsViewModel()
    // Hallazgo real, comparado con SOCIAL_APP.html ("Pubs de socials",
    // etiqueta "con Marta"): no había forma de ver solo las publicaciones
    // hechas CON un social -- 0051_post_social_tags.sql. Reutiliza la
    // misma lista de socials aceptados que NewPostView.swift ya usa para
    // etiquetar, para resolver el nombre real de la persona etiquetada.
    @StateObject private var socialsViewModel = SocialsListViewModel()
    @State private var showOnlyTagged = false
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    @State private var fullScreenURL: URL?
    // Hallazgo real, comparado con Instagram: no había forma de editar el
    // caption de una publicación ya hecha, solo borrarla entera.
    @State private var editingPost: Post?
    @State private var editedCaption = ""

    private var visiblePosts: [Post] {
        showOnlyTagged ? viewModel.posts.filter { $0.taggedProfileID != nil } : viewModel.posts
    }

    private func taggedName(_ id: UUID) -> String {
        socialsViewModel.socials.first { $0.id == id }?.displayName ?? "alguien"
    }

    var body: some View {
        List {
            Picker("", selection: $showOnlyTagged) {
                Text("Todas").tag(false)
                Text("Con tus socials").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if visiblePosts.isEmpty {
                Text(showOnlyTagged ? "Ninguna publicación etiquetada con un social todavía." : "Todavía no has publicado nada.")
                    .foregroundStyle(.secondary)
            }
            ForEach(visiblePosts) { post in
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
                    if let taggedProfileID = post.taggedProfileID {
                        Text("con \(taggedName(taggedProfileID))")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    Text("❤ \(post.likeCount) · 💬 \(post.commentCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Borrar", role: .destructive) {
                        Task { await viewModel.delete(post) }
                    }
                    Button("Editar") {
                        editingPost = post
                        editedCaption = post.caption ?? ""
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Tus publicaciones")
        .task { await viewModel.load() }
        .task { await socialsViewModel.load() }
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
        .sheet(item: $editingPost) { post in
            NavigationStack {
                Form {
                    TextField("Descripción", text: $editedCaption, axis: .vertical)
                    Text("\(editedCaption.count)/2200")
                        .font(.caption2)
                        .foregroundStyle(editedCaption.count > 2200 ? .red : .secondary)
                }
                .navigationTitle("Editar publicación")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            Task {
                                await viewModel.editCaption(post, newCaption: editedCaption)
                                editingPost = nil
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { editingPost = nil }
                    }
                }
            }
        }
    }
}
