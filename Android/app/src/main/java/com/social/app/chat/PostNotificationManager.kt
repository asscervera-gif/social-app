package com.social.app.chat

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Activar avisos de publicaciones de una cuenta real ("🔔"), comparado con
 * Instagram/Twitter/X -- a diferencia del resto de interacciones (like/
 * comentario/mensaje/mención), una publicación nueva de alguien que sigues
 * nunca generaba ningún aviso real, ni siquiera opcional. Ver
 * 0098_post_notifications.sql -- mismo patrón exacto que FollowManager.kt.
 */
class PostNotificationManager {

    @Serializable
    private data class SubscriptionRow(
        @SerialName("subscriber_id") val subscriberId: String,
        @SerialName("creator_id") val creatorId: String
    )

    suspend fun subscribe(subscriberId: String, creatorId: String): Boolean {
        return try {
            SupabaseManager.client.from("post_notification_subscriptions").insert(SubscriptionRow(subscriberId, creatorId))
            true
        } catch (e: Exception) {
            false
        }
    }

    suspend fun unsubscribe(subscriberId: String, creatorId: String): Boolean {
        return try {
            SupabaseManager.client.from("post_notification_subscriptions").delete {
                filter { eq("subscriber_id", subscriberId); eq("creator_id", creatorId) }
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    suspend fun isSubscribed(subscriberId: String, creatorId: String): Boolean {
        return try {
            SupabaseManager.client.from("post_notification_subscriptions")
                .select {
                    filter { eq("subscriber_id", subscriberId); eq("creator_id", creatorId) }
                }
                .decodeList<SubscriptionRow>()
                .isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }
}
