package com.social.app.screens.perfil

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ProfileSection(
    val id: String,
    @SerialName("profile_id") val profileId: String,
    @SerialName("section_key") val sectionKey: String,
    val content: Map<String, String>,
    @SerialName("is_public") val isPublic: Boolean
)

/**
 * Equivalente Kotlin de PerfilViewModel.swift. Antes esta clase solo
 * cargaba `profile` (nombre/bio) — las 15 secciones editables del perfil
 * completo, que sí existen en iOS, no tenían ningún equivalente Android.
 */
class PerfilViewModel : ViewModel() {

    companion object {
        /** Mismo orden y mismas claves que PerfilViewModel.swift.sectionKeys. */
        val SECTION_KEYS = listOf(
            "sobre_mi", "trabajo", "estudios", "musica", "cine", "deportes",
            "viajes", "comida", "mascotas", "idiomas", "signo", "altura",
            "busco", "redes", "curiosidad"
        )
    }

    private val _profile = MutableStateFlow<Profile?>(null)
    val profile: StateFlow<Profile?> = _profile.asStateFlow()

    private val _sections = MutableStateFlow<List<ProfileSection>>(emptyList())
    val sections: StateFlow<List<ProfileSection>> = _sections.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // Hallazgo real: `follows` es totalmente funcional desde esta pasada
    // (seguir/dejar de seguir, ver FollowManager.kt) pero ningún sitio
    // mostraba cuántos seguidores/seguidos tenías — `follows_select` es
    // pública (0002_rls.sql), así que el conteo es una consulta directa.
    private val _followersCount = MutableStateFlow(0)
    val followersCount: StateFlow<Int> = _followersCount.asStateFlow()

    private val _followingCount = MutableStateFlow(0)
    val followingCount: StateFlow<Int> = _followingCount.asStateFlow()

    // Mismos contadores que PerfilViewModel.swift.loadCounters — Android
    // no tenía ninguno de los cuatro (posts/following/followers/socials
    // aceptados), no solo los dos de seguir.
    private val _postCount = MutableStateFlow(0)
    val postCount: StateFlow<Int> = _postCount.asStateFlow()

    private val _socialCount = MutableStateFlow(0)
    val socialCount: StateFlow<Int> = _socialCount.asStateFlow()

    private var userId: String? = null

    @Serializable
    private data class FollowRow(
        @SerialName("follower_id") val followerId: String,
        @SerialName("followee_id") val followeeId: String
    )

    @Serializable
    private data class IdRow(val id: String)

    fun load() {
        viewModelScope.launch {
            try {
                val id = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                userId = id
                _profile.value = SupabaseManager.client.from("profiles")
                    .select { filter { eq("id", id) } }
                    .decodeSingle<Profile>()
                _sections.value = SupabaseManager.client.from("profile_sections")
                    .select { filter { eq("profile_id", id) } }
                    .decodeList<ProfileSection>()
                _followersCount.value = SupabaseManager.client.from("follows")
                    .select { filter { eq("followee_id", id) } }
                    .decodeList<FollowRow>().size
                _followingCount.value = SupabaseManager.client.from("follows")
                    .select { filter { eq("follower_id", id) } }
                    .decodeList<FollowRow>().size
                _postCount.value = SupabaseManager.client.from("posts")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("id")) { filter { eq("author_id", id) } }
                    .decodeList<IdRow>().size
                val requested = SupabaseManager.client.from("socials")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("id")) {
                        filter { eq("requester_id", id); eq("status", "accepted") }
                    }
                    .decodeList<IdRow>().size
                val addressed = SupabaseManager.client.from("socials")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("id")) {
                        filter { eq("addressee_id", id); eq("status", "accepted") }
                    }
                    .decodeList<IdRow>().size
                _socialCount.value = requested + addressed
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el perfil: ${e.message}"
            }
        }
    }

    fun section(key: String): ProfileSection? = _sections.value.firstOrNull { it.sectionKey == key }

    @Serializable
    private data class ProfileUpdate(
        @SerialName("display_name") val displayName: String,
        val bio: String?,
        @SerialName("avatar_config") val avatarConfig: Map<String, String>
    )

    /** Hallazgo real: comparado con cualquier app grande, no había forma de
     * editar nombre/bio/look de avatar en ningún sitio — solo las 15
     * secciones (trabajo, música...) eran editables, no los campos
     * centrales del perfil. Sin selector de foto real (necesitaría cámara
     * + Storage, ver NewPostView para el patrón ya usado en publicaciones
     * — aquí se prioriza cerrar el hueco de nombre/bio/look primero, que
     * no dependía de nada más). `skin`/`hair`/`top` (busto ilustrado,
     * CartoonAvatar) sustituyen al `colorSeed` único de antes de la pasada
     * de fidelidad visual con SOCIAL_APP.html. */
    fun updateBasicInfo(displayName: String, bio: String, skin: String, hair: String, top: String) {
        val id = userId ?: return
        val trimmedName = displayName.trim()
        if (trimmedName.isBlank()) {
            _errorMessage.value = "El nombre no puede estar vacío."
            return
        }
        // Mismos límites reales que profiles_display_name_length/
        // profiles_bio_length (0023_text_length_limits.sql) — validado
        // aquí también para dar un error claro en vez de que el update
        // falle en silencio con el mensaje genérico de más abajo.
        if (trimmedName.length > 50) {
            _errorMessage.value = "El nombre no puede tener más de 50 caracteres."
            return
        }
        if (bio.length > 300) {
            _errorMessage.value = "La bio no puede tener más de 300 caracteres."
            return
        }
        val currentConfig = _profile.value?.avatarConfig ?: emptyMap()
        val newConfig = currentConfig + mapOf("type" to "cartoon", "skin" to skin, "hair" to hair, "top" to top)
        _profile.value = _profile.value?.copy(
            displayName = trimmedName,
            bio = bio.ifBlank { null },
            avatarConfig = newConfig
        )
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("profiles")
                    .update(ProfileUpdate(trimmedName, bio.ifBlank { null }, newConfig)) { filter { eq("id", id) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar el perfil."
            }
        }
    }

    @Serializable
    private data class SectionUpsert(
        @SerialName("profile_id") val profileId: String,
        @SerialName("section_key") val sectionKey: String,
        val content: Map<String, String>,
        @SerialName("is_public") val isPublic: Boolean
    )

    /** Crea o actualiza una sección (upsert por la unique constraint
     * `(profile_id, section_key)`). Actualización optimista — misma
     * estrategia que PerfilViewModel.swift.saveSection. */
    fun saveSection(key: String, text: String, isPublic: Boolean) {
        val id = userId ?: return
        // Mismo límite real que profile_sections_texto_length
        // (0024_more_text_length_limits.sql) — validado aquí también,
        // mismo criterio ya aplicado a nombre/bio/caption/mensaje/comentario.
        if (text.length > 2000) {
            _errorMessage.value = "El texto no puede tener más de 2000 caracteres."
            return
        }
        val existingIndex = _sections.value.indexOfFirst { it.sectionKey == key }
        val optimistic = ProfileSection(
            id = _sections.value.getOrNull(existingIndex)?.id ?: java.util.UUID.randomUUID().toString(),
            profileId = id,
            sectionKey = key,
            content = mapOf("texto" to text),
            isPublic = isPublic
        )
        _sections.value = if (existingIndex >= 0) {
            _sections.value.toMutableList().also { it[existingIndex] = optimistic }
        } else {
            _sections.value + optimistic
        }

        viewModelScope.launch {
            try {
                SupabaseManager.client.from("profile_sections")
                    .upsert(SectionUpsert(id, key, mapOf("texto" to text), isPublic), onConflict = "profile_id,section_key")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo guardar '$key': ${e.message}"
            }
        }
    }
}
