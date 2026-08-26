package com.social.app.screens.home

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.rememberAsyncImagePainter
import com.social.app.backend.SupabaseManager
import com.social.app.chat.SocialLinkManager
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Barra de historias en la parte superior de Home — no existía ningún
 * cliente para Historias en ninguna plataforma (ver StoriesViewModel.kt
 * para el hallazgo completo: el esquema/RLS ya estaban listos desde el
 * principio, solo faltaba construir esto).
 */
@Composable
fun StoriesBar(viewModel: StoriesViewModel = viewModel()) {
    val groups by viewModel.groups.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var viewingGroup by remember { mutableStateOf<StoryGroup?>(null) }
    val context = LocalContext.current

    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) viewModel.createStory(context, uri) {}
    }

    LaunchedEffect(Unit) { viewModel.load() }

    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)
    ) {
        item {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    modifier = Modifier
                        .size(60.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable { pickImage.launch("image/*") },
                    contentAlignment = Alignment.Center
                ) {
                    if (isUploading) CircularProgressIndicator(modifier = Modifier.size(24.dp))
                    else Text("+", style = MaterialTheme.typography.headlineSmall)
                }
                Text("Tu historia", style = MaterialTheme.typography.labelSmall)
            }
        }
        items(groups, key = { it.authorId }) { group ->
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.clickable { viewingGroup = group }
            ) {
                Image(
                    painter = rememberAsyncImagePainter(group.stories.first().mediaUrl),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(60.dp).clip(CircleShape)
                )
                Text(group.authorName, style = MaterialTheme.typography.labelSmall)
            }
        }
    }

    errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }

    viewingGroup?.let { group ->
        StoryViewer(group = group, viewModel = viewModel, onDismiss = { viewingGroup = null })
    }
}

/** Visor a pantalla completa — antes solo tocar para pasar a mano, sin
 * barra de progreso ni avance automático, comparado con Instagram/
 * WhatsApp Status/Snapchat/SOCIAL_APP.html (`.stbar`/`.stbarf`). Ahora
 * cada historia tiene su propio segmento de progreso que se rellena en
 * 5s y avanza sola, igual que esas apps; tocar la mitad derecha adelanta,
 * la izquierda retrocede -- mismo lenguaje de gestos ya estandarizado. */
@Composable
private fun StoryViewer(group: StoryGroup, viewModel: StoriesViewModel = viewModel(), onDismiss: () -> Unit) {
    var index by remember { mutableStateOf(0) }
    val story = group.stories.getOrNull(index)
    // "Quién vio tu historia" (0053_story_views.sql), comparado con
    // Instagram/Snapchat/WhatsApp Status -- antes ni siquiera se
    // registraba quién veía una historia, la tabla no existía.
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    var showViewers by remember { mutableStateOf(false) }
    var viewers by remember { mutableStateOf<List<StoriesViewModel.StoryViewer>>(emptyList()) }
    val progress = remember(index) { androidx.compose.animation.core.Animatable(0f) }
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    var replyText by remember(index) { mutableStateOf("") }
    var isReplyFocused by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val socialLinks = remember { SocialLinkManager() }

    if (story == null) {
        onDismiss()
        return
    }

    fun goNext() {
        if (index < group.stories.lastIndex) index += 1 else onDismiss()
    }
    fun goPrevious() {
        if (index > 0) index -= 1
    }

    LaunchedEffect(story.id) {
        showViewers = false
        if (story.authorId == myId) {
            viewers = viewModel.loadViewers(story.id)
        } else {
            viewModel.recordView(story)
        }
    }

    // 5s por historia, mismo orden de magnitud que Instagram/WhatsApp
    // Status (SOCIAL_APP.html usaba 4s para su maqueta estática). Si el
    // usuario avanza a mano antes de que termine, este LaunchedEffect se
    // cancela por el cambio de `index` -- no se dispara un avance doble.
    // Hallazgo real, comparado con Instagram/WhatsApp Status/Snapchat: las
    // tres apps PAUSAN el avance automático mientras se escribe una
    // respuesta -- un avance por pasos de 50ms (en vez de un solo
    // `animateTo`) deja comprobar `isReplyFocused` en cada paso y
    // simplemente no acumular tiempo mientras el teclado está activo, sin
    // necesitar recalcular una duración "restante" al reanudar.
    LaunchedEffect(index) {
        progress.snapTo(0f)
        val totalMs = 5000
        val stepMs = 50L
        var elapsedMs = 0
        while (elapsedMs < totalMs) {
            delay(stepMs)
            if (!isReplyFocused) {
                elapsedMs += stepMs.toInt()
                progress.snapTo((elapsedMs / totalMs.toFloat()).coerceAtMost(1f))
            }
        }
        goNext()
    }

    // Dialog con `usePlatformDefaultWidth = false`: sin esto, el visor
    // solo ocuparía el tamaño disponible dentro de la fila de historias
    // (un item de LazyRow), no la pantalla entera.
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(androidx.compose.ui.graphics.Color.Black)
                .pointerInput(index) {
                    detectTapGestures { offset ->
                        if (offset.x < size.width / 2) goPrevious() else goNext()
                    }
                }
        ) {
            Image(
                painter = rememberAsyncImagePainter(story.mediaUrl),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .padding(top = 10.dp, start = 8.dp, end = 8.dp)
            ) {
                group.stories.indices.forEach { i ->
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
                            .background(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.35f))
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(fill)
                                .background(androidx.compose.ui.graphics.Color.White)
                        )
                    }
                }
            }
            Text(
                group.authorName,
                color = androidx.compose.ui.graphics.Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(top = 24.dp, start = 16.dp, end = 16.dp)
            )
            if (story.authorId == myId) {
                Text(
                    "👁 ${viewers.size} ${if (viewers.size == 1) "vista" else "vistas"}",
                    color = androidx.compose.ui.graphics.Color.White,
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(16.dp)
                        .clickable(onClick = { showViewers = true })
                )
            } else {
                // Responder a una historia real (0071_message_story_reply.sql),
                // comparado con Instagram/WhatsApp Status/Snapchat -- solo
                // tiene sentido sobre la historia de OTRA persona, nunca
                // la propia (para eso ya está "quién vio tu historia").
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(16.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(20.dp))
                            .background(Color.White.copy(alpha = 0.15f))
                            .padding(horizontal = 14.dp, vertical = 10.dp)
                    ) {
                        if (replyText.isEmpty()) {
                            Text("Responder a la historia…", color = Color.White.copy(alpha = 0.6f))
                        }
                        BasicTextField(
                            value = replyText,
                            onValueChange = { replyText = it },
                            textStyle = TextStyle(color = Color.White),
                            cursorBrush = SolidColor(Color.White),
                            modifier = Modifier.fillMaxWidth().onFocusChanged { isReplyFocused = it.isFocused }
                        )
                    }
                    if (replyText.isNotBlank()) {
                        Text(
                            "➤",
                            color = Color.White,
                            modifier = Modifier.padding(start = 8.dp).clickable {
                                val text = replyText
                                replyText = ""
                                scope.launch {
                                    val myIdNow = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                                    val chatId = socialLinks.getOrCreateChat(myIdNow, story.authorId) ?: return@launch
                                    viewModel.sendReply(chatId, story.id, text)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    if (showViewers) {
        Dialog(onDismissRequest = { showViewers = false }) {
            Box(
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.surface, androidx.compose.foundation.shape.RoundedCornerShape(16.dp))
                    .padding(16.dp)
            ) {
                Column {
                    Text("Vistas", style = MaterialTheme.typography.titleMedium)
                    if (viewers.isEmpty()) {
                        Text(
                            "Todavía nadie ha visto esta historia.",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                    viewers.forEach { viewer ->
                        Text(viewer.displayName, modifier = Modifier.padding(vertical = 6.dp))
                    }
                }
            }
        }
    }
}
