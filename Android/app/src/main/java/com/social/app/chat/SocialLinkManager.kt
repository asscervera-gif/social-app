package com.social.app.chat

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Gestiona el envío/aceptación de "socials" — equivalente Kotlin de
 * SocialLinkManager.swift. Un social requiere aceptación mutua: el perfil
 * público permite chatear antes, pero el vínculo social siempre necesita
 * los dos síes (tabla `socials`).
 *
 * Antes de esta corrección, Android no tenía NINGUNA implementación de este
 * flujo — a diferencia de iOS (que sí tiene `respond()` cableado en
 * AvisosView, aunque `sendSocial()` tampoco se llama desde ningún sitio
 * todavía en ninguna de las dos plataformas: mandar un social requiere
 * conocer el profile_id real de la persona detectada por UWB, y el motor
 * de proximidad hoy solo intercambia un UUID efímero de sesión, no la
 * identidad real — ver LOOP_STATE.md, pendiente principal).
 */
class SocialLinkManager {

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class NewSocial(
        @SerialName("requester_id") val requesterId: String,
        @SerialName("addressee_id") val addresseeId: String
    )

    suspend fun sendSocial(requesterId: String, addresseeId: String) {
        try {
            SupabaseManager.client.from("socials").insert(NewSocial(requesterId, addresseeId))
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo enviar el social."
        }
    }

    @Serializable
    private data class SocialRow(
        val id: String,
        @SerialName("requester_id") val requesterId: String,
        @SerialName("addressee_id") val addresseeId: String
    )

    @Serializable
    private data class NewChat(
        @SerialName("user_a_id") val userAId: String,
        @SerialName("user_b_id") val userBId: String
    )

    /** Solo el destinatario puede aceptar (lo aplica la política RLS socials_update). */
    suspend fun respond(socialId: String, accept: Boolean) {
        try {
            SupabaseManager.client.from("socials")
                .update({ set("status", if (accept) "accepted" else "declined") }) {
                    filter { eq("id", socialId) }
                }
            if (accept) createChatIfNeeded(socialId)
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo responder al social."
        }
    }

    private suspend fun createChatIfNeeded(socialId: String) {
        try {
            val social = SupabaseManager.client.from("socials")
                .select { filter { eq("id", socialId) } }
                .decodeSingle<SocialRow>()
            SupabaseManager.client.from("chats")
                .insert(NewChat(social.requesterId, social.addresseeId))
        } catch (e: Exception) {
            // Puede fallar si el chat ya existe (constraint unique) — no es un error de usuario.
        }
    }
}
