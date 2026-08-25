package com.social.app.screens.live

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

/**
 * "Directo" real por primera vez, comparado con Instagram/TikTok Live --
 * lista de directos activos + arrancar el propio. Ronda de cliente sobre
 * el backend ya construido y verificado (0056_live_streams.sql). Mismo
 * patrón visual que StoriesBar.kt/ReelsScreen.kt: lista real +
 * `LiveStreamRoomScreen` para la sala de vídeo en sí.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveStreamsScreen(viewModel: LiveStreamsViewModel = viewModel()) {
    val streams by viewModel.streams.collectAsState()
    val hostProfiles by viewModel.hostProfiles.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var showStartSheet by remember { mutableStateOf(false) }
    var activeRoom by remember { mutableStateOf<Pair<LiveStream, Boolean>?>(null) }
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = { showStartSheet = true }) {
                Text("🔴", style = MaterialTheme.typography.titleLarge)
            }
        }
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxWidth()) {
            Text(
                "Directos",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(16.dp)
            )
            if (isLoading && streams.isEmpty()) {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
            if (!isLoading && streams.isEmpty() && errorMessage == null) {
                Text(
                    "Nadie está en directo ahora mismo.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp)
                )
            }
            LazyColumn {
                items(streams, key = { it.id }) { stream ->
                    val host = hostProfiles[stream.hostId]
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                scope.launch { activeRoom = stream to (stream.hostId == myId) }
                            }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            com.social.app.avatar.AvatarView(config = host?.avatarConfig ?: emptyMap(), size = 40.dp)
                            Column(modifier = Modifier.padding(start = 10.dp)) {
                                Text(host?.displayName ?: "…", style = MaterialTheme.typography.labelLarge)
                                Text(
                                    stream.title ?: "Directo",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        Text(
                            "🔴 ${stream.viewerCount}",
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .padding(horizontal = 8.dp, vertical = 4.dp)
                        )
                    }
                }
            }
        }
    }

    if (showStartSheet) {
        StartLiveStreamSheet(
            viewModel = viewModel,
            onDismiss = { showStartSheet = false },
            onStarted = { stream ->
                showStartSheet = false
                activeRoom = stream to true
            }
        )
    }

    activeRoom?.let { (stream, isHost) ->
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { activeRoom = null },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)
        ) {
            LiveStreamRoomScreen(
                stream = stream,
                isHost = isHost,
                viewModel = viewModel,
                onClose = {
                    activeRoom = null
                    viewModel.load()
                }
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StartLiveStreamSheet(viewModel: LiveStreamsViewModel, onDismiss: () -> Unit, onStarted: (LiveStream) -> Unit) {
    var title by remember { mutableStateOf("") }
    var isSocialOnly by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("Empezar un directo", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Título (opcional)") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            Row(modifier = Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = isSocialOnly, onCheckedChange = { isSocialOnly = it })
                Text("Solo visible para tus socials aceptados")
            }
            Button(
                onClick = {
                    starting = true
                    scope.launch {
                        val stream = viewModel.startStream(title, isSocialOnly)
                        starting = false
                        if (stream != null) onStarted(stream)
                    }
                },
                enabled = !starting,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text(if (starting) "Empezando…" else "Empezar directo")
            }
        }
    }
}
