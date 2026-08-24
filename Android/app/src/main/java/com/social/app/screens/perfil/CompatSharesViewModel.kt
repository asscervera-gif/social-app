package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.chat.CompatRequestManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class CompatShareEntry(val requestId: String, val requesterName: String)

/**
 * Quién puede ver tu % de compatibilidad — hallazgo real: una vez
 * aceptada una `compat_request`, no había NINGUNA pantalla para ver ni
 * revocar a quién se lo habías concedido, ni siquiera política de delete
 * en la base de datos hasta esta pasada (ver 0021_compat_requests_revoke.sql).
 * Solo lista las que YO controlo (`target_id = yo`) — la dirección
 * contraria (compatibilidad que otros me han concedido a mí) no es algo
 * que yo pueda revocar, es de ellos.
 */
class CompatSharesViewModel : ViewModel() {

    private val _shares = MutableStateFlow<List<CompatShareEntry>>(emptyList())
    val shares: StateFlow<List<CompatShareEntry>> = _shares.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val manager = CompatRequestManager()

    @Serializable
    private data class RequestRow(
        val id: String,
        @SerialName("requester_id") val requesterId: String
    )

    @Serializable
    private data class NameRow(@SerialName("display_name") val displayName: String)

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                // Hallazgo real: sin `.limit()`, a diferencia de la
                // convención del resto del proyecto (mismo patrón
                // corregido en ChatViewModel.loadHistory() esta pasada).
                val rows = SupabaseManager.client.from("compat_requests")
                    .select(columns = Columns.raw("id,requester_id")) {
                        filter {
                            eq("target_id", userId)
                            eq("status", "accepted")
                        }
                        limit(100)
                    }
                    .decodeList<RequestRow>()

                _shares.value = rows.mapNotNull { row ->
                    val name = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name")) { filter { eq("id", row.requesterId) } }
                            .decodeSingleOrNull<NameRow>()?.displayName
                    } catch (e: Exception) {
                        null
                    } ?: return@mapNotNull null
                    CompatShareEntry(row.id, name)
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar a quién le compartes tu compatibilidad."
            }
        }
    }

    fun revoke(requestId: String) {
        _shares.update { it.filter { entry -> entry.requestId != requestId } }
        viewModelScope.launch { manager.revoke(requestId) }
    }
}
