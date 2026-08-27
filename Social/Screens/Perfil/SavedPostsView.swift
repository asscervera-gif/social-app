//
//  SavedPostsView.swift
//  Social
//
//  "Guardados" — hallazgo real: `HomeViewModel.toggleSave()` (icono de
//  marcador en PostCard) lleva desde hace varias pasadas guardando de
//  verdad en `saved_posts`, pero no existía NINGUNA pantalla en ninguna
//  plataforma para ver lo guardado — comparado con la colección
//  "Guardado" real de Instagram. Equivalente de MyPostsView.swift: mismo
//  patrón, distinta fuente (`saved_posts` embebiendo `posts(*)` vía
//  PostgREST, mismo criterio ya usado en EventModeViewModel.swift con
//  `profiles(*)`). Sin verificación de compilador real (límite de
//  plataforma) — mismo nivel de confianza que el resto de cambios iOS de
//  la sesión.
//

import Foundation
import SwiftUI

/// Colecciones reales para publicaciones guardadas, comparado con
/// Instagram -- ver 0125_saved_post_collections.sql. `savedID` (id de la
/// propia fila saved_posts, no del post) hace falta para poder cambiar
/// de colección/quitar de guardados sin depender de post_id+user_id
/// como clave compuesta en cada llamada. Equivalente de SavedItem (Kotlin).
struct SavedItem: Identifiable {
    let savedID: UUID
    let post: Post
    var collectionName: String?
    var id: UUID { savedID }
}

@MainActor
final class SavedPostsViewModel: ObservableObject {
    @Published var posts: [SavedItem] = []
    @Published var errorMessage: String?
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed y en
    // comentarios (HomeViewModel/CommentsViewModel.authorProfiles): esta
    // lista tampoco mostraba QUIÉN escribió cada post guardado -- ni
    // siquiera la imagen, comparado con la colección "Guardado" real de
    // Instagram.
    @Published var authorProfiles: [UUID: Profile] = [:]

    private struct SavedPostRow: Decodable {
        let id: UUID
        let posts: Post?
        let collection_name: String?
    }

    private struct BlockRow: Decodable { let blocked_id: UUID }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            // Mismo refuerzo de privacidad ya aplicado en Home/Match/Find/
            // Search/ChatList: no mostrar contenido de gente bloqueada,
            // aquí aplicado a la lista de guardados. Mismo fix ya
            // construido en la versión Kotlin equivalente.
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }
            let rows: [SavedPostRow] = try await SupabaseManager.shared.client
                .from("saved_posts")
                .select("id,created_at,collection_name,posts(*)")
                .eq("user_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
            let loaded = rows.compactMap { row -> SavedItem? in
                guard let post = row.posts else { return nil }
                return SavedItem(savedID: row.id, post: post, collectionName: row.collection_name)
            }.filter { !blockedIDs.contains($0.post.authorID) }
            posts = loaded

            let authorIDs = Array(Set(loaded.map { $0.post.authorID }))
            if !authorIDs.isEmpty,
               let authors: [Profile] = try? await SupabaseManager.shared.client
                   .from("profiles")
                   .select()
                   .in("id", values: authorIDs)
                   .execute()
                   .value {
                authorProfiles = Dictionary(uniqueKeysWithValues: authors.map { ($0.id, $0) })
            }
        } catch {
            errorMessage = "No se pudieron cargar tus guardados."
        }
    }

    /// Quitar de guardados desde esta misma lista — sin esto, la única
    /// forma de "deshacer" sería volver a encontrar el post en el feed.
    func unsave(_ item: SavedItem) async {
        posts.removeAll { $0.savedID == item.savedID }
        do {
            try await SupabaseManager.shared.client
                .from("saved_posts")
                .delete()
                .eq("id", value: item.savedID)
                .execute()
        } catch {
            errorMessage = "No se pudo quitar de guardados."
        }
    }

    /// Mover un guardado real a otra colección (o quitarlo de todas con
    /// `nil`), comparado con Instagram -- ver
    /// 0125_saved_post_collections.sql (`saved_posts_update_own`,
    /// primera política UPDATE real sobre esta tabla). Equivalente de
    /// SavedPostsViewModel.kt.setCollection().
    func setCollection(_ item: SavedItem, to collectionName: String?) async {
        let trimmed = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(50))
        if let index = posts.firstIndex(where: { $0.savedID == item.savedID }) {
            posts[index].collectionName = finalName
        }
        do {
            try await SupabaseManager.shared.client
                .from("saved_posts")
                .update(["collection_name": finalName])
                .eq("id", value: item.savedID)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar la colección."
            await load()
        }
    }
}

struct SavedPostsView: View {
    @StateObject private var viewModel = SavedPostsViewModel()
    // Hallazgo real, mismo hueco ya cerrado en el feed y el chat: no
    // había forma de tocar la imagen para verla a tamaño completo.
    @State private var fullScreenURL: URL?
    // Colecciones reales para publicaciones guardadas, comparado con
    // Instagram -- ver SavedPostsViewModel.setCollection(),
    // 0125_saved_post_collections.sql.
    @State private var selectedCollection: String?
    @State private var movingItem: SavedItem?
    @State private var moveDraft = ""

    private var collections: [String] {
        Array(Set(viewModel.posts.compactMap { $0.collectionName })).sorted()
    }

    private var visiblePosts: [SavedItem] {
        guard let selectedCollection else { return viewModel.posts }
        return viewModel.posts.filter { $0.collectionName == selectedCollection }
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.posts.isEmpty {
                Text("Todavía no has guardado ninguna publicación.")
                    .foregroundStyle(.secondary)
            }
            // Colecciones reales, comparado con Instagram -- fila de
            // chips para filtrar, "Todo" siempre primero (bandeja
            // general, incluye lo sin colección también).
            if !collections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("Todo") { selectedCollection = nil }
                            .buttonStyle(.bordered)
                            .tint(selectedCollection == nil ? .accentColor : .secondary)
                        ForEach(collections, id: \.self) { name in
                            Button(name) { selectedCollection = name }
                                .buttonStyle(.bordered)
                                .tint(selectedCollection == name ? .accentColor : .secondary)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(visiblePosts) { item in
                let post = item.post
                VStack(alignment: .leading, spacing: 4) {
                    // Hallazgo real, mismo hueco raíz ya cerrado en el
                    // feed y en comentarios: esta lista tampoco mostraba
                    // QUIÉN escribió cada post guardado, ni su imagen.
                    NavigationLink {
                        ProfileViewerView(profileID: post.authorID)
                    } label: {
                        HStack(spacing: 6) {
                            ActiveAvatarProvider.shared.avatarView(
                                config: viewModel.authorProfiles[post.authorID]?.avatarConfig ?? [:],
                                size: 24
                            )
                            Text(viewModel.authorProfiles[post.authorID]?.displayName ?? "…")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.plain)
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
                    // Colecciones reales, comparado con Instagram --
                    // etiqueta real cuando corresponde.
                    if let collectionName = item.collectionName {
                        Text("🗂 \(collectionName)")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("❤ \(post.likeCount) · 💬 \(post.commentCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Quitar", role: .destructive) {
                        Task { await viewModel.unsave(item) }
                    }
                    Button("Mover") {
                        movingItem = item
                        moveDraft = item.collectionName ?? ""
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Guardados")
        .task { await viewModel.load() }
        // Hallazgo real, mismo criterio ya aplicado en Home/Match/
        // ChatList: comparado con Instagram/Twitter/Facebook, esta
        // pantalla no tenía pull-to-refresh. Ya construido en la versión
        // Kotlin equivalente.
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
        // Colecciones reales, comparado con Instagram -- `.sheet` en vez
        // de `.alert`/`.confirmationDialog`: hace falta un `TextField`
        // propio, mismo hallazgo real ya documentado en
        // 0099_story_questions.sql.
        .sheet(item: $movingItem) { item in
            NavigationStack {
                Form {
                    TextField("Nombre (p. ej. \"Viajes\")", text: $moveDraft)
                }
                .navigationTitle("Mover a colección")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            Task { await viewModel.setCollection(item, to: moveDraft) }
                            movingItem = nil
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Quitar colección") {
                            Task { await viewModel.setCollection(item, to: nil) }
                            movingItem = nil
                        }
                    }
                }
            }
        }
    }
}
