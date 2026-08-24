package com.social.app.screens.perfil

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Borrado real de cuenta — hueco documentado en LOOP_STATE.md: la política
 * de privacidad prometía "borrado completo... desde Ajustes" pero no
 * existía ningún mecanismo, ni pantalla de Ajustes, en ninguna plataforma
 * (bloqueante legal real, RGPD/CCPA). Llama a la Edge Function
 * `delete-account` (mismo patrón que `duel-ai`: la clave privilegiada —
 * aquí `service_role`, no `ANTHROPIC_API_KEY` — nunca sale del servidor).
 */
class AccountManager {

    private val _isDeleting = MutableStateFlow(false)
    val isDeleting: StateFlow<Boolean> = _isDeleting.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    suspend fun deleteAccount(): Boolean {
        _isDeleting.value = true
        return try {
            SupabaseManager.client.functions.invoke("delete-account")
            // El servidor ya borró auth.users (cascada real hasta profiles y
            // todo lo dependiente) — cierra también la sesión local, ya que
            // el token seguiría "vigente" en memoria hasta la próxima
            // petición fallida si no se hace explícitamente.
            SupabaseManager.client.auth.signOut()
            true
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo borrar la cuenta: ${e.message}"
            false
        } finally {
            _isDeleting.value = false
        }
    }
}
