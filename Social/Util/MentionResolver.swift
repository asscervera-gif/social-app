//
//  MentionResolver.swift
//  Social
//
//  Resuelve un "@usuario" real (0073_profile_username.sql) a su id de
//  perfil real -- compartido entre captions/comentarios de posts y reels,
//  mismo criterio de "compartir en vez de duplicar" que
//  MentionHashtagText.swift (la consulta es idéntica en las cuatro
//  superficies). Sin resultado si el username ya no existe (cuenta
//  borrada) -- se resuelve en silencio, mismo criterio ya aplicado a
//  shared_post_id/story_id en mensajes (0069/0071). Equivalente de
//  MentionResolver.kt.
//

import Foundation

enum MentionResolver {
    private struct UsernameRow: Decodable { let id: UUID }

    static func resolveProfileID(username: String) async -> UUID? {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let row: UsernameRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id")
            .eq("username", value: normalized)
            .single()
            .execute()
            .value
        return row?.id
    }
}
