package com.social.app.screens.perfil

import androidx.core.content.getSystemService
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

/**
 * Hallazgo real: `compat_public`/`location_public` se consultaban en
 * varios sitios (Match/Home para saber si mostrar el % de compatibilidad
 * sin solicitarla, "Find" para el mapa de ubicaciones públicas) pero no
 * había NINGÚN interruptor para activarlos en ninguna plataforma — se
 * quedaban bloqueados en `false` para siempre, la única forma de cambiar
 * `compat_public` a `true` habría sido escribirlo a mano en la base de
 * datos. `profiles_update_own` (0002_rls.sql) ya permite editar cualquier
 * columna del propio perfil, solo faltaba la UI.
 */
class PrivacySettingsViewModel : ViewModel() {

    @Serializable
    private data class PrivacyRow(
        @SerialName("compat_public") val compatPublic: Boolean,
        @SerialName("location_public") val locationPublic: Boolean,
        @SerialName("muted_push_kinds") val mutedPushKinds: List<String> = emptyList()
    )

    private val _compatPublic = MutableStateFlow(false)
    val compatPublic: StateFlow<Boolean> = _compatPublic.asStateFlow()

    private val _locationPublic = MutableStateFlow(false)
    val locationPublic: StateFlow<Boolean> = _locationPublic.asStateFlow()

    // Hallazgo real, comparado con Instagram/Twitter/Facebook/WhatsApp:
    // todas dejan silenciar "me gusta" sin silenciar "mensajes" -- esta
    // app solo tenía silenciar un CHAT completo (0047_message_notify_mute.sql),
    // nunca una CATEGORÍA de aviso en toda la app. Aplicado de verdad en
    // el servidor (send-push/index.ts), no solo en el cliente -- un push
    // real llega o no llega según esto, no es decorativo.
    private val _mutedKinds = MutableStateFlow<Set<String>>(emptySet())
    val mutedKinds: StateFlow<Set<String>> = _mutedKinds.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val row = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("compat_public,location_public,muted_push_kinds")) { filter { eq("id", userId) } }
                    .decodeSingle<PrivacyRow>()
                _compatPublic.value = row.compatPublic
                _locationPublic.value = row.locationPublic
                _mutedKinds.value = row.mutedPushKinds.toSet()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la privacidad."
            }
        }
    }

    /** [kinds] son los valores reales de `notifications.kind` que agrupa
     * una categoría visible en Ajustes (p. ej. "Me gusta" -> like +
     * reel_like) -- ver AjustesScreen.kt para el mapeo completo. */
    fun setCategoryMuted(kinds: List<String>, muted: Boolean) {
        val previous = _mutedKinds.value
        _mutedKinds.value = if (muted) previous + kinds else previous - kinds.toSet()
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("muted_push_kinds", _mutedKinds.value.toList()) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar el cambio."
                _mutedKinds.value = previous
            }
        }
    }

    fun setCompatPublic(value: Boolean) {
        val previous = _compatPublic.value
        _compatPublic.value = value
        updateColumn("compat_public", value) { _compatPublic.value = previous }
    }

    fun setLocationPublic(context: android.content.Context, value: Boolean) {
        val previous = _locationPublic.value
        _locationPublic.value = value
        updateColumn("location_public", value) { _locationPublic.value = previous }
        // Hallazgo real, encontrado auditando "Find" (FindLocationsViewModel.kt):
        // el mapa ya filtraba correctamente por location_public/bloqueados/
        // invisible, pero NADA en toda la app escribía nunca last_lat/last_lng
        // — ni aquí, ni en la cámara, ni en Modo Evento. El interruptor llevaba
        // pasadas enteras "funcionando" (guardaba el booleano) sin que "Find"
        // pudiera mostrar jamás una sola ubicación real. Se publica una vez, en
        // el momento de activar el interruptor — no es un rastreo en segundo
        // plano continuo (decisión de alcance, no un descuido: eso requeriría
        // un servicio en primer/segundo plano real, fuera de esta corrección).
        if (value) publishCurrentLocation(context)
    }

    private fun publishCurrentLocation(context: android.content.Context) {
        viewModelScope.launch {
            try {
                val locationManager = context.getSystemService<android.location.LocationManager>() ?: return@launch
                val location = listOf(
                    android.location.LocationManager.GPS_PROVIDER,
                    android.location.LocationManager.NETWORK_PROVIDER
                ).mapNotNull { runCatching { locationManager.getLastKnownLocation(it) }.getOrNull() }
                    .firstOrNull() ?: return@launch
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles").update({
                    set("last_lat", location.latitude)
                    set("last_lng", location.longitude)
                }) { filter { eq("id", userId) } }
            } catch (e: SecurityException) {
                // Sin permiso de ubicación concedido todavía — el interruptor
                // ya se guardó, se reintenta la próxima vez que se active.
            } catch (e: Exception) {
                // No crítico: el interruptor ya se guardó, solo falló la
                // primera publicación de coordenadas.
            }
        }
    }

    private fun updateColumn(column: String, value: Boolean, onFailure: () -> Unit) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set(column, value) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar el cambio."
                onFailure()
            }
        }
    }
}
