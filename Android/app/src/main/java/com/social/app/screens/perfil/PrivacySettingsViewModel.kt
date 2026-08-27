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
        @SerialName("muted_push_kinds") val mutedPushKinds: List<String> = emptyList(),
        @SerialName("muted_keywords") val mutedKeywords: List<String> = emptyList(),
        @SerialName("read_receipts_enabled") val readReceiptsEnabled: Boolean = true,
        // Palabras silenciadas reales en TU PROPIO feed, comparado con
        // Twitter/X ("Muted words") -- distinto de muted_keywords (eso
        // filtra comentarios ajenos en TUS publicaciones). Ver
        // 0116_muted_feed_keywords.sql.
        @SerialName("muted_feed_keywords") val mutedFeedKeywords: List<String> = emptyList()
    )

    private val _compatPublic = MutableStateFlow(false)
    val compatPublic: StateFlow<Boolean> = _compatPublic.asStateFlow()

    private val _locationPublic = MutableStateFlow(false)
    val locationPublic: StateFlow<Boolean> = _locationPublic.asStateFlow()

    // Desactivar el recibo de lectura real ("Leído ✓✓"), comparado con
    // WhatsApp/Instagram/Messenger -- mismo criterio recíproco real: si lo
    // apagas, tampoco ves el de los demás (ChatViewModel.kt ya deja de
    // pintar "Leído" para cualquiera cuyo propio interruptor esté
    // apagado, sea quien sea). Ver 0091_read_receipts_toggle.sql.
    private val _readReceiptsEnabled = MutableStateFlow(true)
    val readReceiptsEnabled: StateFlow<Boolean> = _readReceiptsEnabled.asStateFlow()

    // Hallazgo real, comparado con Instagram/Twitter/Facebook/WhatsApp:
    // todas dejan silenciar "me gusta" sin silenciar "mensajes" -- esta
    // app solo tenía silenciar un CHAT completo (0047_message_notify_mute.sql),
    // nunca una CATEGORÍA de aviso en toda la app. Aplicado de verdad en
    // el servidor (send-push/index.ts), no solo en el cliente -- un push
    // real llega o no llega según esto, no es decorativo.
    private val _mutedKinds = MutableStateFlow<Set<String>>(emptySet())
    val mutedKinds: StateFlow<Set<String>> = _mutedKinds.asStateFlow()

    // Palabras silenciadas reales en comentarios (0078_muted_keywords.sql),
    // comparado con Instagram/Twitter -- oculta automáticamente cualquier
    // comentario propio (post o reel) que contenga una de estas palabras,
    // sin bloquear a nadie: el comentario sigue existiendo de verdad para
    // todos los demás, incluido quien lo escribió.
    private val _mutedKeywords = MutableStateFlow<List<String>>(emptyList())
    val mutedKeywords: StateFlow<List<String>> = _mutedKeywords.asStateFlow()

    // Palabras silenciadas reales en TU PROPIO feed, comparado con
    // Twitter/X ("Muted words") -- oculta de tu feed cualquier
    // publicación (de cualquier autor) cuyo texto contenga una de estas
    // palabras. Distinto real de _mutedKeywords (arriba): aquello
    // filtra comentarios AJENOS en TUS publicaciones; esto filtra
    // publicaciones AJENAS en TU feed. Ver 0116_muted_feed_keywords.sql.
    private val _mutedFeedKeywords = MutableStateFlow<List<String>>(emptyList())
    val mutedFeedKeywords: StateFlow<List<String>> = _mutedFeedKeywords.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val row = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("compat_public,location_public,muted_push_kinds,muted_keywords,read_receipts_enabled,muted_feed_keywords")) { filter { eq("id", userId) } }
                    .decodeSingle<PrivacyRow>()
                _compatPublic.value = row.compatPublic
                _locationPublic.value = row.locationPublic
                _mutedKinds.value = row.mutedPushKinds.toSet()
                _mutedKeywords.value = row.mutedKeywords
                _readReceiptsEnabled.value = row.readReceiptsEnabled
                _mutedFeedKeywords.value = row.mutedFeedKeywords
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar la privacidad."
            }
        }
    }

    fun addMutedKeyword(word: String) {
        val normalized = word.trim().lowercase()
        if (normalized.isEmpty() || normalized in _mutedKeywords.value) return
        val previous = _mutedKeywords.value
        _mutedKeywords.value = previous + normalized
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("muted_keywords", _mutedKeywords.value) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar la palabra silenciada."
                _mutedKeywords.value = previous
            }
        }
    }

    fun removeMutedKeyword(word: String) {
        val previous = _mutedKeywords.value
        _mutedKeywords.value = previous - word
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("muted_keywords", _mutedKeywords.value) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar la palabra silenciada."
                _mutedKeywords.value = previous
            }
        }
    }

    /** Palabras silenciadas reales en TU PROPIO feed, comparado con
     * Twitter/X -- mismo patrón exacto que addMutedKeyword()/
     * removeMutedKeyword() de arriba, sobre la columna nueva
     * `muted_feed_keywords` (0116_muted_feed_keywords.sql). */
    fun addMutedFeedKeyword(word: String) {
        val normalized = word.trim().lowercase()
        if (normalized.isEmpty() || normalized in _mutedFeedKeywords.value) return
        val previous = _mutedFeedKeywords.value
        _mutedFeedKeywords.value = previous + normalized
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("muted_feed_keywords", _mutedFeedKeywords.value) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar la palabra silenciada."
                _mutedFeedKeywords.value = previous
            }
        }
    }

    fun removeMutedFeedKeyword(word: String) {
        val previous = _mutedFeedKeywords.value
        _mutedFeedKeywords.value = previous - word
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("profiles")
                    .update({ set("muted_feed_keywords", _mutedFeedKeywords.value) }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar la palabra silenciada."
                _mutedFeedKeywords.value = previous
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

    fun setReadReceiptsEnabled(value: Boolean) {
        val previous = _readReceiptsEnabled.value
        _readReceiptsEnabled.value = value
        updateColumn("read_receipts_enabled", value) { _readReceiptsEnabled.value = previous }
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
