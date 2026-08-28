package com.social.app.screens.perfil

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.rememberAsyncImagePainter
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.launch
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
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun StoryHighlightsRow(profileId: String) {
    var highlights by remember(profileId) { mutableStateOf<List<HighlightRow>>(emptyList()) }
    var covers by remember(profileId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var openHighlight by remember { mutableStateOf<HighlightRow?>(null) }
    // Borrar un destacado completo real, comparado con Instagram
    // (mantener pulsado el círculo -> "Eliminar destacado") -- hallazgo
    // real: un destacado creado quedaba para siempre sin salida real.
    // Solo tiene sentido sobre el propio perfil.
    var myId by remember { mutableStateOf<String?>(null) }
    var deletingHighlight by remember { mutableStateOf<HighlightRow?>(null) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(Unit) {
        myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    }

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
                modifier = Modifier.combinedClickable(
                    onClick = { openHighlight = highlight },
                    onLongClick = { if (profileId == myId) deletingHighlight = highlight }
                )
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

    deletingHighlight?.let { highlight ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { deletingHighlight = null },
            title = { Text("¿Borrar \"${highlight.title}\"?") },
            text = { Text("Esto borra el destacado completo. Las historias en sí no se ven afectadas.") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    highlights = highlights.filter { it.id != highlight.id }
                    deletingHighlight = null
                    scope.launch {
                        try {
                            SupabaseManager.client.from("story_highlights").delete { filter { eq("id", highlight.id) } }
                        } catch (e: Exception) {
                        }
                    }
                }) { Text("Borrar") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { deletingHighlight = null }) { Text("Cancelar") }
            }
        )
    }
}

/**
 * Visor de un destacado real, comparado con Instagram -- ahora con las
 * mismas barras de progreso segmentadas y avance automático que el visor
 * de una historia activa (StoriesBar.kt.StoryViewer, mismo patrón real
 * reutilizado: 5s por foto, Animatable + pasos de 50ms). Cierra el hueco
 * deliberado documentado hasta ahora en este mismo archivo. Los
 * adhesivos interactivos (encuesta/pregunta/responder) de una historia
 * activa siguen fuera de alcance a propósito -- un destacado ya no tiene
 * sentido real para responder/votar, esas piezas eran efímeras.
 */
@Composable
private fun HighlightViewer(highlight: HighlightRow, onDismiss: () -> Unit) {
    var mediaUrls by remember(highlight.id) { mutableStateOf<List<String>>(emptyList()) }
    var index by remember(highlight.id) { mutableStateOf(0) }
    val progress = remember(index) { androidx.compose.animation.core.Animatable(0f) }

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

    fun goNext() {
        if (index < mediaUrls.lastIndex) index += 1 else onDismiss()
    }
    fun goPrevious() {
        if (index > 0) index -= 1
    }

    // Mismo criterio real que StoriesBar.kt.StoryViewer: 5s por foto,
    // cancelado sin avance doble por el cambio de `index` cuando se
    // avanza a mano.
    // Con clave (index, mediaUrls) en vez de solo `index`: sin esto, el
    // avance automático nunca arrancaría -- las fotos reales llegan de
    // forma asíncrona DESPUÉS de que este efecto ya se disparó una vez
    // con la lista todavía vacía, y `LaunchedEffect(index)` no se vuelve
    // a lanzar solo porque cambie el contenido de `mediaUrls` con el
    // mismo `index` (0). Hallazgo real, encontrado escribiendo esta misma
    // ronda.
    LaunchedEffect(index, mediaUrls) {
        if (mediaUrls.isEmpty()) return@LaunchedEffect
        progress.snapTo(0f)
        val totalMs = 5000
        val stepMs = 50L
        var elapsedMs = 0
        while (elapsedMs < totalMs) {
            kotlinx.coroutines.delay(stepMs)
            elapsedMs += stepMs.toInt()
            progress.snapTo((elapsedMs / totalMs.toFloat()).coerceAtMost(1f))
        }
        goNext()
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
                .pointerInput(index) {
                    detectTapGestures { offset ->
                        if (offset.x < size.width / 2) goPrevious() else goNext()
                    }
                }
        ) {
            val url = mediaUrls.getOrNull(index)
            if (url != null) {
                Image(
                    painter = rememberAsyncImagePainter(url),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .padding(top = 10.dp, start = 8.dp, end = 8.dp)
            ) {
                mediaUrls.indices.forEach { i ->
                    val fill = when {
                        i < index -> 1f
                        i == index -> progress.value
                        else -> 0f
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(3.dp)
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(2.dp))
                            .background(Color.White.copy(alpha = 0.35f))
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(fill)
                                .background(Color.White)
                        )
                    }
                }
            }
            Text(
                highlight.title,
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.align(Alignment.TopStart).padding(top = 22.dp, start = 16.dp)
            )
        }
    }
}
