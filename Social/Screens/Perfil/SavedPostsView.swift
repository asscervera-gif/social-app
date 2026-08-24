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

@MainActor
final class SavedPostsViewModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var errorMessage: String?

    private struct SavedPostRow: Decodable {
        let posts: Post?
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
                .select("created_at,posts(*)")
                .eq("user_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
            posts = rows.compactMap { $0.posts }.filter { !blockedIDs.contains($0.authorID) }
        } catch {
            errorMessage = "No se pudieron cargar tus guardados."
        }
    }

    /// Quitar de guardados desde esta misma lista — sin esto, la única
    /// forma de "deshacer" sería volver a encontrar el post en el feed.
    func unsave(_ post: Post) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        posts.removeAll { $0.id == post.id }
        do {
            try await SupabaseManager.shared.client
                .from("saved_posts")
                .delete()
                .eq("user_id", value: userID)
                .eq("post_id", value: post.id)
                .execute()
        } catch {
            errorMessage = "No se pudo quitar de guardados."
        }
    }
}

struct SavedPostsView: View {
    @StateObject private var viewModel = SavedPostsViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.posts.isEmpty {
                Text("Todavía no has guardado ninguna publicación.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.posts) { post in
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.caption ?? "")
                    Text("❤ \(post.likeCount) · 💬 \(post.commentCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Quitar", role: .destructive) {
                        Task { await viewModel.unsave(post) }
                    }
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
    }
}
