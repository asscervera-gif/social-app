package com.social.app.chat

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Responde a una solicitud de ver el % de compatibilidad (tabla
 * `compat_requests`) — equivalente Kotlin de CompatRequestManager.swift.
 * El mecanismo entero ya existía server-side (RLS + la función
 * `private.has_accepted_compat_request`), Android ni siquiera tenía el
 * botón en la hoja de notificaciones.
 */
class CompatRequestManager {

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    suspend fun respond(requestId: String, accept: Boolean) {
        try {
            SupabaseManager.client.from("compat_requests")
                .update({ set("status", if (accept) "accepted" else "declined") }) {
                    filter { eq("id", requestId) }
                }
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo responder a la solicitud de compatibilidad."
        }
    }

    /** Hallazgo real, mismo patrón que socials: una vez aceptada, no había
     * NINGUNA forma de revocar el acceso a tu % de compatibilidad —
     * `compat_requests` no tenía política de delete hasta esta pasada
     * (ver 0021_compat_requests_revoke.sql). Solo el dueño de la
     * compatibilidad (`target_id`) puede revocar. */
    suspend fun revoke(requestId: String) {
        try {
            SupabaseManager.client.from("compat_requests").delete { filter { eq("id", requestId) } }
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo revocar el acceso."
        }
    }
}
