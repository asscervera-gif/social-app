package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
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
 * Gestión de cuentas restringidas -- equivalente exacto de
 * BlockedUsersViewModel.kt, pero sobre `restricts` (0093_restrict_account.sql)
 * en vez de `blocks`. `restricts_select_own` ya deja leer solo la propia
 * lista (nadie más, ni siquiera la persona restringida), así que esta
 * consulta no necesita ningún filtro adicional de pertenencia.
 */
class RestrictedUsersViewModel : ViewModel() {

    private val _restricted = MutableStateFlow<List<Profile>>(emptyList())
    val restricted: StateFlow<List<Profile>> = _restricted.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Fecha real de restricción, comparado con Instagram (la pantalla
    // "Cuentas restringidas" muestra desde cuándo). Mismo hallazgo que
    // BlockedUsersViewModel.kt (Ronda 82): `restricts.created_at` ya
    // existe desde 0093_restrict_account.sql, pero nunca se pedía.
    private val _restrictedAt = MutableStateFlow<Map<String, String>>(emptyMap())
    val restrictedAt: StateFlow<Map<String, String>> = _restrictedAt.asStateFlow()

    @Serializable
    private data class RestrictRow(
        @SerialName("restricted_id") val restrictedId: String,
        @SerialName("created_at") val createdAt: String = ""
    )

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val rows = SupabaseManager.client.from("restricts")
                    .select(Columns.raw("restricted_id,created_at")) { order("created_at", io.github.jan.supabase.postgrest.query.Order.DESCENDING) }
                    .decodeList<RestrictRow>()
                _restrictedAt.value = rows.associate { it.restrictedId to it.createdAt }
                _restricted.value = rows.mapNotNull { row ->
                    try {
                        SupabaseManager.client.from("profiles")
                            .select(Columns.raw("id,display_name,avatar_url,avatar_config,interests,bio,is_invisible,location_public,compat_public,is_verified")) {
                                filter { eq("id", row.restrictedId) }
                            }
                            .decodeSingleOrNull<Profile>()
                    } catch (e: Exception) {
                        null
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la lista de restringidos."
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun unrestrict(restrictedId: String) {
        val previous = _restricted.value
        _restricted.value = previous.filter { it.id != restrictedId }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("restricts").delete {
                    filter {
                        eq("restricter_id", userId)
                        eq("restricted_id", restrictedId)
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo deshacer la restricción."
                _restricted.value = previous
            }
        }
    }
}
