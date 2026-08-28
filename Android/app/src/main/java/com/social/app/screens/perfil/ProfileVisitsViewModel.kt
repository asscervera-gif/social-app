package com.social.app.screens.perfil

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

data class ProfileVisitEntry(
    val profileId: String,
    val displayName: String,
    val avatarConfig: Map<String, String>? = null,
    val visitedAt: String
)

/**
 * "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
 * (Premium) -- ver ProfileViewerScreen.kt (registra la visita al abrir
 * un perfil ajeno) y 0132_profile_visits.sql. Mismo patrón sin join
 * embebido que FollowListViewModel.kt: `profile_visits` no trae el
 * perfil del visitante embebido, se resuelve aparte con un solo select.
 */
class ProfileVisitsViewModel : ViewModel() {

    private val _visits = MutableStateFlow<List<ProfileVisitEntry>>(emptyList())
    val visits: StateFlow<List<ProfileVisitEntry>> = _visits.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class VisitRow(
        @SerialName("visitor_id") val visitorId: String,
        @SerialName("visited_at") val visitedAt: String
    )

    @Serializable
    private data class NameRow(
        val id: String,
        @SerialName("display_name") val displayName: String,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
    )

    fun load() {
        viewModelScope.launch {
            try {
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val rows = SupabaseManager.client.from("profile_visits")
                    .select(columns = Columns.raw("visitor_id,visited_at")) {
                        filter { eq("visited_id", myId) }
                        order("visited_at", Order.DESCENDING)
                        limit(100)
                    }
                    .decodeList<VisitRow>()
                val visitorIds = rows.map { it.visitorId }
                val profiles = if (visitorIds.isEmpty()) emptyList() else SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_config")) { filter { isIn("id", visitorIds) } }
                    .decodeList<NameRow>()
                val byId = profiles.associateBy { it.id }
                _visits.value = rows.mapNotNull { row ->
                    byId[row.visitorId]?.let { ProfileVisitEntry(row.visitorId, it.displayName, it.avatarConfig, row.visitedAt) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las visitas."
            }
        }
    }
}
