package com.social.app.screens.home

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.rememberAsyncImagePainter
import io.github.jan.supabase.gotrue.auth

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
        StoryViewer(group = group, onDismiss = { viewingGroup = null })
    }
}

/** Visor a pantalla completa, avanza a la siguiente historia del mismo
 * autor al tocar, se cierra al llegar al final — mismo patrón simple que
 * Instagram/WhatsApp Status, sin arriesgar gestos/animaciones complejas
 * no verificadas. */
@Composable
private fun StoryViewer(group: StoryGroup, onDismiss: () -> Unit) {
    var index by remember { mutableStateOf(0) }
    val story = group.stories.getOrNull(index)

    if (story == null) {
        onDismiss()
        return
    }

    // Dialog con `usePlatformDefaultWidth = false`: sin esto, el visor
    // solo ocuparía el tamaño disponible dentro de la fila de historias
    // (un item de LazyRow), no la pantalla entera.
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(androidx.compose.ui.graphics.Color.Black)
                .clickable {
                    if (index < group.stories.lastIndex) index += 1 else onDismiss()
                }
        ) {
            Image(
                painter = rememberAsyncImagePainter(story.mediaUrl),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
            Text(
                group.authorName,
                color = androidx.compose.ui.graphics.Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(16.dp)
            )
        }
    }
}
