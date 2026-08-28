package com.social.app.screens.live

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class LiveStream(
    val id: String,
    @SerialName("host_id") val hostId: String,
    val title: String? = null,
    @SerialName("room_name") val roomName: String = "",
    @SerialName("is_social_only") val isSocialOnly: Boolean = false,
    val status: String = "live",
    @SerialName("viewer_count") val viewerCount: Int = 0,
    @SerialName("started_at") val startedAt: String = ""
)

/**
 * "Directo" real por primera vez, comparado con Instagram/TikTok Live --
 * el último hueco grande identificado leyendo SOCIAL_APP.html. Backend ya
 * construido y verificado en la ronda anterior (0056_live_streams.sql,
 * 115/115 tests locales) -- esta es la ronda de CLIENTE, mismo orden que
 * Reels (0050 backend, luego ReelsViewModel.kt).
 *
 * El motor real es LiveKit (elegido explícitamente por el usuario, Cloud
 * frente a self-hosted): esta clase resuelve la parte de "quién puede ver
 * qué directo" contra la base de datos real (RLS ya probado), y pide el
 * token real de conexión a `live-token` (Edge Function, ver
 * supabase/functions/live-token/index.ts) -- nunca construye el token en
 * el cliente, eso requeriría el secreto de LiveKit.
 */
class LiveStreamsViewModel : ViewModel() {

    private val _streams = MutableStateFlow<List<LiveStream>>(emptyList())
    val streams: StateFlow<List<LiveStream>> = _streams.asStateFlow()

    private val _hostProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val hostProfiles: StateFlow<Map<String, Profile>> = _hostProfiles.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val loaded = SupabaseManager.client.from("live_streams")
                    .select(columns = Columns.raw("id,host_id,title,room_name,is_social_only,status,viewer_count,started_at")) {
                        filter { eq("status", "live") }
                        order("started_at", Order.DESCENDING)
                    }
                    .decodeList<LiveStream>()
                _streams.value = loaded

                val hostIds = loaded.map { it.hostId }.distinct()
                if (hostIds.isNotEmpty()) {
                    try {
                        _hostProfiles.value = SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                                filter { isIn("id", hostIds) }
                            }
                            .decodeList<Profile>()
                            .associateBy { it.id }
                    } catch (e: Exception) {
                        // No bloquea la lista si falla -- los directos se
                        // siguen mostrando aunque no se pueda mostrar
                        // quién los está emitiendo.
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar los directos: ${e.message}"
            } finally {
                _isLoading.value = false
            }
        }
    }

    @Serializable
    private data class NewLiveStream(
        @SerialName("host_id") val hostId: String,
        val title: String?,
        @SerialName("is_social_only") val isSocialOnly: Boolean
    )

    /** Empieza un directo real: inserta la fila (RLS `live_streams_insert_own`,
     * 0056_live_streams.sql), sin token todavía -- el token de publicar se
     * pide aparte con [requestToken] una vez la fila ya existe de verdad. */
    suspend fun startStream(title: String, isSocialOnly: Boolean): LiveStream? {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return null
        return try {
            SupabaseManager.client.from("live_streams")
                .insert(NewLiveStream(userId, title.ifBlank { null }, isSocialOnly)) { select() }
                .decodeSingle<LiveStream>()
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo empezar el directo."
            null
        }
    }

    /** Termina el propio directo real -- solo el host puede (RLS
     * `live_streams_update_own`). `viewer_count` no se toca aquí, está
     * protegido por `trg_protect_live_stream_viewer_count`. */
    fun endStream(stream: LiveStream) {
        viewModelScope.launch {
            try {
                val nowIso = java.time.Instant.now().toString()
                SupabaseManager.client.from("live_streams")
                    .update({ set("status", "ended"); set("ended_at", nowIso) }) {
                        filter { eq("id", stream.id) }
                    }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo terminar el directo."
            }
        }
    }

    @Serializable
    private data class NewViewer(
        @SerialName("stream_id") val streamId: String,
        @SerialName("viewer_id") val viewerId: String
    )

    @Serializable
    data class LiveKitTokenResponse(val token: String, val wsUrl: String, val roomName: String)

    @Serializable
    private data class TokenRequest(val streamId: String)

    /** Se une como espectador real (RLS `live_stream_viewers_insert_own`,
     * comprueba bloqueo contra el host) y pide el token real de LiveKit --
     * mismo orden que exige `live-token/index.ts`: primero unirse (RLS ya
     * hizo el control de verdad), luego el token confía en esa fila. */
    suspend fun joinAndGetToken(stream: LiveStream): LiveKitTokenResponse? {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return null
        return try {
            if (stream.hostId != userId) {
                try {
                    SupabaseManager.client.from("live_stream_viewers").insert(NewViewer(stream.id, userId))
                } catch (e: Exception) {
                    // Restricción unique(stream_id, viewer_id): si ya
                    // estaba unido (p.ej. tras reconectar), no es un error
                    // real, mismo criterio que HomeViewModel.toggleLike().
                }
            }
            requestToken(stream.id)
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo entrar al directo."
            null
        }
    }

    private suspend fun requestToken(streamId: String): LiveKitTokenResponse? {
        return try {
            val response = SupabaseManager.client.functions.invoke("live-token", body = TokenRequest(streamId))
            Json.decodeFromString(response.bodyAsText())
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo conectar al directo."
            null
        }
    }

    /** Pide el token de PUBLICAR para el propio host -- misma función, la
     * Edge Function decide `canPublish` comparando `host_id` con el
     * usuario real, nunca a partir de lo que mande este cliente. */
    suspend fun requestHostToken(stream: LiveStream): LiveKitTokenResponse? = requestToken(stream.id)

    @Serializable
    data class LiveViewerEntry(
        @SerialName("viewer_id") val viewerId: String,
        val displayName: String? = null,
        val avatarConfig: Map<String, String>? = null
    )

    @Serializable
    private data class ViewerRow(@SerialName("viewer_id") val viewerId: String)

    @Serializable
    private data class NameRow(
        val id: String,
        @SerialName("display_name") val displayName: String,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
    )

    /** Lista real de quién está viendo el directo AHORA MISMO, comparado
     * con Instagram/TikTok Live -- `live_stream_viewers` (0056_live_streams.sql)
     * ya existía de verdad (sincroniza `viewer_count` real, RLS ya
     * limitaba la lista completa al propio host), pero ningún cliente la
     * consultaba nunca -- el número se veía, la lista real detrás nunca.
     * Solo el host real ve la lista completa (RLS
     * `live_stream_viewers_select_own_stream` lo exige, no solo esta UI). */
    suspend fun fetchViewers(streamId: String): List<LiveViewerEntry> {
        return try {
            val viewerRows = SupabaseManager.client.from("live_stream_viewers")
                .select(columns = Columns.raw("viewer_id")) { filter { eq("stream_id", streamId) } }
                .decodeList<ViewerRow>()
            val viewerIds = viewerRows.map { it.viewerId }
            if (viewerIds.isEmpty()) return emptyList()
            val profiles = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name,avatar_config")) { filter { isIn("id", viewerIds) } }
                .decodeList<NameRow>()
            val byId = profiles.associateBy { it.id }
            viewerIds.mapNotNull { id -> byId[id]?.let { LiveViewerEntry(id, it.displayName, it.avatarConfig) } }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Sale de un directo ajeno real -- borra la propia fila (RLS
     * `live_stream_viewers_delete_own`); baja `viewer_count` el trigger
     * real, no este código. */
    fun leaveStream(stream: LiveStream) {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("live_stream_viewers").delete {
                    filter { eq("stream_id", stream.id); eq("viewer_id", userId) }
                }
            } catch (e: Exception) {
                // Salir es best-effort -- si falla, la fila queda huérfana
                // pero no bloquea al usuario de cerrar la pantalla.
            }
        }
    }
}
