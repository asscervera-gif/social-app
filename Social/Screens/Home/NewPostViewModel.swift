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

    /// [imageData] es opcional a propósito: `posts.media_url` es nullable
    /// (0001_schema.sql), así que una publicación de solo texto sigue
    /// siendo válida — la foto es un extra, no un requisito. Ver
    /// StorageUploader.swift para el hallazgo de Storage. [taggedProfileID]
    /// es opcional -- "con quién" (0051_post_social_tags.sql), comparado
    /// con SOCIAL_APP.html.
    func post(caption: String, isSocialOnly: Bool, imageData: Data?, taggedProfileID: UUID? = nil) async -> Bool {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        // Mismo límite real que posts_caption_length
        // (0023_text_length_limits.sql) — validado aquí también, mismo
        // criterio ya aplicado a nombre/bio de perfil y ya construido en
        // la versión Kotlin equivalente.
        guard caption.count <= 2200 else {
            errorMessage = "El texto no puede tener más de 2200 caracteres."
            return false
        }
        struct NewPost: Encodable {
            let author_id: UUID
            let caption: String
            let is_social_only: Bool
            let media_url: String?
            let tagged_profile_id: UUID?
        }
        isPosting = true
        defer { isPosting = false }
        do {
            let mediaURL: String?
            if let imageData {
                mediaURL = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            } else {
                mediaURL = nil
            }
            try await SupabaseManager.shared.client
                .from("posts")
                .insert(NewPost(author_id: userID, caption: caption, is_social_only: isSocialOnly, media_url: mediaURL, tagged_profile_id: taggedProfileID))
                .execute()
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
