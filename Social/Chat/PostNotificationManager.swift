//
//  PostNotificationManager.swift
//  Social
//
//  Activar avisos de publicaciones de una cuenta real ("🔔"), comparado con
//  Instagram/Twitter/X -- a diferencia del resto de interacciones (like/
//  comentario/mensaje/mención), una publicación nueva de alguien que sigues
//  nunca generaba ningún aviso real, ni siquiera opcional. Ver
//  0098_post_notifications.sql -- mismo patrón exacto que FollowManager.swift.
//  Equivalente de PostNotificationManager.kt.
//

import Foundation

final class PostNotificationManager {

    struct SubscriptionRow: Codable {
        let subscriber_id: UUID
        let creator_id: UUID
    }

    func subscribe(subscriberID: UUID, creatorID: UUID) async -> Bool {
        do {
            try await SupabaseManager.shared.client
                .from("post_notification_subscriptions")
                .insert(SubscriptionRow(subscriber_id: subscriberID, creator_id: creatorID))
                .execute()
            return true
        } catch {
            return false
        }
    }

    func unsubscribe(subscriberID: UUID, creatorID: UUID) async -> Bool {
        do {
            try await SupabaseManager.shared.client
                .from("post_notification_subscriptions")
                .delete()
                .eq("subscriber_id", value: subscriberID)
                .eq("creator_id", value: creatorID)
                .execute()
            return true
        } catch {
            return false
        }
    }

    func isSubscribed(subscriberID: UUID, creatorID: UUID) async -> Bool {
        let rows: [SubscriptionRow]? = try? await SupabaseManager.shared.client
            .from("post_notification_subscriptions")
            .select()
            .eq("subscriber_id", value: subscriberID)
            .eq("creator_id", value: creatorID)
            .execute()
            .value
        return !(rows ?? []).isEmpty
    }
}
