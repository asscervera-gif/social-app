//
//  CommentsViewModel.swift
//  Social
//
//  Comentarios de un post — pieza que faltaba del hueco documentado en
//  LOOP_STATE.md: `posts.comment_count` existía como columna y se mostraba
//  en el feed, pero no había tabla `comments` ni forma de escribir uno.
//  Mismo patrón que HomeViewModel.like(): persistencia real (ver
//  0008_comments.sql, que mantiene posts.comment_count sincronizado con
//  un trigger). Equivalente de CommentsViewModel.kt.
//

import Foundation

struct Comment: Identifiable, Decodable {
    let id: UUID
    let post_id: UUID
    let author_id: UUID
    let body: String
    let created_at: String
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto, no solo a la publicación entera (0054_comment_likes.sql).
    var like_count: Int = 0
    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real de la publicación puede cambiarlo (0084_pin_comments.sql).
    var is_pinned: Bool = false
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- referencia al comentario
    // real de primer nivel que se responde. Ver 0104_comment_replies.sql.
    var parent_comment_id: UUID? = nil
}

@MainActor
final class CommentsViewModel: ObservableObject {

    let postID: UUID

    @Published var comments: [Comment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Hallazgo real, mismo hueco raíz que HomeViewModel.authorProfiles
    // (pasada anterior): la hoja de comentarios nunca mostraba QUIÉN
    // escribió cada uno -- ni nombre, ni avatar, comparado con cualquier
    // app grande. `comments` no lleva el perfil embebido, se resuelve
    // aparte con un solo select por los author_id distintos.
    @Published var authorProfiles: [UUID: Profile] = [:]
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto (0054_comment_likes.sql) -- mismo patrón que
    // HomeViewModel.likedPostIDs, aquí a nivel de comentario individual.
    @Published var likedCommentIDs: Set<UUID> = []
    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real de la publicación puede fijar/desfijar
    // (0084_pin_comments.sql), la propia hoja necesita saber quién es para
    // mostrar el botón solo a esa persona. `comments` no trae el autor de
    // la publicación embebido, se resuelve aparte con un solo select,
    // mismo criterio que authorProfiles.
    @Published var postAuthorID: UUID?
    // Desactivar los comentarios de una publicación, comparado con
    // Instagram/TikTok -- la propia hoja necesita saberlo para ocultar el
    // campo de escribir uno nuevo (0086_disable_comments.sql, el servidor
    // ya lo garantiza en RLS de todas formas).
    @Published var commentsDisabled = false

    init(postID: UUID) {
        self.postID = postID
    }

    /// Responder a un comentario concreto (hilo de un nivel), comparado
    /// con Instagram/Facebook/Twitter/TikTok -- cada comentario de primer
    /// nivel (fijados primero, mismo orden real de siempre) va seguido de
    /// verdad por sus propias respuestas, en orden cronológico. Ver
    /// 0104_comment_replies.sql. Equivalente de
    /// CommentsViewModel.kt.threadOrder().
    private func threadOrder(_ list: [Comment]) -> [Comment] {
        let topLevel = list.filter { $0.parent_comment_id == nil }.sorted { lhs, rhs in
            if lhs.is_pinned != rhs.is_pinned { return lhs.is_pinned }
            return lhs.created_at < rhs.created_at
        }
        let repliesByParent = Dictionary(grouping: list.filter { $0.parent_comment_id != nil }) { $0.parent_comment_id }
        return topLevel.flatMap { parent in
            [parent] + (repliesByParent[parent.id] ?? []).sorted { $0.created_at < $1.created_at }
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: [Comment] = try await SupabaseManager.shared.client
                .from("comments")
                .select()
                .eq("post_id", value: postID)
                .order("created_at", ascending: true)
                .execute()
                .value
            comments = threadOrder(loaded)

            struct PostAuthorRow: Decodable { let author_id: UUID; let comments_disabled: Bool }
            if let row: PostAuthorRow = try? await SupabaseManager.shared.client
                .from("posts")
                .select("author_id,comments_disabled")
                .eq("id", value: postID)
                .single()
                .execute()
                .value {
                postAuthorID = row.author_id
                commentsDisabled = row.comments_disabled
            }

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
                struct LikedCommentRow: Decodable { let comment_id: UUID }
                let commentIDs = loaded.map { $0.id }
                if !commentIDs.isEmpty,
                   let likedRows: [LikedCommentRow] = try? await SupabaseManager.shared.client
                       .from("comment_likes")
                       .select("comment_id")
                       .eq("user_id", value: userID)
                       .in("comment_id", values: commentIDs)
                       .execute()
                       .value {
                    likedCommentIDs = Set(likedRows.map { $0.comment_id })
                }
            }
        } catch {
            errorMessage = "No se pudieron cargar los comentarios: \(error.localizedDescription)"
        }
    }

    /// Toggle real de like/unlike de un comentario -- mismo patrón exacto
    /// que HomeViewModel.toggleLike() para posts. `comments.like_count` lo
    /// mantiene sincronizado el trigger real de 0054_comment_likes.sql, no
    /// este código -- aquí solo se registra/borra el like del usuario.
    func toggleCommentLike(_ comment: Comment) async {
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
        struct NewCommentLike: Encodable {
            let comment_id: UUID
            let user_id: UUID
        }
        do {
            if currentlyLiked {
                try await SupabaseManager.shared.client
                    .from("comment_likes")
                    .delete()
                    .eq("comment_id", value: comment.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("comment_likes")
                    .insert(NewCommentLike(comment_id: comment.id, user_id: userID))
                    .execute()
                AnalyticsManager.track("comment_liked")
            }
        } catch {
            // Restricción unique(comment_id, user_id): si ya existía el
            // like, Postgrest devuelve un 409 — mismo criterio que
            // HomeViewModel.toggleLike(), el estado deseado ya se cumple.
        }
    }

    /// Fijar/desfijar un comentario real, comparado con Instagram/Twitter
    /// -- solo el autor real de la publicación puede hacerlo
    /// (`comments_update_pin`, 0084_pin_comments.sql, lo garantiza también
    /// del lado del servidor: un intento ajeno afecta 0 filas, revertido
    /// en silencio por la propia UI al no ofrecerle el botón).
    /// Equivalente de CommentsViewModel.kt.togglePin().
    func togglePin(_ comment: Comment) async {
        let newValue = !comment.is_pinned
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index].is_pinned = newValue
        }
        comments = threadOrder(comments)
        do {
            struct PinUpdate: Encodable { let is_pinned: Bool }
            try await SupabaseManager.shared.client
                .from("comments")
                .update(PinUpdate(is_pinned: newValue))
                .eq("id", value: comment.id)
                .execute()
        } catch {
            errorMessage = "No se pudo fijar el comentario."
            await load()
        }
    }

    struct NewComment: Encodable {
        let post_id: UUID
        let author_id: UUID
        let body: String
        var parent_comment_id: UUID? = nil
    }

    /// Aviso de honestidad: la cadena `.insert(...).select().single()` para
    /// pedir de vuelta la fila insertada SÍ está verificada con compilador
    /// real en la versión Kotlin equivalente (`CommentsViewModel.kt`,
    /// `insert(...) { select() }`), pero no hay compilador iOS disponible
    /// en este entorno para confirmar que supabase-swift expone la misma
    /// forma encadenada — es la API razonable según el resto de este
    /// archivo (`select()`/`.eq()`/`.single()` ya se usan en `load()`), no
    /// una firma inventada de cero.
    /// [parentCommentID] es opcional -- responder a un comentario
    /// concreto (hilo de un nivel), comparado con Instagram/Facebook/
    /// Twitter/TikTok -- tiene que ser un comentario real de primer
    /// nivel de esta misma publicación (el propio trigger de
    /// 0104_comment_replies.sql lo exige; si no se cumple, el comentario
    /// simplemente no se publica). Equivalente de
    /// CommentsViewModel.kt.addComment().
    func addComment(_ text: String, parentCommentID: UUID? = nil, onCommentAdded: @escaping () -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Mismo límite real que comments_body_length (0008_comments.sql,
        // el único de los cuatro campos de texto que ya lo tenía desde
        // antes de 0023_text_length_limits.sql) — nunca se validó en el
        // cliente, mismo hueco ya cerrado para nombre/bio/caption/mensaje,
        // ya construido en la versión Kotlin equivalente.
        guard trimmed.count <= 500 else {
            errorMessage = "El comentario no puede tener más de 500 caracteres."
            return
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let inserted: Comment = try await SupabaseManager.shared.client
                .from("comments")
                .insert(NewComment(post_id: postID, author_id: userID, body: trimmed, parent_comment_id: parentCommentID))
                .select()
                .single()
                .execute()
                .value
            comments = threadOrder(comments + [inserted])
            // Si es el primer comentario propio en este post, mi perfil
            // todavía no está en authorProfiles (solo se cargó el de
            // quienes ya habían comentado) -- sin esto, mi propio
            // comentario recién publicado se vería con nombre "…" hasta
            // la próxima recarga.
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
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: comentar tampoco se registraba.
            AnalyticsManager.track("comment_added")
            onCommentAdded()
        } catch {
            errorMessage = "No se pudo publicar el comentario."
        }
    }

    /// Hallazgo real: comparado con cualquier app grande, no había forma
    /// de borrar el propio comentario — `comments_delete_own`
    /// (0008_comments.sql) ya lo permitía a nivel de RLS, solo faltaba el
    /// botón. Equivalente de CommentsViewModel.kt.deleteComment().
    func deleteComment(_ comment: Comment, onCommentRemoved: @escaping () -> Void) async {
        // Responder a un comentario concreto (0104_comment_replies.sql):
        // `on delete cascade` real se lleva sus respuestas con él -- el
        // estado local tiene que reflejar lo mismo.
        comments.removeAll { $0.id == comment.id || $0.parent_comment_id == comment.id }
        do {
            try await SupabaseManager.shared.client
                .from("comments")
                .delete()
                .eq("id", value: comment.id)
                .execute()
            onCommentRemoved()
        } catch {
            errorMessage = "No se pudo borrar el comentario."
        }
    }
}
