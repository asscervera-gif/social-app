package com.social.app.screens.home

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.StorageUploader
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

@Serializable
data class StoryRow(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("media_url") val mediaUrl: String,
    @SerialName("created_at") val createdAt: String
)

data class StoryGroup(val authorId: String, val authorName: String, val stories: List<StoryRow>)

/**
 * Historias — hueco documentado toda la sesión como "bloqueado por
 * Storage", ya no es cierto (ver StorageUploader.kt). El esquema y RLS ya
 * estaban completos desde 0001/0002 (`expires_at default now()+24h`,
 * `stories_select using (expires_at > now())` filtra caducadas a nivel de
 * base de datos, sin necesitar lógica de cliente para ocultarlas) — solo
 * faltaba el cliente entero: crear y ver.
 */
class StoriesViewModel : ViewModel() {

    private val _groups = MutableStateFlow<List<StoryGroup>>(emptyList())
    val groups: StateFlow<List<StoryGroup>> = _groups.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading: StateFlow<Boolean> = _isUploading.asStateFlow()

    @Serializable
    private data class NameRow(@SerialName("display_name") val displayName: String)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    fun load() {
        viewModelScope.launch {
            try {
                // RLS ya excluye las caducadas (`expires_at > now()`) — no
                // hace falta filtrar en cliente.
                //
                // Hallazgo real: Historias nunca filtraba historias de
                // gente bloqueada — mismo refuerzo de privacidad ya
                // aplicado en Home/Match/Find/Search/ChatList/Guardados/
                // Tus socials.
                val blockedIds = try {
                    SupabaseManager.client.from("blocks")
                        .select(columns = Columns.raw("blocked_id"))
                        .decodeList<BlockRow>()
                        .map { it.blockedId }
                        .toSet()
                } catch (e: Exception) {
                    emptySet()
                }
                val stories = SupabaseManager.client.from("stories")
                    .select(columns = Columns.raw("id,author_id,media_url,created_at")) {
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<StoryRow>()
                    .filter { it.authorId !in blockedIds }

                _groups.value = stories.groupBy { it.authorId }.map { (authorId, authorStories) ->
                    val name = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name")) { filter { eq("id", authorId) } }
                            .decodeSingleOrNull<NameRow>()?.displayName
                    } catch (e: Exception) {
                        null
                    } ?: "Perfil"
                    StoryGroup(authorId, name, authorStories)
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las historias."
            }
        }
    }

    @Serializable
    private data class NewStory(
        @SerialName("author_id") val authorId: String,
        @SerialName("media_url") val mediaUrl: String
    )

    @Serializable
    private data class NewStoryView(
        @SerialName("story_id") val storyId: String,
        @SerialName("viewer_id") val viewerId: String
    )

    /**
     * "Quién vio tu historia" (0053_story_views.sql), comparado con
     * Instagram/Snapchat/WhatsApp Status. No se registra al ver tu propia
     * historia (no tendría sentido contarte a ti mismo como espectador).
     * `unique(story_id, viewer_id)` puede lanzar si ya se registró antes
     * -- no es un error real, el estado deseado ya se cumple.
     */
    fun recordView(story: StoryRow) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            if (userId == story.authorId) return@launch
            try {
                SupabaseManager.client.from("story_views").insert(NewStoryView(story.id, userId))
            } catch (e: Exception) {
                // Ya registrada (unique constraint) u otro fallo no
                // crítico -- ver la historia no debe romperse por esto.
            }
        }
    }

    @Serializable
    data class StoryViewer(val id: String, val displayName: String)

    @Serializable
    private data class ViewerIdRow(@SerialName("viewer_id") val viewerId: String)

    @Serializable
    private data class ViewerNameRow(val id: String, @SerialName("display_name") val displayName: String)

    /** Solo tiene sentido llamarlo sobre tu propia historia -- RLS
     * (`story_views_select_own_story`) ya lo exige, esta función no
     * duplica esa comprobación en cliente. */
    suspend fun loadViewers(storyId: String): List<StoryViewer> {
        return try {
            val viewerIds = SupabaseManager.client.from("story_views")
                .select(columns = Columns.raw("viewer_id")) { filter { eq("story_id", storyId) } }
                .decodeList<ViewerIdRow>()
                .map { it.viewerId }
            if (viewerIds.isEmpty()) return emptyList()
            SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name")) { filter { isIn("id", viewerIds) } }
                .decodeList<ViewerNameRow>()
                .map { StoryViewer(it.id, it.displayName) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun createStory(context: Context, uri: Uri, onDone: () -> Unit) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            _isUploading.value = true
            try {
                val url = StorageUploader.uploadImage(context, uri, userId)
                SupabaseManager.client.from("stories").insert(NewStory(userId, url))
                // Hallazgo real, mismo criterio ya aplicado a
                // post_created/signup_completed: publicar una historia no
                // se registraba, dejando un hueco en cualquier análisis
                // de qué tan usada está la función.
                com.social.app.backend.AnalyticsManager.track("story_created")
                load()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo subir la historia."
            } finally {
                _isUploading.value = false
                onDone()
            }
        }
    }
}
