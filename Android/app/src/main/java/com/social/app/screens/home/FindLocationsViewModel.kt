package com.social.app.screens.home

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

@Serializable
data class PublicLocation(
    val id: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("last_lat") val lat: Double,
    @SerialName("last_lng") val lng: Double
)

/**
 * "Find" — hallazgo real: en iOS era un texto de relleno ("Find: mapa de
 * ubicaciones públicas", un `.sheet` con un `Text` fijo, nunca un mapa
 * real), y en Android no existía ni siquiera el punto de entrada. Ahora
 * que `location_public` tiene un interruptor real (ver
 * PrivacySettingsViewModel.kt), tiene sentido construir el mapa de
 * verdad. `profiles_select_public` (0002_rls.sql) ya expone
 * `last_lat`/`last_lng` solo cuando `location_public = true` — el
 * servidor ya hace el filtro de privacidad, este ViewModel no tiene que
 * repetirlo.
 */
class FindLocationsViewModel : ViewModel() {

    private val _locations = MutableStateFlow<List<PublicLocation>>(emptyList())
    val locations: StateFlow<List<PublicLocation>> = _locations.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    @Serializable
    private data class LocationRow(
        val id: String,
        @SerialName("display_name") val displayName: String,
        @SerialName("last_lat") val lat: Double? = null,
        @SerialName("last_lng") val lng: Double? = null
    )

    fun load() {
        viewModelScope.launch {
            try {
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                // Mismo refuerzo de privacidad ya aplicado en Match/Home/
                // Search: no mostrar a quien he bloqueado.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                // location_public=true no garantiza que last_lat/last_lng
                // tengan un valor real (el usuario puede no haber
                // compartido nunca su posición) — se decodifican como
                // nullable y se filtran en cliente, en vez de asumir que
                // siempre vienen presentes.
                val rows = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,last_lat,last_lng")) {
                        filter {
                            eq("location_public", true)
                            // Mismo hallazgo real ya corregido en
                            // SearchViewModel.kt: sin este filtro, el modo
                            // invisible no protegía la ubicación exacta en
                            // el mapa — un hueco más grave que en el
                            // buscador, porque aquí se filtran
                            // coordenadas reales, no solo el nombre.
                            eq("is_invisible", false)
                            myId?.let { neq("id", it) }
                        }
                        limit(50)
                    }
                    .decodeList<LocationRow>()
                    .filter { it.id !in blockedIds && it.lat != null && it.lng != null }
                    .map { PublicLocation(it.id, it.displayName, it.lat!!, it.lng!!) }
                _locations.value = rows
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las ubicaciones."
            }
        }
    }
}
