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
 * Gestión de bloqueados — hallazgo real: `SafetyManager.block()` existe
 * desde antes de esta sesión, y `blocks_delete_own` (0003_safety.sql) ya
 * permite desbloquear a nivel de RLS, pero no había ninguna pantalla en
 * ninguna plataforma que listara a quién has bloqueado ni forma de
 * desbloquear — un bloqueo era, en la práctica, permanente.
 */
class BlockedUsersViewModel : ViewModel() {

    private val _blocked = MutableStateFlow<List<Profile>>(emptyList())
    val blocked: StateFlow<List<Profile>> = _blocked.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Fecha real de bloqueo, comparado con Instagram/Twitter-X (la
    // pantalla "Cuentas bloqueadas" muestra cuándo bloqueaste a cada
    // persona, útil para una revisión periódica de seguridad). Hallazgo
    // real: `blocks.created_at` ya existe desde el principio
    // (0003_safety.sql), pero ningún cliente lo pedía ni lo mostraba
    // jamás -- mismo patrón ya visto esta sesión con
    // live_stream_viewers (Ronda 79): el dato real ya estaba, solo
    // faltaba consultarlo.
    private val _blockedAt = MutableStateFlow<Map<String, String>>(emptyMap())
    val blockedAt: StateFlow<Map<String, String>> = _blockedAt.asStateFlow()

    @Serializable
    private data class BlockRow(
        @SerialName("blocked_id") val blockedId: String,
        @SerialName("created_at") val createdAt: String = ""
    )

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id
                val rows = SupabaseManager.client.from("blocks")
                    .select(Columns.raw("blocked_id,created_at")) { order("created_at", io.github.jan.supabase.postgrest.query.Order.DESCENDING) }
                    .decodeList<BlockRow>()
                _blockedAt.value = rows.associate { it.blockedId to it.createdAt }
                val ids = rows.map { it.blockedId }.filter { it != userId }
                // Sin `isIn`/filtro de pertenencia verificado en el resto del
                // código (MatchViewModel/HomeViewModel filtran en cliente, no
                // por lista en el servidor) — mismo patrón aquí: una consulta
                // por id bloqueado. Las listas de bloqueados son pequeñas por
                // naturaleza, así que N consultas pequeñas es aceptable.
                _blocked.value = ids.mapNotNull { blockedId ->
                    try {
                        SupabaseManager.client.from("profiles")
                            .select(Columns.raw("id,display_name,avatar_url,avatar_config,interests,bio,is_invisible,location_public,compat_public,is_verified")) {
                                filter { eq("id", blockedId) }
                            }
                            .decodeSingleOrNull<Profile>()
                    } catch (e: Exception) {
                        null
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la lista de bloqueados."
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun unblock(blockedId: String) {
        val previous = _blocked.value
        _blocked.value = previous.filter { it.id != blockedId }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("blocks").delete {
                    filter {
                        eq("blocker_id", userId)
                        eq("blocked_id", blockedId)
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo desbloquear."
                _blocked.value = previous
            }
        }
    }
}
