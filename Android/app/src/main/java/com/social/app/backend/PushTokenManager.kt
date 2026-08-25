package com.social.app.backend

import com.google.firebase.messaging.FirebaseMessaging
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Pieza cliente que faltaba para que notify_push_on_new_notification()
 * (0041_notify_push_trigger.sql) y send-push (supabase/functions/send-push)
 * tengan un token real al que enviar -- equivalente exacto de
 * PushTokenManager.swift. Se llama desde AppRoot.kt solo con sesión real
 * (nunca en frío), y desde SocialFirebaseMessagingService.onNewToken()
 * cuando Firebase renueva el token más tarde.
 */
object PushTokenManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun registerCurrentToken() {
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> register(token) }
    }

    fun register(token: String) {
        scope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("device_tokens").upsert(
                    DeviceTokenUpsert(userId, "android", token),
                    onConflict = "profile_id,platform,token"
                )
            } catch (e: Exception) {
                // Fire-and-forget deliberado, mismo criterio que
                // AnalyticsManager.track(): un fallo de red al registrar el
                // token no debe afectar a la funcionalidad real de la app.
            }
        }
    }

    @Serializable
    private data class DeviceTokenUpsert(
        @SerialName("profile_id") val profileId: String,
        val platform: String,
        val token: String
    )
}
