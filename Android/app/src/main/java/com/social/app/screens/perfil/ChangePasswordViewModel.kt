package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Hallazgo real: había un flujo de "olvidé mi contraseña" (por email,
 * pasada anterior) pero ninguna forma de cambiar la contraseña estando ya
 * dentro de la cuenta — cualquier app real deja hacerlo desde Ajustes sin
 * tener que cerrar sesión y pasar por el email.
 */
class ChangePasswordViewModel : ViewModel() {

    private val _isSaving = MutableStateFlow(false)
    val isSaving: StateFlow<Boolean> = _isSaving.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _successMessage = MutableStateFlow<String?>(null)
    val successMessage: StateFlow<String?> = _successMessage.asStateFlow()

    fun changePassword(newPassword: String) {
        if (newPassword.length < 6) {
            _errorMessage.value = "La contraseña debe tener al menos 6 caracteres."
            return
        }
        _errorMessage.value = null
        _successMessage.value = null
        _isSaving.value = true
        viewModelScope.launch {
            try {
                SupabaseManager.client.auth.updateUser {
                    password = newPassword
                }
                _successMessage.value = "Contraseña actualizada."
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cambiar la contraseña: ${e.message}"
            } finally {
                _isSaving.value = false
            }
        }
    }
}
