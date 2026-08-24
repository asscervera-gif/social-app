package com.social.app.chat

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Gestiona seguir (tabla `follows`, no requiere aceptación mutua como los
 * socials) — equivalente Kotlin de FollowManager.swift. Antes Android no
 * tenía ningún botón ni implementación de "seguir de vuelta" en absoluto.
 *
 * Aviso de honestidad: misma convención de `payload["actor_id"]` ya
 * documentada en FollowManager.swift.
 */
class FollowManager {

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class NewFollow(
        @SerialName("follower_id") val followerId: String,
        @SerialName("followee_id") val followeeId: String
    )

    suspend fun follow(followerId: String, followeeId: String) {
        try {
            SupabaseManager.client.from("follows").insert(NewFollow(followerId, followeeId))
            // Hallazgo real, misma auditoría de AnalyticsManager de la
            // pasada anterior: seguir a alguien tampoco se registraba.
            com.social.app.backend.AnalyticsManager.track("user_followed")
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo seguir a este perfil."
        }
    }

    /**
     * Hallazgo real: no existía ninguna forma de dejar de seguir en ninguna
     * plataforma, ni ningún botón "Seguir" directo en el visor de perfil
     * (solo "seguir de vuelta" desde una notificación) — `follows_select`
     * (0002_rls.sql) es pública (`using (true)`), así que se puede
     * comprobar el estado real sin necesidad de una función RPC.
     */
    suspend fun unfollow(followerId: String, followeeId: String) {
        try {
            SupabaseManager.client.from("follows").delete {
                filter {
                    eq("follower_id", followerId)
                    eq("followee_id", followeeId)
                }
            }
            // Hallazgo real: se registraba `user_followed` pero no su
            // opuesto — sin `user_unfollowed` no se puede medir cuánta
            // gente sigue y luego se arrepiente.
            com.social.app.backend.AnalyticsManager.track("user_unfollowed")
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo dejar de seguir."
        }
    }

    suspend fun isFollowing(followerId: String, followeeId: String): Boolean {
        return try {
            SupabaseManager.client.from("follows")
                .select {
                    filter {
                        eq("follower_id", followerId)
                        eq("followee_id", followeeId)
                    }
                }
                .decodeList<NewFollow>()
                .isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }
}
