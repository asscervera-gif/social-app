package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class SocialEntry(
    val socialId: String,
    val profileId: String,
    val displayName: String,
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
    // chats/duelos/avisos: "Tus socials" -- la relación central de la
    // app -- tampoco mostraba avatar, solo el nombre.
    val avatarConfig: Map<String, String>? = null
)

/**
 * Hallazgo real: "socials" (vínculo mutuo, distinto de "follow" — requiere
 * aceptación de ambas partes) es el concepto de relación central de la
 * app, pero no existía NINGUNA pantalla para ver la lista de socials
 * aceptados en ninguna plataforma — `PerfilViewModel.socialCount` ya
 * calculaba el número desde hace varias pasadas, pero solo el número, sin
 * forma de ver quiénes son. Mismo patrón sin join embebido/FK ambigua que
 * DuelHistoryViewModel/ChatListViewModel: `socials` tiene dos columnas que
 * referencian `profiles` (requester_id/addressee_id).
 */
class SocialsListViewModel : ViewModel() {

    private val _socials = MutableStateFlow<List<SocialEntry>>(emptyList())
    val socials: StateFlow<List<SocialEntry>> = _socials.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class SocialRow(
        val id: String,
        @SerialName("requester_id") val requesterId: String,
        @SerialName("addressee_id") val addresseeId: String
    )

    @Serializable
    private data class NameRow(
        @SerialName("display_name") val displayName: String,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
    )

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                // Hallazgo real: bloquear a alguien no borra la fila de
                // `socials` ya aceptada (son conceptos independientes),
                // así que sin este filtro alguien bloqueado seguía
                // apareciendo en "Tus socials" — mismo refuerzo de
                // privacidad ya aplicado en Home/Match/Find/Search/
                // ChatList/Guardados.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                // Hallazgo real: sin `.limit()`, a diferencia de la
                // convención del resto del proyecto (mismo patrón
                // corregido en ChatViewModel.loadHistory() esta pasada).
                val rows = SupabaseManager.client.from("socials")
                    .select(columns = Columns.raw("id,requester_id,addressee_id")) {
                        filter {
                            eq("status", "accepted")
                            or {
                                eq("requester_id", userId)
                                eq("addressee_id", userId)
                            }
                        }
                        limit(100)
                    }
                    .decodeList<SocialRow>()

                _socials.value = rows.mapNotNull { row ->
                    val otherId = if (row.requesterId == userId) row.addresseeId else row.requesterId
                    if (otherId in blockedIds) return@mapNotNull null
                    val profile = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name,avatar_config")) { filter { eq("id", otherId) } }
                            .decodeSingleOrNull<NameRow>()
                    } catch (e: Exception) {
                        null
                    } ?: return@mapNotNull null
                    SocialEntry(row.id, otherId, profile.displayName, profile.avatarConfig)
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus socials."
            }
        }
    }

    /** Hallazgo real: no había forma de quitar un social aceptado —
     * `socials` no tenía ninguna política de delete hasta esta pasada
     * (ver 0020_socials_delete.sql). Cualquiera de las dos partes puede
     * deshacer el vínculo. */
    fun removeSocial(socialId: String) {
        _socials.update { it.filter { entry -> entry.socialId != socialId } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("socials").delete { filter { eq("id", socialId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar el social."
            }
        }
    }
}
