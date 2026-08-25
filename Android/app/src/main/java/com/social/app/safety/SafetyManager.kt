package com.social.app.safety

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Bloqueo, denuncia y modo invisible — equivalente Kotlin de
 * SafetyManager.swift. Mismas tablas (`blocks`, `reports`, `profiles`), mismo
 * RLS del backend compartido.
 */
class SafetyManager : ViewModel() {

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class InvisibleUpdate(@SerialName("is_invisible") val isInvisible: Boolean)

    /** Persiste el modo invisible en el perfil. El efecto real sobre el
     * motor UWB (dejar de anunciarse) se hace por separado, llamando a
     * `SocialProximity.setDiscoverable()` — ver comentario en iOS sobre
     * por qué esto tiene que actuar en dos capas. */
    fun setInvisible(invisible: Boolean, userId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("profiles")
                    .update(InvisibleUpdate(invisible)) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar el modo invisible."
            }
        }
    }

    @Serializable
    private data class BlockRow(
        @SerialName("blocker_id") val blockerId: String,
        @SerialName("blocked_id") val blockedId: String
    )

    fun block(userId: String, blockedId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("blocks").insert(BlockRow(userId, blockedId))
                // Hallazgo real, misma auditoría de AnalyticsManager de
                // la pasada anterior: bloquear (una métrica real de
                // confianza y seguridad) tampoco se registraba.
                com.social.app.backend.AnalyticsManager.track("block_created")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo bloquear a este usuario."
            }
        }
    }

    @Serializable
    private data class ReportRow(
        @SerialName("reporter_id") val reporterId: String,
        @SerialName("reported_id") val reportedId: String,
        val reason: String,
        val details: String?,
        // Hallazgo real, comparado con Instagram/TikTok/Facebook: antes el
        // único rastro de "esta denuncia es sobre ESTE post/comentario"
        // era un texto libre y editable ("Publicación {id}" metido a mano
        // en `details`) -- un admin no tenía forma real de ver el
        // contenido denunciado. Referencia real (0045_reports_content_reference.sql).
        @SerialName("post_id") val postId: String? = null,
        @SerialName("comment_id") val commentId: String? = null
    )

    fun report(
        reporterId: String,
        reportedId: String,
        reason: String,
        details: String?,
        postId: String? = null,
        commentId: String? = null
    ) {
        // Mismo límite real que reports_details_length
        // (0024_more_text_length_limits.sql) — "details" es el único
        // campo libre de este formulario ("reason" es una de las
        // REASONS fijas de ReportSheet.kt, no texto libre).
        if ((details?.length ?: 0) > 1000) {
            _errorMessage.value = "Los detalles no pueden tener más de 1000 caracteres."
            return
        }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reports").insert(ReportRow(reporterId, reportedId, reason, details, postId, commentId))
                // Hallazgo real: cada acción clave de la app se registra
                // con AnalyticsManager (duel_completed, tab_view,
                // app_open...) salvo denunciar — el propio equipo de
                // SOCIAL no tendría forma de saber si esta función se usa
                // de verdad sin entrar a la tabla `reports` a mano.
                com.social.app.backend.AnalyticsManager.track("report_submitted")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la denuncia."
            }
        }
    }

    /**
     * Verificación de cuenta: compara una selfie en vivo contra el avatar
     * guardado. Igual que en `SafetyManager.swift`, la comparación real de
     * similitud debe hacerla un servicio backend (Edge Function), nunca el
     * cliente — para no exponer el modelo de comparación ni permitir
     * manipulación local del resultado. Placeholder honesto, no una
     * implementación simulada: el resultado real vendría de una Edge
     * Function equivalente a `duel-ai` que reciba la selfie, la compare
     * contra `avatar_url` y actualice `profiles.is_verified` server-side.
     */
    suspend fun requestVerification(): Boolean {
        _errorMessage.value = "La verificación de cuenta requiere el servicio backend de comparación (pendiente de implementar en Supabase Edge Functions)."
        return false
    }
}
