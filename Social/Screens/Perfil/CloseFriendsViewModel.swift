//
//  CloseFriendsViewModel.swift
//  Social
//
//  "Mejores amigos" real para historias (0075_close_friends_stories.sql),
//  comparado con Instagram (Close Friends) y Snapchat (audiencia
//  personalizada). Hallazgo real de seguridad, no solo de funcionalidad:
//  `stories_select` (0002_rls.sql) no tenía NINGUNA restricción de
//  audiencia -- cualquier usuario autenticado veía la historia de
//  cualquier otro.
//
//  El candidato natural para elegir "mejores amigos" es la lista de
//  socials aceptados (la relación mutua central de la app, ver
//  SocialsListViewModel.swift) -- no tiene sentido ofrecer añadir a un
//  desconocido sin relación previa. Equivalente de CloseFriendsViewModel.kt.
//

import Foundation

@MainActor
final class CloseFriendsViewModel: ObservableObject {
    @Published var candidates: [SocialEntry] = []
    @Published var closeFriendIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private struct SocialRow: Decodable {
        let id: UUID
        let requester_id: UUID
        let addressee_id: UUID
    }

    private struct NameRow: Decodable {
        let display_name: String
        let avatar_config: [String: String]?
    }

    private struct FriendIDRow: Decodable {
        let friend_id: UUID
    }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
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
                if let profile: NameRow = try? await SupabaseManager.shared.client
                    .from("profiles")
                    .select("display_name,avatar_config")
                    .eq("id", value: otherID)
                    .single()
                    .execute()
                    .value {
                    // compatibilityScore: relleno sin usar aquí -- esta
                    // pantalla nunca lo muestra, solo reutiliza el mismo
                    // SocialEntry ya extendido en SocialsListViewModel.swift
                    // (ronda "Tus socials ordenados por compatibilidad").
                    entries.append(SocialEntry(
                        id: otherID, socialID: row.id,
                        displayName: profile.display_name, avatarConfig: profile.avatar_config,
                        compatibilityScore: 50
                    ))
                }
            }
            candidates = entries

            // close_friends_select_own (0075) solo deja leer la propia
            // lista -- exactamente lo que hace falta aquí.
            let friendRows: [FriendIDRow] = try await SupabaseManager.shared.client
                .from("close_friends")
                .select("friend_id")
                .eq("owner_id", value: userID)
                .execute()
                .value
            closeFriendIDs = Set(friendRows.map { $0.friend_id })
        } catch {
            errorMessage = "No se pudo cargar tu lista de mejores amigos."
        }
    }

    private struct NewCloseFriend: Encodable {
        let owner_id: UUID
        let friend_id: UUID
    }

    func toggle(_ profileID: UUID) {
        let isCurrentlyFriend = closeFriendIDs.contains(profileID)
        if isCurrentlyFriend {
            closeFriendIDs.remove(profileID)
        } else {
            closeFriendIDs.insert(profileID)
        }
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                if isCurrentlyFriend {
                    try await SupabaseManager.shared.client
                        .from("close_friends")
                        .delete()
                        .eq("owner_id", value: userID)
                        .eq("friend_id", value: profileID)
                        .execute()
                } else {
                    try await SupabaseManager.shared.client
                        .from("close_friends")
                        .insert(NewCloseFriend(owner_id: userID, friend_id: profileID))
                        .execute()
                }
            } catch {
                // Revierte el estado optimista si el servidor rechazó el cambio.
                if isCurrentlyFriend {
                    closeFriendIDs.insert(profileID)
                } else {
                    closeFriendIDs.remove(profileID)
                }
                errorMessage = "No se pudo actualizar tu lista de mejores amigos."
            }
        }
    }
}
