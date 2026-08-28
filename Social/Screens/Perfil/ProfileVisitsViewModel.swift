//
//  ProfileVisitsViewModel.swift
//  Social
//
//  "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
//  (Premium) -- ver ProfileViewerView.swift (registra la visita al abrir
//  un perfil ajeno) y 0132_profile_visits.sql. Mismo patrón sin join
//  embebido que FollowListViewModel.swift: `profile_visits` no trae el
//  perfil del visitante embebido, se resuelve aparte con un solo select.
//  Equivalente de ProfileVisitsViewModel.kt.
//

import Foundation

struct ProfileVisitEntry: Identifiable {
    let id: UUID
    let displayName: String
    let avatarConfig: [String: String]?
    let visitedAt: String
}

@MainActor
final class ProfileVisitsViewModel: ObservableObject {
    @Published var visits: [ProfileVisitEntry] = []
    @Published var errorMessage: String?

    private struct VisitRow: Decodable {
        let visitor_id: UUID
        let visited_at: String
    }

    private struct NameRow: Decodable {
        let id: UUID
        let display_name: String
        let avatar_config: [String: String]?
    }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let rows: [VisitRow] = try await SupabaseManager.shared.client
                .from("profile_visits")
                .select("visitor_id,visited_at")
                .eq("visited_id", value: userID)
                .order("visited_at", ascending: false)
                .limit(100)
                .execute()
                .value
            let visitorIDs = rows.map { $0.visitor_id }
            var byID: [UUID: NameRow] = [:]
            if !visitorIDs.isEmpty {
                let profiles: [NameRow] = try await SupabaseManager.shared.client
                    .from("profiles")
                    .select("id,display_name,avatar_config")
                    .in("id", values: visitorIDs)
                    .execute()
                    .value
                byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }
            visits = rows.compactMap { row in
                byID[row.visitor_id].map { ProfileVisitEntry(id: row.visitor_id, displayName: $0.display_name, avatarConfig: $0.avatar_config, visitedAt: row.visited_at) }
            }
        } catch {
            errorMessage = "No se pudieron cargar las visitas."
        }
    }
}
