package com.social.app.duels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class DuelHistoryEntry(
    val id: String,
    @SerialName("initiator_id") val initiatorId: String,
    @SerialName("opponent_id") val opponentId: String,
    @SerialName("compatibility_delta") val compatibilityDelta: Int? = null,
    @SerialName("created_at") val createdAt: String,
    val opponentName: String? = null
)

@Serializable
private data class DuelOpponentProfile(
    @SerialName("display_name") val displayName: String
)

/**
 * Historial de duelos — antes "Fights" en PerfilView.swift era un botón
 * vacío (`{}`), y Android no tenía ni siquiera el botón (la decisión
 * documentada de no portar la rejilla de 6 iconos era correcta cuando 5 de
 * 6 dependían de vídeo/fotos sin Storage real — "Fights" es la excepción:
 * usa datos que ya existen de verdad en `duels`, sin infraestructura
 * nueva). Sin join embebido a `profiles` a propósito: `duels` tiene DOS
 * columnas que referencian `profiles` (initiator_id/opponent_id), y
 * desambiguar el nombre exacto de la foreign key sin poder probarlo contra
 * un Postgres real sería adivinar.
 *
 * Resuelto en una pasada posterior: en vez de un join embebido (que exige
 * adivinar el nombre de la FK), una consulta de `display_name` por id del
 * "otro" participante — mismo patrón ya usado y seguro en
 * `BlockedUsersViewModel.kt`. Ya no hace falta mostrar el historial en
 * blanco de nombre.
 */
class DuelHistoryViewModel : ViewModel() {

    private val _duels = MutableStateFlow<List<DuelHistoryEntry>>(emptyList())
    val duels: StateFlow<List<DuelHistoryEntry>> = _duels.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val entries = SupabaseManager.client.from("duels")
                    .select(columns = Columns.raw("id,initiator_id,opponent_id,compatibility_delta,created_at")) {
                        filter {
                            or {
                                eq("initiator_id", userId)
                                eq("opponent_id", userId)
                            }
                        }
                        order("created_at", Order.DESCENDING)
                        limit(50)
                    }
                    .decodeList<DuelHistoryEntry>()

                _duels.value = entries.map { entry ->
                    val opponentId = if (entry.initiatorId == userId) entry.opponentId else entry.initiatorId
                    val name = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name")) { filter { eq("id", opponentId) } }
                            .decodeSingleOrNull<DuelOpponentProfile>()
                            ?.displayName
                    } catch (e: Exception) {
                        null
                    }
                    entry.copy(opponentName = name)
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el historial de duelos: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }
}
