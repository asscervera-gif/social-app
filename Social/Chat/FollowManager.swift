//
//  FollowManager.swift
//  Social
//
//  Gestiona seguir/dejar de seguir (tabla `follows`, no requiere aceptación
//  mutua como los socials — cualquiera puede seguir a un perfil público).
//  Antes el botón "Seguir de vuelta" en AvisosView.swift estaba vacío
//  (`{}`), sin ninguna implementación.
//
//  Aviso de honestidad: asume que el backend rellena `payload["actor_id"]`
//  con el profile_id de quien generó la notificación de tipo "follow" —
//  misma convención ya usada (y ya documentada como asunción) para
//  `payload["chat_id"]`/`payload["social_id"]` en notificaciones de tipo
//  "social". Si esa pieza server-side no rellena esa clave, el botón no
//  tiene a quién seguir; no es un bug del cliente.
//

import Foundation

@MainActor
final class FollowManager: ObservableObject {

    @Published var errorMessage: String?

    func follow(followerID: UUID, followeeID: UUID) async {
        struct NewFollow: Encodable {
            let follower_id: UUID
            let followee_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("follows")
                .insert(NewFollow(follower_id: followerID, followee_id: followeeID))
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: seguir a alguien tampoco se registraba.
            AnalyticsManager.track("user_followed")
        } catch {
            errorMessage = "No se pudo seguir a este perfil."
        }
    }

    /// Hallazgo real: no existía ninguna forma de dejar de seguir en
    /// ninguna plataforma, ni ningún botón "Seguir" directo en el visor de
    /// perfil (solo "seguir de vuelta" desde una notificación) —
    /// `follows_select` (0002_rls.sql) es pública (`using (true)`), así que
    /// se puede comprobar el estado real sin necesidad de una función RPC.
    func unfollow(followerID: UUID, followeeID: UUID) async {
        do {
            try await SupabaseManager.shared.client
                .from("follows")
                .delete()
                .eq("follower_id", value: followerID)
                .eq("followee_id", value: followeeID)
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: se registraba `user_followed` pero no
            // su opuesto.
            AnalyticsManager.track("user_unfollowed")
        } catch {
            errorMessage = "No se pudo dejar de seguir."
        }
    }

    func isFollowing(followerID: UUID, followeeID: UUID) async -> Bool {
        struct FollowRow: Decodable {
            let follower_id: UUID
            let followee_id: UUID
        }
        let rows: [FollowRow]? = try? await SupabaseManager.shared.client
            .from("follows")
            .select()
            .eq("follower_id", value: followerID)
            .eq("followee_id", value: followeeID)
            .execute()
            .value
        return !(rows ?? []).isEmpty
    }
}
