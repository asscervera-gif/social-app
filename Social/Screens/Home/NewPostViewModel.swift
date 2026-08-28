//
//  NewPostViewModel.swift
//  Social
//
//  Hallazgo real, otro hueco grande: no existía NINGUNA forma de crear una
//  publicación en toda la app — se podía dar like, comentar, guardar y
//  compartir publicaciones ajenas, pero nunca crear una propia. A diferencia
//  de `stories.media_url` (`not null`), `posts.media_url` es opcional
//  (0001_schema.sql) — una publicación solo de texto es válida a nivel de
//  esquema y RLS (`posts_write_own`) sin necesitar Supabase Storage, a
//  diferencia de Historias/chat multimedia. Equivalente de
//  NewPostViewModel.kt.
//

import Foundation

@MainActor
final class NewPostViewModel: ObservableObject {
    @Published var isPosting = false
    @Published var errorMessage: String?

    /// [imageDataList] es opcional (lista vacía) a propósito: `posts.media_url`
    /// es nullable (0001_schema.sql), así que una publicación de solo texto
    /// sigue siendo válida — la foto es un extra, no un requisito. Ver
    /// StorageUploader.swift para el hallazgo de Storage. Comparado con
    /// Instagram/Facebook: varias fotos por publicación
    /// (0055_post_media.sql) -- la primera va en `posts.media_url` como
    /// siempre, el resto en `post_media`. [taggedProfileID] es opcional --
    /// "con quién" (0051_post_social_tags.sql), comparado con SOCIAL_APP.html.
    // Borrador de publicación no enviada, comparado con Instagram/Twitter/
    // X -- ver 0128_post_drafts.sql. Alcance deliberado: solo texto
    // (caption/location_name/is_sensitive), sin fotos elegidas (Data local
    // que no sobrevive a un reinicio real de la app). Equivalente de
    // NewPostViewModel.kt.PostDraft/loadDraft/saveDraft/discardDraft.
    struct PostDraft: Decodable {
        let caption: String
        let location_name: String?
        let is_sensitive: Bool
    }

    func loadDraft() async -> PostDraft? {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return nil }
        return try? await SupabaseManager.shared.client
            .from("post_drafts")
            .select()
            .eq("author_id", value: userID)
            .single()
            .execute()
            .value
    }

    func saveDraft(caption: String, locationName: String?, isSensitive: Bool) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id, !caption.isEmpty else { return }
        struct UpsertDraft: Encodable {
            let author_id: UUID
            let caption: String
            let location_name: String?
            let is_sensitive: Bool
        }
        let trimmedLocation = locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLocation = (trimmedLocation?.isEmpty ?? true) ? nil : trimmedLocation
        try? await SupabaseManager.shared.client
            .from("post_drafts")
            .upsert(UpsertDraft(author_id: userID, caption: caption, location_name: finalLocation, is_sensitive: isSensitive), onConflict: "author_id")
            .execute()
    }

    func discardDraft() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        try? await SupabaseManager.shared.client
            .from("post_drafts")
            .delete()
            .eq("author_id", value: userID)
            .execute()
    }

    func post(caption: String, isSocialOnly: Bool, imageDataList: [Data], taggedProfileID: UUID? = nil, locationName: String? = nil, isSensitive: Bool = false, replyAudience: String = "everyone", pollQuestion: String = "", pollOptions: [String] = [], collaboratorUsername: String = "", altText: String = "") async -> Bool {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        // Mismo límite real que posts_caption_length
        // (0023_text_length_limits.sql) — validado aquí también, mismo
        // criterio ya aplicado a nombre/bio de perfil y ya construido en
        // la versión Kotlin equivalente.
        guard caption.count <= 2200 else {
            errorMessage = "El texto no puede tener más de 2200 caracteres."
            return false
        }
        // Mismo límite real que posts_location_name_length
        // (0095_post_location_tag.sql).
        let trimmedLocation = locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLocation = (trimmedLocation?.isEmpty ?? true) ? nil : trimmedLocation
        guard (finalLocation?.count ?? 0) <= 100 else {
            errorMessage = "El nombre del sitio no puede tener más de 100 caracteres."
            return false
        }
        struct NewPost: Encodable {
            let author_id: UUID
            let caption: String
            let is_social_only: Bool
            let media_url: String?
            let tagged_profile_id: UUID?
            let location_name: String?
            let is_sensitive: Bool
            let reply_audience: String
            // Texto alternativo real (accesibilidad), comparado con
            // Instagram/Facebook/Twitter-X -- ver 0151_post_alt_text.sql.
            // Alcance acotado: solo la foto principal esta ronda, sin
            // editor por cada foto adicional del carrusel todavía.
            let alt_text: String?
        }
        struct NewPostMedia: Encodable {
            let post_id: UUID
            let media_url: String
            let position: Int
        }
        // Encuesta real, comparado con Twitter/X/Facebook -- ver
        // 0113_post_polls.sql.
        struct NewPostPoll: Encodable {
            let post_id: UUID
            let question: String
            let options: [String]
        }
        isPosting = true
        defer { isPosting = false }
        do {
            var mediaURLs: [String] = []
            for imageData in imageDataList {
                if let url = try? await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID) {
                    mediaURLs.append(url)
                }
            }
            let insertedPost: Post = try await SupabaseManager.shared.client
                .from("posts")
                .insert(NewPost(author_id: userID, caption: caption, is_social_only: isSocialOnly, media_url: mediaURLs.first, tagged_profile_id: taggedProfileID, location_name: finalLocation, is_sensitive: isSensitive, reply_audience: replyAudience, alt_text: altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(altText.prefix(1000))))
                .select()
                .single()
                .execute()
                .value
            if mediaURLs.count > 1 {
                let extraMedia = mediaURLs.dropFirst().enumerated().map { index, url in
                    NewPostMedia(post_id: insertedPost.id, media_url: url, position: index + 1)
                }
                try await SupabaseManager.shared.client
                    .from("post_media")
                    .insert(extraMedia)
                    .execute()
            }
            // Encuesta real, comparado con Twitter/X/Facebook -- mismo
            // límite real del CHECK de post_polls.question (200
            // caracteres) y de options (2 a 4), 0113_post_polls.sql.
            let trimmedPollQuestion = String(pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            let cleanOptions = pollOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !trimmedPollQuestion.isEmpty && (2...4).contains(cleanOptions.count) {
                try await SupabaseManager.shared.client
                    .from("post_polls")
                    .insert(NewPostPoll(post_id: insertedPost.id, question: trimmedPollQuestion, options: cleanOptions))
                    .execute()
            }
            // Publicación colaborativa real ("Collab"), comparado con
            // Instagram -- ver 0142_post_collaborators.sql. Alcance
            // acotado: solo 1 colaborador por post, invitación real (no
            // automática) que aparece como aviso aparte y hace falta
            // aceptar. Equivalente de NewPostViewModel.kt.
            var trimmedCollaborator = collaboratorUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCollaborator.hasPrefix("@") { trimmedCollaborator.removeFirst() }
            if !trimmedCollaborator.isEmpty {
                struct UsernameRow: Decodable { let id: UUID }
                struct NewPostCollaborator: Encodable {
                    let post_id: UUID
                    let user_id: UUID
                }
                if let collaboratorRow: UsernameRow = try? await SupabaseManager.shared.client
                    .from("profiles")
                    .select("id")
                    .eq("username", value: trimmedCollaborator)
                    .single()
                    .execute()
                    .value {
                    try? await SupabaseManager.shared.client
                        .from("post_collaborators")
                        .insert(NewPostCollaborator(post_id: insertedPost.id, user_id: collaboratorRow.id))
                        .execute()
                } else {
                    errorMessage = "Publicado, pero no se encontró a @\(trimmedCollaborator) para invitar como colaborador."
                }
            }
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: publicar es la acción de activación más
            // importante del feed y no se registraba.
            AnalyticsManager.track("post_created")
            await discardDraft()
            return true
        } catch {
            errorMessage = "No se pudo publicar."
            return false
        }
    }

    /// Programar la publicación de un post real para más tarde, comparado
    /// con Instagram/Twitter-X/TikTok -- ver 0141_scheduled_posts.sql.
    /// Alcance acotado (mismo criterio que el borrador): solo texto + una
    /// imagen, sin encuesta/varias fotos. Equivalente de
    /// NewPostViewModel.kt.schedulePost().
    func schedulePost(caption: String, isSocialOnly: Bool, imageData: Data?, scheduledFor: Date) async -> Bool {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        guard caption.count <= 2200 else {
            errorMessage = "El texto no puede tener más de 2200 caracteres."
            return false
        }
        struct NewScheduledPost: Encodable {
            let author_id: UUID
            let caption: String
            let is_social_only: Bool
            let media_url: String?
            let scheduled_for: String
        }
        isPosting = true
        defer { isPosting = false }
        do {
            var mediaURL: String?
            if let imageData {
                mediaURL = try? await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            }
            try await SupabaseManager.shared.client
                .from("scheduled_posts")
                .insert(NewScheduledPost(
                    author_id: userID,
                    caption: caption,
                    is_social_only: isSocialOnly,
                    media_url: mediaURL,
                    scheduled_for: ISO8601DateFormatter().string(from: scheduledFor)
                ))
                .execute()
            await discardDraft()
            return true
        } catch {
            errorMessage = "No se pudo programar la publicación."
            return false
        }
    }
}
