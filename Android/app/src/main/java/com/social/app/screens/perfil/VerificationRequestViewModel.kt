package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Verificación real (insignia azul, 0080_verification_requests.sql),
 * comparado con Instagram/Twitter/TikTok -- las tres dejan al usuario
 * SOLICITAR la verificación; un equipo revisa y aprueba o rechaza.
 * `profiles.is_verified` ya se pintaba de verdad en varias pantallas,
 * pero no existía NINGÚN camino para llegar a `true` salvo escribirlo a
 * mano en la base de datos.
 */
class VerificationRequestViewModel : ViewModel() {

    private val _isVerified = MutableStateFlow(false)
    val isVerified: StateFlow<Boolean> = _isVerified.asStateFlow()

    private val _hasOpenRequest = MutableStateFlow(false)
    val hasOpenRequest: StateFlow<Boolean> = _hasOpenRequest.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _successMessage = MutableStateFlow<String?>(null)
    val successMessage: StateFlow<String?> = _successMessage.asStateFlow()

    @Serializable
    private data class VerifiedRow(@SerialName("is_verified") val isVerified: Boolean)

    @Serializable
    private data class RequestRow(val id: String)

    fun load() {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                _isVerified.value = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("is_verified")) { filter { eq("id", userId) } }
                    .decodeSingle<VerifiedRow>()
                    .isVerified
                _hasOpenRequest.value = SupabaseManager.client.from("verification_requests")
                    .select(columns = Columns.raw("id")) {
                        filter { eq("profile_id", userId); eq("status", "open") }
                    }
                    .decodeList<RequestRow>()
                    .isNotEmpty()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el estado de verificación."
            }
        }
    }

    @Serializable
    private data class NewRequest(@SerialName("profile_id") val profileId: String, val message: String)

    fun submitRequest(message: String) {
        val trimmed = message.trim()
        if (trimmed.isEmpty() || trimmed.length > 500) {
            _errorMessage.value = "Cuéntanos en menos de 500 caracteres por qué debería verificarse tu cuenta."
            return
        }
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("verification_requests").insert(NewRequest(userId, trimmed))
                _hasOpenRequest.value = true
                _successMessage.value = "Solicitud enviada. Te avisaremos cuando se revise."
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar la solicitud."
            }
        }
    }
}
