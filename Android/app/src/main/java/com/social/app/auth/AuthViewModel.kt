package com.social.app.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.gotrue.providers.builtin.Email
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.LocalDate
import java.time.Period

/**
 * Hallazgo real más grave de toda la sesión: no existía NINGÚN flujo de
 * registro/login en ninguna plataforma. Sin esto no hay forma de que un
 * usuario real entre en la app — todo lo demás construido esta sesión
 * (chat, posts, follow, duelos...) era técnicamente correcto pero
 * inalcanzable sin una cuenta real.
 *
 * Verificación de edad: `legal/privacy_policy_es.md` marca esto como "el
 * riesgo más grave posible" (localización precisa + desconocidos +
 * menores) y deja explícito que un checkbox no es verificación de edad
 * real. Lo que se construye aquí es la comprobación honesta que SÍ puede
 * hacerse desde el cliente sin infraestructura de terceros: fecha de
 * nacimiento real, cálculo de edad exacto, y bloqueo duro (nunca se llama
 * a signUp) si da menos de 18 — no un mensaje de aviso ignorable. Una
 * verificación real contra documento de identidad (KYC) sigue pendiente y
 * se documenta como tal, no se finge aquí.
 */
class AuthViewModel : ViewModel() {

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Hallazgo real: si el proyecto Supabase exige confirmación de email
    // (configuración habitual por defecto), signUp no crea sesión —
    // AppRoot.kt se queda esperando en AuthScreen sin ningún mensaje,
    // dejando al usuario sin saber que tiene que revisar su correo.
    private val _infoMessage = MutableStateFlow<String?>(null)
    val infoMessage: StateFlow<String?> = _infoMessage.asStateFlow()

    fun reportInvalidBirthDate() {
        _errorMessage.value = "Escribe la fecha de nacimiento como AAAA-MM-DD."
    }

    fun signUp(email: String, password: String, displayName: String, birthDate: LocalDate) {
        val age = Period.between(birthDate, LocalDate.now()).years
        if (age < 18) {
            _errorMessage.value = "SOCIAL es solo para mayores de 18 años."
            return
        }
        if (displayName.isBlank()) {
            _errorMessage.value = "Escribe un nombre."
            return
        }
        // Mismo límite real que profiles_display_name_length
        // (0023_text_length_limits.sql) — validado aquí también para dar
        // un error claro en vez de que falle el insert del trigger
        // handle_new_user con un mensaje de Postgres críptico.
        if (displayName.length > 50) {
            _errorMessage.value = "El nombre no puede tener más de 50 caracteres."
            return
        }
        _errorMessage.value = null
        _infoMessage.value = null
        _isLoading.value = true
        viewModelScope.launch {
            try {
                val result = SupabaseManager.client.auth.signUpWith(Email) {
                    this.email = email
                    this.password = password
                    data = JsonObject(mapOf("display_name" to JsonPrimitive(displayName)))
                }
                // signUpWith devuelve null cuando el proyecto exige
                // confirmación de email: la cuenta se crea, pero no hay
                // sesión todavía — sin este mensaje, la pantalla se
                // quedaría igual sin explicar por qué.
                if (result == null) {
                    _infoMessage.value = "Te hemos enviado un email para confirmar tu cuenta. Revisa tu correo y vuelve a intentar iniciar sesión después."
                }
                // Hallazgo real: el registro es el primer paso de
                // cualquier embudo de producto y no se registraba en
                // absoluto — se marca aquí (la cuenta ya se creó de
                // verdad, con o sin confirmación de email pendiente), no
                // en el primer inicio de sesión posterior.
                com.social.app.backend.AnalyticsManager.track("signup_completed")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo crear la cuenta: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }

    /** Hallazgo real: no existía NINGÚN flujo de "olvidé mi contraseña" —
     * un usuario que la olvida se quedaría bloqueado para siempre, sin
     * forma de recuperar la cuenta desde la app. */
    fun resetPassword(email: String) {
        if (email.isBlank()) {
            _errorMessage.value = "Escribe tu email primero."
            return
        }
        _errorMessage.value = null
        _infoMessage.value = null
        _isLoading.value = true
        viewModelScope.launch {
            try {
                SupabaseManager.client.auth.resetPasswordForEmail(email)
                _infoMessage.value = "Si existe una cuenta con ese email, te hemos enviado un enlace para restablecer tu contraseña."
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo enviar el email de recuperación."
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun signIn(email: String, password: String) {
        _errorMessage.value = null
        _isLoading.value = true
        viewModelScope.launch {
            try {
                SupabaseManager.client.auth.signInWith(Email) {
                    this.email = email
                    this.password = password
                }
                // Hallazgo real, misma auditoría de AnalyticsManager de
                // las últimas pasadas: `signup_completed` se registraba,
                // pero volver a iniciar sesión — la métrica de
                // participación recurrente más básica de cualquier app —
                // no se registraba en absoluto.
                com.social.app.backend.AnalyticsManager.track("signin_completed")
            } catch (e: Exception) {
                // Hallazgo real: antes esto siempre mostraba "email o
                // contraseña incorrectos", incluso cuando la causa real
                // era que el email todavía no estaba confirmado (justo el
                // caso que signUp() ya avisa correctamente) — un usuario
                // recién registrado sin confirmar se llevaría un mensaje
                // engañoso sobre su contraseña. Heurística sobre el
                // mensaje de error real de Supabase, no un código exacto
                // verificado — mejor que el mensaje siempre-incorrecto de
                // antes, aunque no sea infalible.
                _errorMessage.value = if (e.message?.contains("confirm", ignoreCase = true) == true) {
                    "Todavía no has confirmado tu email. Revisa tu correo."
                } else {
                    "Email o contraseña incorrectos."
                }
            } finally {
                _isLoading.value = false
            }
        }
    }
}
