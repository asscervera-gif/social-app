//
//  RestrictedUsersViewModel.swift
//  Social
//
//  Gestión de cuentas restringidas -- equivalente exacto de
//  BlockedUsersViewModel.swift, pero sobre `restricts`
//  (0093_restrict_account.sql) en vez de `blocks`. `restricts_select_own`
//  ya deja leer solo la propia lista (nadie más, ni siquiera la persona
//  restringida), así que esta consulta no necesita ningún filtro
//  adicional de pertenencia. Equivalente de RestrictedUsersViewModel.kt.
//

import Foundation

@MainActor
final class RestrictedUsersViewModel: ObservableObject {
    @Published var restricted: [Profile] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseManager.shared.client
            struct RestrictRow: Decodable { let restricted_id: UUID }
            let rows: [RestrictRow] = try await client
                .from("restricts")
                .select("restricted_id")
                .execute()
                .value

            var results: [Profile] = []
            for row in rows {
                if let profile: Profile = try? await client
                    .from("profiles")
                    .select()
                    .eq("id", value: row.restricted_id)
                    .single()
                    .execute()
                    .value {
                    results.append(profile)
                }
            }
            restricted = results
        } catch {
            errorMessage = "No se pudo cargar la lista de restringidos."
        }
    }

    func unrestrict(_ profile: Profile) {
        let previous = restricted
        restricted.removeAll { $0.id == profile.id }
        Task {
            do {
                guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
                try await SupabaseManager.shared.client
                    .from("restricts")
                    .delete()
                    .eq("restricter_id", value: userID)
                    .eq("restricted_id", value: profile.id)
                    .execute()
            } catch {
                errorMessage = "No se pudo deshacer la restricción."
                restricted = previous
            }
        }
    }
}
