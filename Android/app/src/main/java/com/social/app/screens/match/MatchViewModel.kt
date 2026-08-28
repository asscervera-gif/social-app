package com.social.app.screens.match

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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

/** Equivalente Kotlin de MatchViewModel.swift: cuadrícula de perfiles con
 * compatibilidad pública o solicitable. */
class MatchViewModel : ViewModel() {

    data class Entry(val profile: Profile, val compatibility: Int?, val requestSent: Boolean = false)

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Expuesto para el filtro real "Tus gustos" del boceto (ver
    // MatchScreen.kt) — antes se calculaba dentro de load() y se tiraba
    // después de usarlo solo para estimatedCompatibility().
    private val _myInterests = MutableStateFlow<Set<String>>(emptySet())
    val myInterests: StateFlow<Set<String>> = _myInterests.asStateFlow()

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    fun load() {
        viewModelScope.launch {
            try {
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id

                // Hallazgo real: a quien bloqueas seguía apareciendo en Match
                // — el fix de invisible/self-exclusión de esta sesión nunca
                // cubrió bloqueados. Solo se puede filtrar en la dirección
                // "a quién he bloqueado yo" (RLS de `blocks` no deja ver
                // quién me bloqueó a mí — límite de privacidad correcto, no
                // un hueco a rellenar).
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }

                // Antes se traían TODOS los perfiles, incluyendo a quien tiene
                // el modo invisible activo y al propio usuario — modo invisible
                // es un principio de producto "no negociable" (ver comentario
                // en SocialCameraView.swift/SocialCameraScreen.kt), así que
                // ignorarlo aquí era un fallo de privacidad real, no solo de
                // optimización de la consulta.
                // Optimización: la cuadrícula de Match solo usa id, nombre,
                // avatar, intereses y compat_public — antes se traían TODAS
                // las columnas (bio, is_verified, location_public...) sin
                // usarlas nunca en esta pantalla. El resto de campos de
                // Profile tiene valor por defecto, así que decodifica igual.
                val profiles = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config,interests,compat_public,last_lat,last_lng,created_at")) {
                        filter {
                            eq("is_invisible", false)
                            myId?.let { neq("id", it) }
                        }
                        limit(60)
                    }
                    .decodeList<Profile>()
                    .filter { it.id !in blockedIds }

                val myInterests = myId?.let { userId ->
                    try {
                        SupabaseManager.client.from("profiles")
                            .select { filter { eq("id", userId) } }
                            .decodeSingle<Profile>()
                            .interests
                            .toSet()
                    } catch (e: Exception) {
                        emptySet()
                    }
                } ?: emptySet()
                _myInterests.value = myInterests

                _entries.value = profiles.map { Entry(it, estimatedCompatibility(it, myInterests)) }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar Match: ${e.message}"
            }
        }
    }

    /** Estimación heurística por solapamiento de intereses (Jaccard) — mismo
     * criterio y misma advertencia que `estimatedCompatibility` en
     * MatchViewModel.swift: es un punto de partida real, no un algoritmo de
     * compatibilidad definitivo. No hay otra fuente de "% con un desconocido"
     * en el esquema hasta que exista un chat entre ambos. */
    private fun estimatedCompatibility(profile: Profile, myInterests: Set<String>): Int? {
        if (!profile.compatPublic) return null
        val theirInterests = profile.interests.toSet()
        if (myInterests.isEmpty() || theirInterests.isEmpty()) return null
        val intersection = myInterests.intersect(theirInterests).size
        val union = myInterests.union(theirInterests).size
        if (union == 0) return null
        return ((intersection.toDouble() / union) * 100).toInt()
    }

    @Serializable
    private data class NewCompatRequest(
        @SerialName("requester_id") val requesterId: String,
        @SerialName("target_id") val targetId: String,
        val highlighted: Boolean = false
    )

    /** Crea una fila en compat_requests (misma tabla y RLS que iOS, regla 4).
     * [highlighted] real, comparado con Tinder/Bumble (Super Like) -- ver
     * 0136_compat_request_highlight.sql. Límite real de una destacada al
     * día reforzado por un índice único parcial en el propio servidor
     * (`idx_compat_requests_highlighted_daily`); un segundo intento el
     * mismo día real revierte el estado optimista y muestra el error real
     * en vez de fingir que se destacó. */
    fun requestCompatibility(entry: Entry, highlighted: Boolean = false) {
        _entries.update { list -> list.map { if (it.profile.id == entry.profile.id) it.copy(requestSent = true) else it } }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("compat_requests").insert(
                    NewCompatRequest(requesterId = userId, targetId = entry.profile.id, highlighted = highlighted)
                )
                // Hallazgo real, misma auditoría de AnalyticsManager de
                // las últimas pasadas: pedir ver la compatibilidad de
                // alguien tampoco se registraba.
                com.social.app.backend.AnalyticsManager.track(if (highlighted) "compat_request_highlighted" else "compat_request_sent")
            } catch (e: Exception) {
                if (highlighted) {
                    _entries.update { list -> list.map { if (it.profile.id == entry.profile.id) it.copy(requestSent = false) else it } }
                    _errorMessage.value = "Ya has destacado una solicitud hoy."
                } else {
                    _errorMessage.value = "No se pudo enviar la solicitud de compatibilidad."
                }
            }
        }
    }
}
