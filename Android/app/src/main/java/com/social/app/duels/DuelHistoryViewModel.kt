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
    val opponentName: String? = null,
    // Hallazgo real, mismo hueco raíz ya cerrado en la lista de chats
    // (ChatListEntry.otherAvatarConfig): el historial de duelos tampoco
    // mostraba el avatar del rival, solo el nombre.
    val opponentAvatarConfig: Map<String, String>? = null
)

// Estadísticas agregadas reales del historial, comparado con Snapchat
// (Snap Score) y el patrón estándar de "resumen" en juegos sociales con
// historial de partidas (Wordle compartido, Kahoot) -- antes solo se
// veía la lista cruda, partida por partida, sin ningún total ni media.
// Alcance deliberado: calculado sobre los mismos 50 duelos más recientes
// que ya trae load() (limit(50) real, ver más abajo), no un agregado de
// por vida -- documentado explícitamente en la propia UI ("de tus
// últimos N duelos") para no afirmar más de lo que se calcula de verdad.
data class DuelStats(
    val totalPlayed: Int,
    val averageDelta: Double,
    val mostFrequentOpponentName: String?,
    val mostFrequentOpponentCount: Int
)

@Serializable
private data class DuelOpponentProfile(
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
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

    private val _stats = MutableStateFlow<DuelStats?>(null)
    val stats: StateFlow<DuelStats?> = _stats.asStateFlow()

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
                    val opponent = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name,avatar_config")) { filter { eq("id", opponentId) } }
                            .decodeSingleOrNull<DuelOpponentProfile>()
                    } catch (e: Exception) {
                        null
                    }
                    entry.copy(opponentName = opponent?.displayName, opponentAvatarConfig = opponent?.avatarConfig)
                }

                val deltas = _duels.value.mapNotNull { it.compatibilityDelta }
                val mostFrequent = _duels.value
                    .mapNotNull { it.opponentName }
                    .groupingBy { it }
                    .eachCount()
                    .maxByOrNull { it.value }
                _stats.value = if (_duels.value.isEmpty()) null else DuelStats(
                    totalPlayed = _duels.value.size,
                    averageDelta = if (deltas.isEmpty()) 0.0 else deltas.average(),
                    mostFrequentOpponentName = mostFrequent?.key,
                    mostFrequentOpponentCount = mostFrequent?.value ?: 0
                )
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el historial de duelos: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }
}
