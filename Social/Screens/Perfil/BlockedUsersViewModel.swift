//
//  BlockedUsersViewModel.swift
//  Social
//
//  Gestión de bloqueados — hallazgo real: `SafetyManager.block()` existe
//  desde antes de esta sesión, y `blocks_delete_own` (0003_safety.sql) ya
//  permite desbloquear a nivel de RLS, pero no había ninguna pantalla en
//  ninguna plataforma que listara a quién has bloqueado ni forma de
//  desbloquear — un bloqueo era, en la práctica, permanente. Equivalente de
//  BlockedUsersViewModel.kt.
//

import Foundation

@MainActor
final class BlockedUsersViewModel: ObservableObject {
    @Published var blocked: [Profile] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Fecha real de bloqueo, comparado con Instagram/Twitter-X (la
    // pantalla "Cuentas bloqueadas" muestra cuándo bloqueaste a cada
    // persona). Hallazgo real: `blocks.created_at` ya existe desde el
    // principio (0003_safety.sql), pero ningún cliente lo pedía ni lo
    // mostraba jamás -- mismo patrón ya visto esta sesión con
    // live_stream_viewers (Ronda 79). Equivalente de
    // BlockedUsersViewModel.kt.blockedAt.
    @Published var blockedAt: [UUID: String] = [:]

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseManager.shared.client
            let userID = try? await client.auth.session.user.id

            struct BlockRow: Decodable { let blocked_id: UUID; let created_at: String }
            let rows: [BlockRow] = try await client
                .from("blocks")
                .select("blocked_id,created_at")
                .order("created_at", ascending: false)
                .execute()
                .value
            blockedAt = Dictionary(uniqueKeysWithValues: rows.map { ($0.blocked_id, $0.created_at) })
            let ids = rows.map { $0.blocked_id }.filter { $0 != userID }

            // Sin filtro de pertenencia por lista verificado en el resto del
            // código (MatchViewModel/HomeViewModel filtran en cliente) —
            // mismo patrón aquí: una consulta por id bloqueado. Las listas
            // de bloqueados son pequeñas por naturaleza.
            var results: [Profile] = []
            for id in ids {
                if let profile: Profile = try? await client
                    .from("profiles")
                    .select()
                    .eq("id", value: id)
                    .single()
                    .execute()
                    .value {
                    results.append(profile)
                }
            }
            blocked = results
        } catch {
            errorMessage = "No se pudo cargar la lista de bloqueados."
        }
    }

    func unblock(_ profile: Profile) {
        let previous = blocked
        blocked.removeAll { $0.id == profile.id }
        Task {
            do {
                guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
                try await SupabaseManager.shared.client
                    .from("blocks")
                    .delete()
                    .eq("blocker_id", value: userID)
                    .eq("blocked_id", value: profile.id)
                    .execute()
            } catch {
                errorMessage = "No se pudo desbloquear."
                blocked = previous
            }
        }
    }
}
