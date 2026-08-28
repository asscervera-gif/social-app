//
//  DataExportManager.swift
//  Social
//
//  "Descargar tus datos" real, comparado con Instagram/Facebook/
//  Twitter-X ("Download Your Information") -- hallazgo real, confirmado
//  con grep de "export"/"download_data" sin ningún resultado en todo el
//  repo: AjustesView.swift ya cubre toggles de privacidad reales pero
//  ninguna forma real de exportar los datos propios.
//
//  Alcance deliberado: perfil propio + publicaciones propias +
//  comentarios propios (posts y reels) -- un export representativo, no
//  exhaustivo de cada tabla del esquema. Equivalente de
//  DataExportManager.kt.
//

import Foundation

@MainActor
final class DataExportManager: ObservableObject {

    private struct ProfileRow: Encodable, Decodable {
        let id: UUID
        let display_name: String
        let bio: String?
        let username: String?
        let created_at: String?
    }

    private struct PostRow: Encodable, Decodable {
        let id: UUID
        let caption: String?
        let media_url: String?
        let created_at: String
    }

    private struct CommentRow: Encodable, Decodable {
        let id: UUID
        let body: String
        let created_at: String
    }

    private struct ExportPayload: Encodable {
        let profile: ProfileRow?
        let posts: [PostRow]
        let comments: [CommentRow]
        let reel_comments: [CommentRow]
        let exported_at: String
    }

    /// Devuelve una URL real a un fichero temporal ya escrito con el JSON,
    /// o nil si no hay sesión -- listo para `ShareLink(item:)`.
    func buildExportFile() async -> URL? {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return nil }
        let client = SupabaseManager.shared.client

        let profile: ProfileRow? = try? await client
            .from("profiles")
            .select("id,display_name,bio,username,created_at")
            .eq("id", value: userID)
            .single()
            .execute()
            .value

        let posts: [PostRow] = (try? await client
            .from("posts")
            .select("id,caption,media_url,created_at")
            .eq("author_id", value: userID)
            .execute()
            .value) ?? []

        let comments: [CommentRow] = (try? await client
            .from("comments")
            .select("id,body,created_at")
            .eq("author_id", value: userID)
            .execute()
            .value) ?? []

        let reelComments: [CommentRow] = (try? await client
            .from("reel_comments")
            .select("id,body,created_at")
            .eq("author_id", value: userID)
            .execute()
            .value) ?? []

        let payload = ExportPayload(
            profile: profile,
            posts: posts,
            comments: comments,
            reel_comments: reelComments,
            exported_at: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("social_datos_\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
