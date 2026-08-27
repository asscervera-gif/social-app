package com.social.app.screens.perfil

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.rememberAsyncImagePainter
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class HighlightRow(
    val id: String,
    val title: String,
    @SerialName("cover_story_id") val coverStoryId: String? = null
)

@Serializable
private data class HighlightItemRow(@SerialName("story_id") val storyId: String)

@Serializable
private data class StoryMediaRow(val id: String, @SerialName("media_url") val mediaUrl: String)

/**
 * Destacados reales de historias en el perfil, comparado con Instagram --
 * fila de círculos justo debajo de la bio, igual en el propio perfil
 * (PerfilScreen.kt) que en el ajeno (ProfileViewerScreen.kt), reutilizada
 * tal cual en los dos porque la visibilidad ya la decide RLS
 * (0101_story_highlights.sql: `story_highlights_select`/`stories_select`
 * son las mismas para cualquiera que consulte, incluido el propio dueño).
 * No se muestra ninguna fila si la persona no tiene ningún destacado
 * todavía -- nunca un hueco vacío ni un texto de "sin destacados".
 */
@Composable
fun StoryHighlightsRow(profileId: String) {
    var highlights by remember(profileId) { mutableStateOf<List<HighlightRow>>(emptyList()) }
    var covers by remember(profileId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var openHighlight by remember { mutableStateOf<HighlightRow?>(null) }

    LaunchedEffect(profileId) {
        val rows = try {
            SupabaseManager.client.from("story_highlights")
                .select(columns = Columns.raw("id,title,cover_story_id")) { filter { eq("author_id", profileId) } }
                .decodeList<HighlightRow>()
        } catch (e: Exception) {
            emptyList()
        }
        highlights = rows
        val coverIds = rows.mapNotNull { it.coverStoryId }
        covers = if (coverIds.isEmpty()) emptyMap() else try {
            SupabaseManager.client.from("stories")
                .select(columns = Columns.raw("id,media_url")) { filter { isIn("id", coverIds) } }
                .decodeList<StoryMediaRow>()
                .associate { it.id to it.mediaUrl }
        } catch (e: Exception) {
            emptyMap()
        }
    }

    if (highlights.isEmpty()) return

    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        items(highlights) { highlight ->
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.clickable { openHighlight = highlight }
            ) {
                val coverUrl = highlight.coverStoryId?.let { covers[it] }
                Box(
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center
                ) {
                    if (coverUrl != null) {
                        Image(
                            painter = rememberAsyncImagePainter(coverUrl),
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.size(64.dp).clip(CircleShape)
                        )
                    } else {
                        Text("⭐")
                    }
                }
                Text(
                    highlight.title,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    modifier = Modifier.widthIn(max = 64.dp).padding(top = 4.dp)
                )
            }
        }
    }

    openHighlight?.let { highlight ->
        HighlightViewer(highlight = highlight, onDismiss = { openHighlight = null })
    }
}

/**
 * Visor minimalista de un destacado real -- alcance deliberado, distinto
 * del visor de una historia activa (StoriesBar.kt.StoryViewer): solo
 * pasa las fotos reales una a una al tocar, sin las barras de progreso ni
 * los adhesivos interactivos (encuesta/pregunta/responder) de una
 * historia activa. Añadir esa paridad completa es un hueco real aparte,
 * documentado en LOOP_STATE.md.
 */
@Composable
private fun HighlightViewer(highlight: HighlightRow, onDismiss: () -> Unit) {
    var mediaUrls by remember(highlight.id) { mutableStateOf<List<String>>(emptyList()) }
    var index by remember(highlight.id) { mutableStateOf(0) }

    LaunchedEffect(highlight.id) {
        try {
            val storyIds = SupabaseManager.client.from("story_highlight_items")
                .select(columns = Columns.raw("story_id")) { filter { eq("highlight_id", highlight.id) } }
                .decodeList<HighlightItemRow>()
                .map { it.storyId }
            mediaUrls = if (storyIds.isEmpty()) emptyList() else SupabaseManager.client.from("stories")
                .select(columns = Columns.raw("id,media_url")) { filter { isIn("id", storyIds) } }
                .decodeList<StoryMediaRow>()
                .map { it.mediaUrl }
        } catch (e: Exception) {
            mediaUrls = emptyList()
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            val url = mediaUrls.getOrNull(index)
            if (url != null) {
                Image(
                    painter = rememberAsyncImagePainter(url),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize().clickable {
                        if (index < mediaUrls.lastIndex) index += 1 else onDismiss()
                    }
                )
            }
            Text(
                highlight.title,
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.align(Alignment.TopStart).padding(16.dp)
            )
        }
    }
}
