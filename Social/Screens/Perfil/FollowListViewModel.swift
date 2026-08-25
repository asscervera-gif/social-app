//
//  FollowListViewModel.swift
//  Social
//
//  Hallazgo real, comparado con Instagram/Twitter/TikTok: los contadores
//  "Siguiendo"/"Seguidores" de la cabecera del perfil (PerfilViewModel.swift,
//  followingCount/followerCount) ya eran reales desde una pasada anterior,
//  pero tocarlos no hacía nada -- no existía NINGUNA pantalla para ver QUIÉN
//  sigue a quién, solo el número. Mismo patrón sin join embebido/FK ambigua
//  que SocialsListViewModel: `follows` referencia `profiles` dos veces
//  (follower_id/followee_id). Equivalente de FollowListViewModel.kt.
//

import Foundation

struct FollowEntry: Identifiable {
    let id: UUID
    let displayName: String
    let avatarConfig: [String: String]?
    var isFollowing: Bool
}

@MainActor
final class FollowListViewModel: ObservableObject {
    @Published var following: [FollowEntry] = []
    @Published var followers: [FollowEntry] = []
    @Published var errorMessage: String?

    private var myID: UUID?

    private struct FollowRow: Decodable {
        let follower_id: UUID
        let followee_id: UUID
    }

    private struct NameRow: Decodable {
        let id: UUID
        let display_name: String
        let avatar_config: [String: String]?
    }

    private struct BlockRow: Decodable { let blocked_id: UUID }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        myID = userID
        do {
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            let followingRows: [FollowRow] = try await SupabaseManager.shared.client
                .from("follows")
                .select("followee_id")
                .eq("follower_id", value: userID)
                .limit(200)
                .execute()
                .value
            let followingIDs = Set(followingRows.map { $0.followee_id }).subtracting(blockedIDs)

            let followerRows: [FollowRow] = try await SupabaseManager.shared.client
                .from("follows")
                .select("follower_id")
                .eq("followee_id", value: userID)
                .limit(200)
                .execute()
                .value
            let followerIDs = Set(followerRows.map { $0.follower_id }).subtracting(blockedIDs)

            let allIDs = Array(followingIDs.union(followerIDs))
            var byID: [UUID: NameRow] = [:]
            if !allIDs.isEmpty {
                let profiles: [NameRow] = try await SupabaseManager.shared.client
                    .from("profiles")
                    .select("id,display_name,avatar_config")
                    .in("id", values: allIDs)
                    .execute()
                    .value
                byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }

            following = followingIDs.compactMap { pid in
                byID[pid].map { FollowEntry(id: pid, displayName: $0.display_name, avatarConfig: $0.avatar_config, isFollowing: true) }
            }
            followers = followerIDs.compactMap { pid in
                byID[pid].map { FollowEntry(id: pid, displayName: $0.display_name, avatarConfig: $0.avatar_config, isFollowing: followingIDs.contains(pid)) }
            }
        } catch {
            errorMessage = "No se pudo cargar la lista."
        }
    }

    func toggleFollow(_ entry: FollowEntry) {
        guard let myID else { return }
        let manager = FollowManager()
        Task {
            if entry.isFollowing {
                await manager.unfollow(followerID: myID, followeeID: entry.id)
            } else {
                await manager.follow(followerID: myID, followeeID: entry.id)
            }
            await load()
        }
    }
}
