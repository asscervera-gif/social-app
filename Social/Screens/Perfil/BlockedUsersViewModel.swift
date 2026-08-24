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

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseManager.shared.client
            let userID = try? await client.auth.session.user.id

            struct BlockRow: Decodable { let blocked_id: UUID }
            let rows: [BlockRow] = try await client
                .from("blocks")
                .select()
                .execute()
                .value
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
