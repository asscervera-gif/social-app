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
    val visibility: String = "everyone",
    // Texto sobre la Historia + @menciones reales ahí, comparado con
    // Instagram/TikTok/Snapchat -- ver 0143_story_caption_mentions.sql.
    val caption: String? = null,
    // Sticker de enlace real ("swipe up"), comparado con Instagram
    // Stories/TikTok/Snapchat -- ver 0146_story_link.sql.
    @SerialName("link_url") val linkUrl: String? = null,
    // Sticker de cuenta atrás real, comparado con Instagram (Countdown)/
    // Snapchat -- ver 0147_story_countdown.sql.
    @SerialName("countdown_label") val countdownLabel: String? = null,
    @SerialName("countdown_target_at") val countdownTargetAt: String? = null
)

// Adhesivo de pregunta real en una historia ("Pregúntame algo"),
// comparado con Instagram -- ver 0099_story_questions.sql.
@Serializable
data class StoryQuestionRow(
    val id: String,
    @SerialName("story_id") val storyId: String,
    val prompt: String
)

// Encuesta real en una historia, comparado con Instagram/Twitter/X --
// ver 0100_story_polls.sql.
@Serializable
data class StoryPollRow(
    val id: String,
    @SerialName("story_id") val storyId: String,
    val question: String,
    val options: List<String>,
    @SerialName("vote_counts") val voteCounts: List<Int> = emptyList()
)

// Destacados reales de historias en el perfil, comparado con Instagram --
// ver 0101_story_highlights.sql.
@Serializable
data class StoryHighlightRow(
    val id: String,
    @SerialName("author_id") val authorId: String,
    val title: String,
    @SerialName("cover_story_id") val coverStoryId: String? = null
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

    // Encuesta real en una historia, comparado con Instagram/Twitter/X --
    // una por story_id como mucho, ver 0100_story_polls.sql.
    private val _storyPolls = MutableStateFlow<Map<String, StoryPollRow>>(emptyMap())
    val storyPolls: StateFlow<Map<String, StoryPollRow>> = _storyPolls.asStateFlow()

    // Mi propio voto real por encuesta (poll_id -> option_index), para
    // saber si ya voté y en qué opción, sin depender de recargar toda la
    // bandeja tras votar.
    private val _myPollVotes = MutableStateFlow<Map<String, Int>>(emptyMap())
    val myPollVotes: StateFlow<Map<String, Int>> = _myPollVotes.asStateFlow()

    // Destacados reales de historias en el perfil, comparado con
    // Instagram -- solo los MÍOS (para poder elegir a cuál añadir una
    // historia real activa desde el visor), ver 0101_story_highlights.sql.
    private val _myHighlights = MutableStateFlow<List<StoryHighlightRow>>(emptyList())
    val myHighlights: StateFlow<List<StoryHighlightRow>> = _myHighlights.asStateFlow()

    @Serializable
    private data class NameRow(@SerialName("display_name") val displayName: String)

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    @Serializable
    private data class MutedStoryAuthorRow(@SerialName("muted_id") val mutedId: String)

    @Serializable
    private data class MyVoteRow(
        @SerialName("poll_id") val pollId: String,
        @SerialName("option_index") val optionIndex: Int
    )

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

                // Encuesta real en una historia, comparado con
                // Instagram/Twitter/X -- se carga junto con el resto,
                // igual que la pregunta de arriba.
                val polls = if (stories.isEmpty()) emptyList() else try {
                    SupabaseManager.client.from("story_polls")
                        .select(columns = Columns.raw("id,story_id,question,options,vote_counts")) { filter { isIn("story_id", stories.map { it.id }) } }
                        .decodeList<StoryPollRow>()
                } catch (e: Exception) {
                    emptyList()
                }
                _storyPolls.value = polls.associateBy { it.storyId }
                _myPollVotes.value = if (polls.isEmpty() || myId == null) emptyMap() else try {
                    SupabaseManager.client.from("story_poll_votes")
                        .select(columns = Columns.raw("poll_id,option_index")) { filter { eq("voter_id", myId); isIn("poll_id", polls.map { it.id }) } }
                        .decodeList<MyVoteRow>()
                        .associate { it.pollId to it.optionIndex }
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

                // Destacados reales de historias en el perfil, comparado
                // con Instagram -- solo los propios, para poder elegir a
                // cuál añadir una historia activa desde el visor.
                _myHighlights.value = if (myId == null) emptyList() else try {
                    SupabaseManager.client.from("story_highlights")
                        .select(columns = Columns.raw("id,author_id,title,cover_story_id")) { filter { eq("author_id", myId) } }
                        .decodeList<StoryHighlightRow>()
                } catch (e: Exception) {
                    emptyList()
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las historias."
            }
        }
    }

    @Serializable
    private data class NewStory(
        @SerialName("author_id") val authorId: String,
        @SerialName("media_url") val mediaUrl: String,
        val visibility: String,
        // Texto sobre la Historia + @menciones reales ahí, comparado con
        // Instagram/TikTok/Snapchat -- ver 0143_story_caption_mentions.sql.
        val caption: String? = null,
        // Sticker de enlace real ("swipe up"), comparado con Instagram
        // Stories/TikTok/Snapchat -- ver 0146_story_link.sql.
        @SerialName("link_url") val linkUrl: String? = null,
        // Sticker de cuenta atrás real, comparado con Instagram
        // (Countdown)/Snapchat -- ver 0147_story_countdown.sql.
        @SerialName("countdown_label") val countdownLabel: String? = null,
        @SerialName("countdown_target_at") val countdownTargetAt: String? = null
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
    private data class NewStoryLinkClick(
        @SerialName("story_id") val storyId: String,
        @SerialName("user_id") val userId: String
    )

    /** Registrar un clic real en el sticker de enlace ("swipe up"),
     * comparado con Instagram Stories/TikTok/Snapchat -- ver
     * 0146_story_link.sql. Mismo criterio real que recordView(): no
     * crítico si falla, abrir el enlace no debe bloquearse por esto. */
    fun recordLinkClick(story: StoryRow) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("story_link_clicks").insert(NewStoryLinkClick(story.id, userId))
            } catch (e: Exception) {
                // Ya registrado (unique constraint) u otro fallo no
                // crítico.
            }
        }
    }

    @Serializable
    private data class NewCountdownReminder(
        @SerialName("story_id") val storyId: String,
        @SerialName("user_id") val userId: String
    )

    private val _remindedStoryIds = MutableStateFlow<Set<String>>(emptySet())
    val remindedStoryIds: StateFlow<Set<String>> = _remindedStoryIds.asStateFlow()

    /** "Recordarme" real de un sticker de cuenta atrás, comparado con
     * Instagram (Countdown)/Snapchat -- ver 0147_story_countdown.sql.
     * Aviso de honestidad: SIN pg_cron, el aviso real solo se genera la
     * próxima vez que ESTE usuario abra la app tras vencer el plazo
     * (ver notifyDueCountdowns(), llamada desde HomeViewModel.load()). */
    fun setCountdownReminder(story: StoryRow) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("story_countdown_reminders").insert(NewCountdownReminder(story.id, userId))
                _remindedStoryIds.update { it + story.id }
            } catch (e: Exception) {
                // Ya registrado (unique constraint) u otro fallo no crítico.
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
    @Serializable
    private data class NewStoryPoll(
        @SerialName("story_id") val storyId: String,
        val question: String,
        val options: List<String>
    )

    /** [pollQuestion]/[pollOptions] son opcionales -- la encuesta real
     * ("Encuesta", 0100_story_polls.sql), comparado con Instagram/
     * Twitter/X, no es obligatoria en ninguna historia. [pollOptions]
     * necesita entre 2 y 4 opciones reales (mismo límite del CHECK de
     * story_polls.options) para llegar a insertarse -- si no las
     * cumple, la encuesta simplemente no se crea (la historia en sí
     * sigue publicándose con normalidad). */
    fun createStory(context: Context, uri: Uri, visibility: String = "everyone", caption: String? = null, linkUrl: String? = null, countdownLabel: String? = null, countdownTargetAt: String? = null, questionPrompt: String? = null, pollQuestion: String? = null, pollOptions: List<String> = emptyList(), onDone: () -> Unit) {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            _isUploading.value = true
            try {
                val url = StorageUploader.uploadImage(context, uri, userId)
                // Mismo límite real que posts_caption_length
                // (0023_text_length_limits.sql) -- validado también en
                // el resto de superficies con @menciones (posts/reels/
                // comments).
                val trimmedCaption = caption?.trim()?.take(2200)?.ifEmpty { null }
                // Sticker de enlace real ("swipe up"), comparado con
                // Instagram Stories/TikTok/Snapchat -- mismo límite y
                // patrón real del CHECK de stories.link_url
                // (0146_story_link.sql): debe empezar por http(s)://,
                // si no lo cumple simplemente se descarta (la historia
                // en sí sigue publicándose con normalidad).
                val trimmedLink = linkUrl?.trim()?.take(500)?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
                // Sticker de cuenta atrás real, comparado con Instagram
                // (Countdown)/Snapchat -- solo se manda si hay AMBOS,
                // etiqueta y fecha real (mismo límite real del CHECK de
                // stories.countdown_label, 0147_story_countdown.sql: 60
                // caracteres).
                val trimmedCountdownLabel = countdownLabel?.trim()?.take(60)?.ifEmpty { null }
                val finalCountdownLabel = if (countdownTargetAt != null) trimmedCountdownLabel else null
                val finalCountdownTargetAt = if (trimmedCountdownLabel != null) countdownTargetAt else null
                val insertedStory = SupabaseManager.client.from("stories")
                    .insert(NewStory(userId, url, visibility, trimmedCaption, trimmedLink, finalCountdownLabel, finalCountdownTargetAt)) { select() }
                    .decodeSingle<StoryRow>()
                // Mismo límite real del CHECK de story_questions.prompt
                // (0099_story_questions.sql): 200 caracteres.
                val trimmedPrompt = questionPrompt?.trim()?.take(200)
                if (!trimmedPrompt.isNullOrEmpty()) {
                    SupabaseManager.client.from("story_questions").insert(NewStoryQuestion(insertedStory.id, trimmedPrompt))
                }
                val trimmedPollQuestion = pollQuestion?.trim()?.take(200)
                val cleanOptions = pollOptions.map { it.trim() }.filter { it.isNotEmpty() }
                if (!trimmedPollQuestion.isNullOrEmpty() && cleanOptions.size in 2..4) {
                    SupabaseManager.client.from("story_polls").insert(NewStoryPoll(insertedStory.id, trimmedPollQuestion, cleanOptions))
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

    @Serializable
    private data class NewPollVote(
        @SerialName("poll_id") val pollId: String,
        @SerialName("voter_id") val voterId: String,
        @SerialName("option_index") val optionIndex: Int
    )

    /** Votar/cambiar de opción real en una encuesta de una historia,
     * comparado con Instagram/Twitter/X -- `upsert` con
     * `onConflict = "poll_id,voter_id"` porque `unique(poll_id,
     * voter_id)` (0100_story_polls.sql) ya impide un segundo voto:
     * cambiar de opción es un UPDATE real de la fila propia, no un
     * intento de insertar dos veces. El reparto real (`vote_counts`) lo
     * recalcula el propio trigger del servidor -- este cliente solo
     * refleja optimistamente MI voto, `load()` trae el reparto real
     * actualizado en la siguiente carga. */
    fun voteOnPoll(pollId: String, optionIndex: Int) {
        _myPollVotes.update { it + (pollId to optionIndex) }
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                SupabaseManager.client.from("story_poll_votes")
                    .upsert(NewPollVote(pollId, userId, optionIndex), onConflict = "poll_id,voter_id")
                // Refleja el reparto real recién recalculado por el
                // trigger del servidor, sin recargar toda la bandeja.
                val updated = SupabaseManager.client.from("story_polls")
                    .select(columns = Columns.raw("id,story_id,question,options,vote_counts")) { filter { eq("id", pollId) } }
                    .decodeSingleOrNull<StoryPollRow>()
                if (updated != null) {
                    _storyPolls.update { it + (updated.storyId to updated) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo registrar el voto."
            }
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

    @Serializable
    private data class NewHighlight(
        @SerialName("author_id") val authorId: String,
        val title: String,
        @SerialName("cover_story_id") val coverStoryId: String
    )

    @Serializable
    private data class NewHighlightItem(
        @SerialName("highlight_id") val highlightId: String,
        @SerialName("story_id") val storyId: String
    )

    /** Crea un destacado real NUEVO a partir de una historia real propia
     * activa, comparado con Instagram -- solo tiene sentido sobre tu
     * propia historia (RLS ya lo exige por partida doble: dueño real del
     * destacado Y de la historia, 0101_story_highlights.sql). Alcance
     * deliberado: siempre crea un destacado nuevo, sin ofrecer añadir a
     * uno ya existente desde este mismo diálogo -- eso sigue siendo un
     * hueco real aparte, documentado en LOOP_STATE.md. */
    fun createHighlight(storyId: String, title: String, onDone: () -> Unit = {}) {
        val trimmed = title.trim().take(50)
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val created = SupabaseManager.client.from("story_highlights")
                    .insert(NewHighlight(userId, trimmed, storyId)) { select() }
                    .decodeSingle<StoryHighlightRow>()
                SupabaseManager.client.from("story_highlight_items")
                    .insert(NewHighlightItem(created.id, storyId))
                _myHighlights.update { it + created }
                com.social.app.backend.AnalyticsManager.track("story_highlight_created")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo crear el destacado."
            } finally {
                onDone()
            }
        }
    }

    /** Añadir una historia real a un destacado YA EXISTENTE, comparado con
     * Instagram -- cierra el hueco deliberado documentado en
     * createHighlight() de arriba. Misma tabla real
     * (story_highlight_items, 0101_story_highlights.sql), sin migración:
     * el propio RLS ya exige ser dueño real tanto del destacado como de
     * la historia. La portada del destacado no se toca -- solo la del
     * destacado recién CREADO se fija (mismo criterio ya establecido). */
    fun addStoryToHighlight(highlightId: String, storyId: String, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("story_highlight_items")
                    .insert(NewHighlightItem(highlightId, storyId))
                com.social.app.backend.AnalyticsManager.track("story_added_to_highlight")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo añadir al destacado."
            } finally {
                onDone()
            }
        }
    }
}
