//
//  ReelCommentsViewModel.swift
//  Social
//
//  Comentarios de un reel -- hueco real documentado explícitamente al
//  construir la UI de Reels: `reel_comments` (0050_reels.sql) ya existe con
//  su propio contador (`reels.comment_count`, ya visible en ReelsView.swift),
//  pero sin ninguna pantalla para leerlos o escribirlos. Mismo patrón
//  exacto que CommentsViewModel.swift (posts), solo cambia la tabla/columna.
//  Equivalente de ReelCommentsViewModel.kt.
//

import Foundation

struct ReelComment: Identifiable, Decodable {
    let id: UUID
    let reel_id: UUID
    let author_id: UUID
    let body: String
    let created_at: String
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto de un reel (0054_comment_likes.sql).
    var like_count: Int = 0
}

@MainActor
final class ReelCommentsViewModel: ObservableObject {

    let reelID: UUID

    @Published var comments: [ReelComment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authorProfiles: [UUID: Profile] = [:]
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto de un reel (0054_comment_likes.sql), mismo patrón que
    // CommentsViewModel.likedCommentIDs (posts).
    @Published var likedCommentIDs: Set<UUID> = []

    init(reelID: UUID) {
        self.reelID = reelID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: [ReelComment] = try await SupabaseManager.shared.client
                .from("reel_comments")
                .select()
                .eq("reel_id", value: reelID)
                .order("created_at", ascending: true)
                .execute()
                .value
            comments = loaded

            let authorIDs = Array(Set(loaded.map { $0.author_id }))
            if !authorIDs.isEmpty,
               let authors: [Profile] = try? await SupabaseManager.shared.client
                   .from("profiles")
                   .select()
                   .in("id", values: authorIDs)
                   .execute()
                   .value {
                authorProfiles = Dictionary(uniqueKeysWithValues: authors.map { ($0.id, $0) })
            }

            if let userID = try? await SupabaseManager.shared.client.auth.session.user.id {
                struct LikedReelCommentRow: Decodable { let reel_comment_id: UUID }
                let commentIDs = loaded.map { $0.id }
                if !commentIDs.isEmpty,
                   let likedRows: [LikedReelCommentRow] = try? await SupabaseManager.shared.client
                       .from("reel_comment_likes")
                       .select("reel_comment_id")
                       .eq("user_id", value: userID)
                       .in("reel_comment_id", values: commentIDs)
                       .execute()
                       .value {
                    likedCommentIDs = Set(likedRows.map { $0.reel_comment_id })
                }
            }
        } catch {
            errorMessage = "No se pudieron cargar los comentarios: \(error.localizedDescription)"
        }
    }

    /// Toggle real de like/unlike de un comentario de reel -- mismo patrón
    /// exacto que CommentsViewModel.toggleCommentLike() (posts).
    func toggleCommentLike(_ comment: ReelComment) async {
        let currentlyLiked = likedCommentIDs.contains(comment.id)
        if currentlyLiked {
            likedCommentIDs.remove(comment.id)
        } else {
            likedCommentIDs.insert(comment.id)
        }
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index].like_count = max(0, comments[index].like_count + (currentlyLiked ? -1 : 1))
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewReelCommentLike: Encodable {
            let reel_comment_id: UUID
            let user_id: UUID
        }
        do {
            if currentlyLiked {
                try await SupabaseManager.shared.client
                    .from("reel_comment_likes")
                    .delete()
                    .eq("reel_comment_id", value: comment.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("reel_comment_likes")
                    .insert(NewReelCommentLike(reel_comment_id: comment.id, user_id: userID))
                    .execute()
                AnalyticsManager.track("reel_comment_liked")
            }
        } catch {
            // Mismo criterio que CommentsViewModel.toggleCommentLike(): un
            // 409 por unique(reel_comment_id, user_id) no es un error
            // real, el estado deseado ya se cumple.
        }
    }

    struct NewReelComment: Encodable {
        let reel_id: UUID
        let author_id: UUID
        let body: String
    }

    func addComment(_ text: String, onCommentAdded: @escaping () -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Mismo límite real que comments_body_length, reutilizado tal cual
        // para reel_comments (0050_reels.sql no define uno propio
        // distinto -- mismo esquema de columna `body text not null`).
        guard trimmed.count <= 500 else {
            errorMessage = "El comentario no puede tener más de 500 caracteres."
            return
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let inserted: ReelComment = try await SupabaseManager.shared.client
                .from("reel_comments")
                .insert(NewReelComment(reel_id: reelID, author_id: userID, body: trimmed))
                .select()
                .single()
                .execute()
                .value
            comments.append(inserted)
            if authorProfiles[userID] == nil {
                if let me: Profile = try? await SupabaseManager.shared.client
                    .from("profiles")
                    .select()
                    .eq("id", value: userID)
                    .single()
                    .execute()
                    .value {
                    authorProfiles[userID] = me
                }
            }
            AnalyticsManager.track("reel_comment_added")
            onCommentAdded()
        } catch {
            errorMessage = "No se pudo publicar el comentario."
        }
    }

    func deleteComment(_ comment: ReelComment, onCommentRemoved: @escaping () -> Void) async {
        comments.removeAll { $0.id == comment.id }
        do {
            try await SupabaseManager.shared.client
                .from("reel_comments")
                .delete()
                .eq("id", value: comment.id)
                .execute()
            onCommentRemoved()
        } catch {
            errorMessage = "No se pudo borrar el comentario."
        }
    }
}
