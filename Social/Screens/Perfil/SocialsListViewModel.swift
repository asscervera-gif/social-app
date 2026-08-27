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
    // % de compatibilidad REAL (chats.compatibility_score), comparado con
    // el filtro "Compatibles" que ya existe en descubrimiento
    // (MatchView.swift) -- hueco real de la auditoría de sistemas propios
    // de SOCIAL: "Tus socials" no mostraba ni ordenaba por compatibilidad
    // pese a que cada social aceptado ya tiene un chat con ese dato real
    // (más significativo aquí que el estimado por intereses del feed).
    // Equivalente de SocialEntry.compatibilityScore (Kotlin).
    let compatibilityScore: Int
}

@MainActor
final class SocialsListViewModel: ObservableObject {
    @Published var socials: [SocialEntry] = []
    // Hallazgo real, comparado con Instagram (solicitudes de seguimiento
    // enviadas, con opción de cancelar): tras enviar un social por la
    // cámara (único punto de envío -- SocialCameraView.swift), quien lo
    // envía no tenía NINGUNA forma de ver que sigue pendiente ni de
    // cancelarlo si capturó a la persona equivocada -- 0020_socials_delete.sql
    // ya permite borrar la fila a cualquiera de las dos partes sin
    // importar el status, el hueco era puramente de UI/visibilidad.
    @Published var pendingSent: [SocialEntry] = []
    @Published var errorMessage: String?

    private struct SocialRow: Decodable {
        let id: UUID
        let requester_id: UUID
        let addressee_id: UUID
    }

    private struct BlockRow: Decodable { let blocked_id: UUID }

    private struct CompatRow: Decodable { let compatibility_score: Int }

    /// Mismo orden canónico (menor id primero) que
    /// SocialLinkManager.getOrCreateChat() -- `unique(user_a_id,
    /// user_b_id)` (0001_schema.sql) es sensible al orden, así que el
    /// chat real de cada social ya vive con este mismo orden desde que se
    /// creó al aceptar (SocialLinkManager.respond()). Sin crear un chat
    /// nuevo aquí a propósito: esta pantalla solo LEE, nunca debe tener
    /// el efecto secundario de crear una fila nueva solo por mostrar la
    /// lista. Equivalente de realCompatibility() en Kotlin.
    private func realCompatibility(userID: UUID, otherID: UUID) async -> Int {
        let (a, b) = userID.uuidString < otherID.uuidString ? (userID, otherID) : (otherID, userID)
        guard let row: CompatRow = try? await SupabaseManager.shared.client
            .from("chats")
            .select("compatibility_score")
            .eq("user_a_id", value: a)
            .eq("user_b_id", value: b)
            .single()
            .execute()
            .value else {
            return 50
        }
        return row.compatibility_score
    }

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
                        displayName: profile.display_name, avatarConfig: profile.avatar_config,
                        compatibilityScore: await realCompatibility(userID: userID, otherID: otherID)
                    ))
                }
            }
            socials = entries.sorted { $0.compatibilityScore > $1.compatibilityScore }

            let pendingRows: [SocialRow] = try await SupabaseManager.shared.client
                .from("socials")
                .select()
                .eq("status", value: "pending")
                .eq("requester_id", value: userID)
                .limit(100)
                .execute()
                .value

            var pendingEntries: [SocialEntry] = []
            for row in pendingRows {
                if blockedIDs.contains(row.addressee_id) { continue }
                if let profile = await profileInfo(for: row.addressee_id) {
                    // Sin chat real todavía (solo se crea al aceptar,
                    // SocialLinkManager.respond()) -- 50 es solo un valor
                    // de relleno, nunca se muestra para una pendiente.
                    pendingEntries.append(SocialEntry(
                        id: row.addressee_id, socialID: row.id,
                        displayName: profile.display_name, avatarConfig: profile.avatar_config,
                        compatibilityScore: 50
                    ))
                }
            }
            pendingSent = pendingEntries
        } catch {
            errorMessage = "No se pudieron cargar tus socials."
        }
    }

    /// Hallazgo real: no había forma de quitar un social aceptado —
    /// `socials` no tenía ninguna política de delete hasta esta pasada
    /// (ver 0020_socials_delete.sql). También usado para cancelar una
    /// solicitud pendiente enviada (misma política de delete, sin
    /// distinción de status). Equivalente de
    /// SocialsListViewModel.kt.removeSocial().
    func removeSocial(_ socialID: UUID) {
        socials.removeAll { $0.socialID == socialID }
        pendingSent.removeAll { $0.socialID == socialID }
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
