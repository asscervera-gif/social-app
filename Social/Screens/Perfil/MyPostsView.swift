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

    /// Archivar publicaciones real (0076_archive_posts.sql), comparado
    /// con Instagram/Facebook: antes o se dejaba visible para siempre o
    /// se borraba para siempre, sin término medio -- `posts_write_own`
    /// (0002_rls.sql) ya es `for all`, así que archivar/restaurar ya
    /// estaba permitido a nivel de RLS, solo faltaba el botón y la
    /// columna. Equivalente de MyPostsViewModel.kt.toggleArchive().
    func toggleArchive(_ post: Post) async {
        let isCurrentlyArchived = post.archivedAt != nil
        let newArchivedAt = isCurrentlyArchived ? nil : ISO8601DateFormatter().string(from: Date())
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].archivedAt = newArchivedAt
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["archived_at": newArchivedAt])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo actualizar el archivo."
            await load()
        }
    }

    /// Desactivar los comentarios de una publicación real, comparado con
    /// Instagram/TikTok -- los comentarios que ya existían se quedan tal
    /// cual, solo se cierra la puerta a comentarios NUEVOS
    /// (`comments_insert_own`, 0086_disable_comments.sql, lo garantiza
    /// también del lado del servidor). `posts_write_own` ya es `for all`,
    /// mismo criterio que toggleArchive(): sin política RLS nueva.
    /// Equivalente de MyPostsViewModel.kt.toggleCommentsDisabled().
    func toggleCommentsDisabled(_ post: Post) async {
        let newValue = !post.commentsDisabled
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].commentsDisabled = newValue
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["comments_disabled": newValue])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar el estado de los comentarios."
            await load()
        }
    }

    /// Ocultar el número de "me gusta" real, comparado con Instagram/
    /// Facebook -- el propio autor sigue viendo su cifra real siempre,
    /// solo desaparece para los demás (0094_hide_like_count.sql).
    /// Equivalente de MyPostsViewModel.kt.toggleHideLikeCount().
    func toggleHideLikeCount(_ post: Post) async {
        let newValue = !post.hideLikeCount
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].hideLikeCount = newValue
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["hide_like_count": newValue])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar la visibilidad del número de me gusta."
            await load()
        }
    }

    /// Marcar contenido como sensible, comparado con Instagram/Twitter/
    /// TikTok -- ver 0096_sensitive_content.sql. Equivalente de
    /// MyPostsViewModel.kt.toggleSensitive().
    func toggleSensitive(_ post: Post) async {
        let newValue = !post.isSensitive
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].isSensitive = newValue
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["is_sensitive": newValue])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar la marca de contenido sensible."
            await load()
        }
    }

    /// "¿Quién puede comentar?" real, comparado con Twitter/X/TikTok --
    /// ver 0097_reply_audience.sql. Equivalente de
    /// MyPostsViewModel.kt.cycleReplyAudience().
    func cycleReplyAudience(_ post: Post) async {
        let newValue: String
        switch post.replyAudience {
        case "everyone": newValue = "followers"
        case "followers": newValue = "mentioned"
        default: newValue = "everyone"
        }
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].replyAudience = newValue
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["reply_audience": newValue])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar quién puede comentar."
            await load()
        }
    }

    /// Fijar/desfijar una publicación real en el perfil (hasta 3),
    /// comparado con Instagram -- `posts_write_own` ya es "for all",
    /// mismo criterio que toggleArchive()/toggleSensitive(): sin
    /// política RLS nueva. El límite real de 3 lo impone
    /// `trg_limit_pinned_posts` (0106_pin_posts_to_profile.sql) del lado
    /// del servidor -- si ya hay 3 fijadas, el UPDATE real falla y aquí
    /// se revierte el optimismo y se avisa con un mensaje real, no
    /// genérico. Equivalente de MyPostsViewModel.kt.togglePinned().
    func togglePinned(_ post: Post) async {
        let isCurrentlyPinned = post.pinnedAt != nil
        let newPinnedAt = isCurrentlyPinned ? nil : ISO8601DateFormatter().string(from: Date())
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].pinnedAt = newPinnedAt
        }
        do {
            try await SupabaseManager.shared.client
                .from("posts")
                .update(["pinned_at": newPinnedAt])
                .eq("id", value: post.id)
                .execute()
        } catch {
            errorMessage = isCurrentlyPinned ? "No se pudo desfijar la publicación." : "Ya tienes 3 publicaciones fijadas -- quita una antes de fijar otra."
            await load()
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
    // "Pubs. de socials" (PerfilView.swift) abre esta misma pantalla ya
    // filtrada en vez de duplicarla -- por defecto "Tus publicaciones"
    // sigue mostrando todas. Tercera pestaña "Archivadas"
    // (0076_archive_posts.sql), comparado con Instagram/Facebook.
    private enum PostsTab: Hashable {
        case all, tagged, archived
    }
    @State private var selectedTab: PostsTab

    init(initialTaggedOnly: Bool = false) {
        _selectedTab = State(initialValue: initialTaggedOnly ? .tagged : .all)
    }
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    @State private var fullScreenURL: URL?
    // Hallazgo real, comparado con Instagram: no había forma de editar el
    // caption de una publicación ya hecha, solo borrarla entera.
    @State private var editingPost: Post?
    @State private var editedCaption = ""

    // Las dos primeras excluyen las archivadas (mismo criterio que
    // Instagram: el archivo es un sitio aparte, no una publicación más
    // mezclada con el resto), la última solo las archivadas.
    private var visiblePosts: [Post] {
        switch selectedTab {
        case .all:
            // Fijar una publicación en el perfil (hasta 3), comparado
            // con Instagram -- las fijadas van siempre primero (la más
            // reciente fijada primero, no la más reciente publicada),
            // igual que la rejilla real del perfil; el resto sigue en
            // el mismo orden por fecha de siempre.
            let active = viewModel.posts.filter { $0.archivedAt == nil }
            let pinned = active.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? "") > ($1.pinnedAt ?? "") }
            let unpinned = active.filter { $0.pinnedAt == nil }
            return pinned + unpinned
        case .tagged: return viewModel.posts.filter { $0.archivedAt == nil && $0.taggedProfileID != nil }
        case .archived: return viewModel.posts.filter { $0.archivedAt != nil }
        }
    }

    private var emptyStateText: String {
        switch selectedTab {
        case .tagged: return "Ninguna publicación etiquetada con un social todavía."
        case .archived: return "No tienes ninguna publicación archivada."
        case .all: return "Todavía no has publicado nada."
        }
    }

    private func taggedName(_ id: UUID) -> String {
        socialsViewModel.socials.first { $0.id == id }?.displayName ?? "alguien"
    }

    var body: some View {
        List {
            Picker("", selection: $selectedTab) {
                Text("Todas").tag(PostsTab.all)
                Text("Con tus socials").tag(PostsTab.tagged)
                Text("Archivadas").tag(PostsTab.archived)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if visiblePosts.isEmpty {
                Text(emptyStateText).foregroundStyle(.secondary)
            }
            ForEach(visiblePosts) { post in
                // "¿Quién puede comentar?" real, comparado con Twitter/X/
                // TikTok -- calculado aparte para no anidar un switch
                // dentro del propio Button (mismo motivo real ya
                // documentado en ReelsView.swift: el compilador de Swift
                // real puede tardar demasiado en type-checkear una
                // expresión compleja inlineada dentro de un ViewBuilder).
                let audienceLabel: String = {
                    switch post.replyAudience {
                    case "followers": return "quienes sigo"
                    case "mentioned": return "a quien mencione"
                    default: return "todos"
                    }
                }()
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
                    // Fijar una publicación en el perfil, comparado con
                    // Instagram -- el propio icono ya comunica el
                    // estado, mismo criterio que "Fijado" en mensajes/
                    // comentarios.
                    if post.pinnedAt != nil {
                        Text("📌 Fijada").font(.caption.bold()).foregroundStyle(.accentColor)
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
                    // Fijar una publicación en el perfil (hasta 3),
                    // comparado con Instagram -- ver
                    // MyPostsViewModel.togglePinned(),
                    // 0106_pin_posts_to_profile.sql.
                    Button(post.pinnedAt != nil ? "Desfijar" : "Fijar") {
                        Task { await viewModel.togglePinned(post) }
                    }
                    .tint(.yellow)
                    // Archivar publicaciones real
                    // (0076_archive_posts.sql), comparado con Instagram/
                    // Facebook -- antes o se dejaba visible para siempre o
                    // se borraba para siempre, sin término medio.
                    Button(post.archivedAt != nil ? "Desarchivar" : "Archivar") {
                        Task { await viewModel.toggleArchive(post) }
                    }
                    .tint(.gray)
                    // Desactivar los comentarios de esta publicación real,
                    // comparado con Instagram/TikTok -- los comentarios
                    // previos se quedan, solo se cierra la puerta a
                    // comentarios nuevos (0086_disable_comments.sql).
                    Button(post.commentsDisabled ? "Activar comentarios" : "Desactivar comentarios") {
                        Task { await viewModel.toggleCommentsDisabled(post) }
                    }
                    .tint(.indigo)
                    // Ocultar el número de "me gusta" real, comparado con
                    // Instagram/Facebook -- el propio autor sigue viendo
                    // su cifra real siempre, solo desaparece para los
                    // demás. Ver 0094_hide_like_count.sql.
                    Button(post.hideLikeCount ? "Mostrar número de me gusta" : "Ocultar número de me gusta") {
                        Task { await viewModel.toggleHideLikeCount(post) }
                    }
                    .tint(.purple)
                    // Marcar contenido como sensible, comparado con
                    // Instagram/Twitter/TikTok -- ver
                    // 0096_sensitive_content.sql.
                    Button(post.isSensitive ? "Quitar aviso de sensible" : "Marcar como sensible") {
                        Task { await viewModel.toggleSensitive(post) }
                    }
                    .tint(.orange)
                    // "¿Quién puede comentar?" real, comparado con
                    // Twitter/X/TikTok -- ver 0097_reply_audience.sql.
                    Button("Comentan: \(audienceLabel)") {
                        Task { await viewModel.cycleReplyAudience(post) }
                    }
                    .tint(.teal)
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
