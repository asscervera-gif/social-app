package com.social.app.event

import android.location.Location
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.AnalyticsManager
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Modo Evento: dentro de un recinto, todos los asistentes se ven entre sí,
 * con ranking de socials del evento — equivalente Kotlin de
 * EventModeViewModel.swift. Mismas tablas `events`/`event_attendees`. */
class EventModeViewModel : ViewModel() {

    @Serializable
    data class EventInfo(
        val id: String,
        val name: String,
        @SerialName("venue_lat") val venueLat: Double,
        @SerialName("venue_lng") val venueLng: Double,
        @SerialName("radius_meters") val radiusMeters: Int
    )

    data class RankedAttendee(val profileId: String, val displayName: String, val socialCount: Int)

    private val _activeEvent = MutableStateFlow<EventInfo?>(null)
    val activeEvent: StateFlow<EventInfo?> = _activeEvent.asStateFlow()

    private val _ranking = MutableStateFlow<List<RankedAttendee>>(emptyList())
    val ranking: StateFlow<List<RankedAttendee>> = _ranking.asStateFlow()

    /** Se actualiza en loadRanking() a partir de la misma fila que ya trae
     * `profileId` por asistente — evita una consulta de red aparte solo para
     * saber si el usuario actual ya está en `event_attendees`. */
    private val _hasJoined = MutableStateFlow(false)
    val hasJoined: StateFlow<Boolean> = _hasJoined.asStateFlow()

    /** Hallazgo real, alineado con growth_strategy.md sección 6: la
     * métrica que de verdad importa ("densidad efectiva", % de asistentes
     * con la app abierta ahora mismo, no el número total) ya existía
     * construida y correcta del lado del servidor
     * (`event_density()`, 0005_analytics.sql) desde hace muchas pasadas,
     * pero NADA la llamaba nunca — ni un panel de organizador, ni esta
     * misma pantalla, solo aparecía en comentarios de código. Primera
     * llamada RPC real de todo el proyecto — firma verificada contra el
     * bytecode real de postgrest-kt 2.5.4 (decompilado, no documentación)
     * antes de escribir esto: `postgrest.rpc(name, params)` devuelve
     * `PostgrestResult`, `.decodeAs<Double>()` para el escalar numérico
     * que devuelve la función SQL. */
    private val _density = MutableStateFlow<Double?>(null)
    val density: StateFlow<Double?> = _density.asStateFlow()

    @Serializable
    private data class DensityParams(@SerialName("p_event_id") val eventId: String)

    private suspend fun loadDensity(eventId: String) {
        _density.value = try {
            SupabaseManager.client.postgrest.rpc("event_density", DensityParams(eventId)).decodeAs()
        } catch (e: Exception) {
            null
        }
    }

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun checkForNearbyEvent(location: Location) {
        viewModelScope.launch {
            try {
                val nowIso = java.time.Instant.now().toString()
                val events = SupabaseManager.client.from("events")
                    .select {
                        filter {
                            lte("starts_at", nowIso)
                            gte("ends_at", nowIso)
                        }
                    }
                    .decodeList<EventInfo>()

                _activeEvent.value = events.firstOrNull { event ->
                    val venue = Location("venue").apply {
                        latitude = event.venueLat
                        longitude = event.venueLng
                    }
                    location.distanceTo(venue) <= event.radiusMeters
                }
                val active = _activeEvent.value
                if (active != null) {
                    loadRanking(active.id)
                    loadDensity(active.id)
                } else if (_hasJoined.value) {
                    // Ya no hay ningún evento activo cerca — deja de contar
                    // como actividad "dentro de un evento" para
                    // event_density() (ver AnalyticsManager.currentEventId).
                    AnalyticsManager.setCurrentEvent(null)
                    _hasJoined.value = false
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo comprobar eventos cercanos."
            }
        }
    }

    @Serializable
    private data class NewAttendee(
        @SerialName("event_id") val eventId: String,
        @SerialName("profile_id") val profileId: String
    )

    fun joinEvent(eventId: String, userId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("event_attendees").insert(NewAttendee(eventId, userId))
                AnalyticsManager.track("event_joined", eventId)
                // Ver comentario en AnalyticsManager.currentEventId: a partir
                // de aquí, tab_view/app_open cuentan como actividad real
                // dentro de este evento para event_density(), no solo el
                // propio join.
                AnalyticsManager.setCurrentEvent(eventId)
                loadRanking(eventId)
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo unir al evento."
            }
        }
    }

    @Serializable
    private data class EmbeddedProfile(@SerialName("display_name") val displayName: String)

    @Serializable
    private data class AttendeeRow(
        @SerialName("social_count") val socialCount: Int,
        @SerialName("profile_id") val profileId: String,
        val profiles: EmbeddedProfile? = null
    )

    private suspend fun loadRanking(eventId: String) {
        try {
            // Join real vía "resource embedding" de PostgREST — equivalente
            // a "social_count, profiles(*)" en EventModeViewModel.swift.
            // Columns.raw() y la sintaxis anidada quedaron verificadas contra
            // el bytecode real de postgrest-kt 2.5.4 (antes no confirmado por
            // falta de compilador en este entorno).
            val rows = SupabaseManager.client.from("event_attendees")
                .select(columns = Columns.raw("social_count, profile_id, profiles(display_name)")) {
                    filter { eq("event_id", eventId) }
                    order("social_count", io.github.jan.supabase.postgrest.query.Order.DESCENDING)
                    // Faltaba respecto a EventModeViewModel.swift (.limit(50))
                    // — sin tope, un evento grande traería el ranking entero.
                    limit(50)
                }
                .decodeList<AttendeeRow>()
            _ranking.value = rows.map {
                RankedAttendee(it.profileId, it.profiles?.displayName ?: it.profileId, it.socialCount)
            }
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            _hasJoined.value = myId != null && rows.any { it.profileId == myId }
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo cargar el ranking del evento."
        }
    }
}
