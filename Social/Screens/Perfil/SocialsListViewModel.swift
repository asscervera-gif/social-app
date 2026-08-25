//
//  SocialsListViewModel.swift
//  Social
//
//  Hallazgo real: "socials" (vínculo mutuo, distinto de "follow" — requiere
//  aceptación de ambas partes) es el concepto de relación central de la
//  app, pero no existía NINGUNA pantalla para ver la lista de socials
//  aceptados en ninguna plataforma — `PerfilViewModel.socialCount` ya
//  calculaba el número, pero solo el número. Mismo patrón sin join
//  embebido/FK ambigua que DuelHistoryViewModel/ChatListViewModel.
//  Equivalente de SocialsListViewModel.kt.
//

import Foundation

struct SocialEntry: Identifiable {
    let id: UUID
    let socialID: UUID
    let displayName: String
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
    // chats/duelos/avisos: "Tus socials" -- la relación central de la
    // app -- tampoco mostraba avatar, solo el nombre.
    let avatarConfig: [String: String]?
}

@MainActor
final class SocialsListViewModel: ObservableObject {
    @Published var socials: [SocialEntry] = []
    @Published var errorMessage: String?

    private struct SocialRow: Decodable {
        let id: UUID
        let requester_id: UUID
        let addressee_id: UUID
    }

    private struct BlockRow: Decodable { let blocked_id: UUID }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            // Hallazgo real: bloquear a alguien no borra la fila de
            // `socials` ya aceptada (son conceptos independientes), así
            // que sin este filtro alguien bloqueado seguía apareciendo en
            // "Tus socials" — mismo refuerzo de privacidad ya aplicado en
            // Home/Match/Find/Search/ChatList/Guardados. Mismo fix ya
            // construido en la versión Kotlin equivalente.
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            // Hallazgo real: sin límite, a diferencia de la convención
            // del resto del proyecto (mismo patrón corregido en
            // ChatViewModel.loadHistory() esta pasada).
            let rows: [SocialRow] = try await SupabaseManager.shared.client
                .from("socials")
                .select()
                .eq("status", value: "accepted")
                .or("requester_id.eq.\(userID),addressee_id.eq.\(userID)")
                .limit(100)
                .execute()
                .value

            var entries: [SocialEntry] = []
            for row in rows {
                let otherID = row.requester_id == userID ? row.addressee_id : row.requester_id
                if blockedIDs.contains(otherID) { continue }
                if let profile = await profileInfo(for: otherID) {
                    entries.append(SocialEntry(
                        id: otherID, socialID: row.id,
                        displayName: profile.display_name, avatarConfig: profile.avatar_config
                    ))
                }
            }
            socials = entries
        } catch {
            errorMessage = "No se pudieron cargar tus socials."
        }
    }

    /// Hallazgo real: no había forma de quitar un social aceptado —
    /// `socials` no tenía ninguna política de delete hasta esta pasada
    /// (ver 0020_socials_delete.sql). Equivalente de
    /// SocialsListViewModel.kt.removeSocial().
    func removeSocial(_ socialID: UUID) {
        socials.removeAll { $0.socialID == socialID }
        Task {
            do {
                try await SupabaseManager.shared.client
                    .from("socials")
                    .delete()
                    .eq("id", value: socialID)
                    .execute()
            } catch {
                errorMessage = "No se pudo quitar el social."
            }
        }
    }

    private struct NameRow: Decodable {
        let display_name: String
        let avatar_config: [String: String]?
    }

    private func profileInfo(for id: UUID) async -> NameRow? {
        try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name,avatar_config")
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }
}
