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
    func post(caption: String, isSocialOnly: Bool, imageDataList: [Data], taggedProfileID: UUID? = nil, locationName: String? = nil, isSensitive: Bool = false, replyAudience: String = "everyone", pollQuestion: String = "", pollOptions: [String] = []) async -> Bool {
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
                .insert(NewPost(author_id: userID, caption: caption, is_social_only: isSocialOnly, media_url: mediaURLs.first, tagged_profile_id: taggedProfileID, location_name: finalLocation, is_sensitive: isSensitive, reply_audience: replyAudience))
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
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: publicar es la acción de activación más
            // importante del feed y no se registraba.
            AnalyticsManager.track("post_created")
            return true
        } catch {
            errorMessage = "No se pudo publicar."
            return false
        }
    }
}
