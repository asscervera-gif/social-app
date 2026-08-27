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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class StoryRow(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("media_url") val mediaUrl: String,
    @SerialName("created_at") val createdAt: String,
    // "Mejores amigos" real (0075_close_friends_stories.sql), comparado
    // con Instagram/Snapchat -- decodificado aunque el cliente no lo
    // necesite para filtrar (RLS ya decide quién ve qué fila en absoluto),
    // solo para poder mostrarlo si hiciera falta más adelante.
    val visibility: String = "everyone"
)

// Adhesivo de pregunta real en una historia ("Pregúntame algo"),
// comparado con Instagram -- ver 0099_story_questions.sql.
@Serializable
data class StoryQuestionRow(
    val id: String,
    @SerialName("story_id") val storyId: String,
    val prompt: String
)

data class StoryGroup(
    val authorId: String,
    val authorName: String,
    val stories: List<StoryRow>,
    // Silenciar las historias de alguien sin dejar de seguirlo, comparado
    // con Instagram/Snapchat -- preferencia personal de orden/atenuación
    // en la propia bandeja, NO control de acceso (0085_muted_story_authors.sql,
    // `stories_select` no cambia: sigue siendo tan accesible como siempre).
    val isMuted: Boolean = false
)

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

    // Silenciar las historias de alguien sin dejar de seguirlo, comparado
    // con Instagram/Snapchat (0085_muted_story_authors.sql).
    private val _mutedAuthorIds = MutableStateFlow<Set<String>>(emptySet())
    val mutedAuthorIds: StateFlow<Set<String>> = _mutedAuthorIds.asStateFlow()

    // Adhesivo de pregunta real en una historia ("Pregúntame algo"),
    // comparado con Instagram -- una por story_id como mucho, ver
    // 0099_story_questions.sql.
    private val _storyQuestions = MutableStateFlow<Map<String, StoryQuestionRow>>(emptyMap())
    val storyQuestions: StateFlow<Map<String, StoryQuestionRow>> = _storyQuestions.asStateFlow()

    @Serializable
    private data class NameRow(@SerialName("display_name") val displayName: String)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    @Serializable
    private data class MutedStoryAuthorRow(@SerialName("muted_id") val mutedId: String)

    @Serializable
    private data class NewMutedStoryAuthor(
        @SerialName("muter_id") val muterId: String,
        @SerialName("muted_id") val mutedId: String
    )

    /** Silenciar/dejar de silenciar las historias reales de una persona,
     * comparado con Instagram/Snapchat -- NO es un bloqueo ni afecta
     * `stories_select`, solo el orden/atenuación en la propia bandeja
     * (`muted_story_authors_insert/_delete`, 0085_muted_story_authors.sql,
     * ya garantizan del lado del servidor que solo se toca la lista
     * propia). */
    fun toggleMuteAuthor(authorId: String) {
        val currentlyMuted = _mutedAuthorIds.value.contains(authorId)
        _mutedAuthorIds.update { if (currentlyMuted) it - authorId else it + authorId }
        _groups.update { list ->
            list.map { if (it.authorId == authorId) it.copy(isMuted = !currentlyMuted) else it }
                .sortedBy { it.isMuted }
        }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                if (currentlyMuted) {
                    SupabaseManager.client.from("muted_story_authors").delete {
                        filter { eq("muter_id", userId); eq("muted_id", authorId) }
                    }
                } else {
                    SupabaseManager.client.from("muted_story_authors").insert(NewMutedStoryAuthor(userId, authorId))
                }
            } catch (e: Exception) {
                // No crítico: si falla, la próxima carga real reconcilia
                // el estado con el servidor.
            }
        }
    }

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
                    .select(columns = Columns.raw("id,author_id,media_url,created_at,visibility")) {
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<StoryRow>()
                    .filter { it.authorId !in blockedIds }

                // Silenciar las historias de alguien sin dejar de
                // seguirlo, comparado con Instagram/Snapchat
                // (0085_muted_story_authors.sql) -- lista propia, nunca
                // visible para nadie más.
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
                val mutedIds = if (myId != null) {
                    try {
                        SupabaseManager.client.from("muted_story_authors")
                            .select(columns = Columns.raw("muted_id")) { filter { eq("muter_id", myId) } }
                            .decodeList<MutedStoryAuthorRow>()
                            .map { it.mutedId }
                            .toSet()
                    } catch (e: Exception) {
                        emptySet()
                    }
                } else {
                    emptySet()
                }
                _mutedAuthorIds.value = mutedIds

                // Adhesivo de pregunta real en una historia ("Pregúntame
                // algo"), comparado con Instagram -- se carga junto con
                // el resto de historias, en vez de una consulta aparte
                // por cada una al abrirlas.
                _storyQuestions.value = if (stories.isEmpty()) emptyMap() else try {
                    SupabaseManager.client.from("story_questions")
                        .select(columns = Columns.raw("id,story_id,prompt")) { filter { isIn("story_id", stories.map { it.id }) } }
                        .decodeList<StoryQuestionRow>()
                        .associateBy { it.storyId }
                } catch (e: Exception) {
                    emptyMap()
                }

                val groups = stories.groupBy { it.authorId }.map { (authorId, authorStories) ->
                    val name = try {
                        SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("display_name")) { filter { eq("id", authorId) } }
                            .decodeSingleOrNull<NameRow>()?.displayName
                    } catch (e: Exception) {
                        null
                    } ?: "Perfil"
                    StoryGroup(authorId, name, authorStories, isMuted = authorId in mutedIds)
                }
                // Silenciado se manda al final de la bandeja, atenuado en
                // el cliente -- nunca oculto del todo, mismo criterio real
                // que Instagram/Snapchat (a diferencia de un bloqueo).
                _groups.value = groups.sortedBy { it.isMuted }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las historias."
            }
        }
    }

    @Serializable
    private data class NewStory(
        @SerialName("author_id") val authorId: String,
        @SerialName("media_url") val mediaUrl: String,
        val visibility: String
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

    // "Mejores amigos" real (0075_close_friends_stories.sql), comparado
    // con Instagram/Snapchat -- `visibility` elegido por el usuario al
    // subir, "everyone" por defecto (mismo comportamiento de siempre).
    @Serializable
    private data class NewStoryQuestion(
        @SerialName("story_id") val storyId: String,
        val prompt: String
    )

    /** [questionPrompt] es opcional -- el adhesivo de pregunta real
     * ("Pregúntame algo", 0099_story_questions.sql), comparado con
     * Instagram, no es obligatorio en ninguna historia. */
    fun createStory(context: Context, uri: Uri, visibility: String = "everyone", questionPrompt: String? = null, onDone: () -> Unit) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            _isUploading.value = true
            try {
                val url = StorageUploader.uploadImage(context, uri, userId)
                val insertedStory = SupabaseManager.client.from("stories")
                    .insert(NewStory(userId, url, visibility)) { select() }
                    .decodeSingle<StoryRow>()
                // Mismo límite real del CHECK de story_questions.prompt
                // (0099_story_questions.sql): 200 caracteres.
                val trimmedPrompt = questionPrompt?.trim()?.take(200)
                if (!trimmedPrompt.isNullOrEmpty()) {
                    SupabaseManager.client.from("story_questions").insert(NewStoryQuestion(insertedStory.id, trimmedPrompt))
                }
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

    @Serializable
    private data class NewStoryReply(
        @SerialName("chat_id") val chatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String,
        @SerialName("story_id") val storyId: String
    )

    /** Responder a una historia real (0071_message_story_reply.sql),
     * comparado con Instagram/WhatsApp Status/Snapchat -- manda la
     * respuesta como un mensaje directo real a quien publicó la historia.
     * `chatId` ya resuelto por el llamador (StoriesBar.kt, vía
     * `SocialLinkManager.getOrCreateChat`, el mismo usado para "Enviar
     * mensaje" desde un aviso) -- esta función solo inserta el mensaje. */
    suspend fun sendReply(chatId: String, storyId: String, text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length > 2000) return false
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return false
        return try {
            SupabaseManager.client.from("messages").insert(NewStoryReply(chatId, userId, trimmed, storyId))
            com.social.app.backend.AnalyticsManager.track("story_replied")
            true
        } catch (e: Exception) {
            false
        }
    }

    @Serializable
    private data class NewStoryQuestionResponse(
        @SerialName("question_id") val questionId: String,
        @SerialName("responder_id") val responderId: String,
        val body: String
    )

    /** Responder en privado a la pregunta real de una historia ajena
     * ("Pregúntame algo"), comparado con Instagram -- a diferencia de
     * sendReply() (arriba), esto NO manda un mensaje de chat normal:
     * solo el autor real de la historia ve la respuesta, con quién la
     * escribió (`story_question_responses_select`, 0099_story_questions.sql). */
    suspend fun respondToQuestion(questionId: String, text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length > 500) return false
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return false
        return try {
            SupabaseManager.client.from("story_question_responses").insert(NewStoryQuestionResponse(questionId, userId, trimmed))
            com.social.app.backend.AnalyticsManager.track("story_question_answered")
            true
        } catch (e: Exception) {
            false
        }
    }

    data class StoryQuestionResponse(val responderName: String, val body: String)

    @Serializable
    private data class ResponseRow(
        @SerialName("responder_id") val responderId: String,
        val body: String
    )

    /** Solo tiene sentido llamarlo sobre una pregunta de tu propia
     * historia -- RLS (`story_question_responses_select`) ya lo exige,
     * esta función no duplica esa comprobación en cliente. Mismo patrón
     * que loadViewers(). */
    suspend fun loadQuestionResponses(questionId: String): List<StoryQuestionResponse> {
        return try {
            val rows = SupabaseManager.client.from("story_question_responses")
                .select(columns = Columns.raw("responder_id,body")) { filter { eq("question_id", questionId) } }
                .decodeList<ResponseRow>()
            if (rows.isEmpty()) return emptyList()
            val names = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name")) { filter { isIn("id", rows.map { it.responderId }) } }
                .decodeList<ViewerNameRow>()
                .associateBy { it.id }
            rows.map { StoryQuestionResponse(names[it.responderId]?.displayName ?: "Alguien", it.body) }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
