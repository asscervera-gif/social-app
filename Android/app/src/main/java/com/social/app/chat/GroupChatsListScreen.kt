package com.social.app.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.screens.perfil.SocialsListViewModel
import kotlinx.coroutines.launch

/**
 * Lista de chats de grupo reales + crear uno propio, comparado con
 * WhatsApp/Instagram/Messenger/Facebook. Ronda de cliente sobre el backend
 * ya construido y verificado (0057_group_chats.sql). Mismo patrón visual
 * que ChatListScreen.kt (chats 1:1), en una pantalla propia -- no se
 * mezclan las dos listas para no reescribir ChatListScreen/ViewModel, que
 * ya funcionan bien para 1:1.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupChatsListScreen(viewModel: GroupChatsViewModel = viewModel(), onOpenGroup: (String, String) -> Unit) {
    val groups by viewModel.groups.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var showCreateSheet by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreateSheet = true }) {
                Text("+", style = MaterialTheme.typography.headlineSmall)
            }
        }
    ) { padding ->
        Box(modifier = Modifier.padding(padding).fillMaxSize()) {
            if (isLoading && groups.isEmpty()) {
                CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
            if (!isLoading && groups.isEmpty() && errorMessage == null) {
                Text(
                    "Todavía no tienes ningún grupo.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.align(Alignment.Center).padding(16.dp)
                )
            }
            LazyColumn {
                items(groups, key = { it.id }) { group ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenGroup(group.id, group.name) }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(44.dp)
                                .background(MaterialTheme.colorScheme.surfaceVariant, CircleShape),
                            contentAlignment = Alignment.Center
                        ) {
                            // Foto de grupo real (0063_group_chat_photo.sql),
                            // comparado con WhatsApp/Messenger/Telegram --
                            // "👥" de respaldo mientras no se le ponga foto.
                            if (group.photoUrl != null) {
                                androidx.compose.foundation.Image(
                                    painter = coil.compose.rememberAsyncImagePainter(group.photoUrl),
                                    contentDescription = null,
                                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                    modifier = Modifier.size(44.dp).clip(CircleShape)
                                )
                            } else {
                                Text("👥")
                            }
                        }
                        Text(group.name, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        }
    }

    if (showCreateSheet) {
        CreateGroupSheet(
            groupsViewModel = viewModel,
            onDismiss = { showCreateSheet = false },
            onCreated = { group ->
                showCreateSheet = false
                viewModel.load()
                onOpenGroup(group.id, group.name)
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreateGroupSheet(groupsViewModel: GroupChatsViewModel, onDismiss: () -> Unit, onCreated: (GroupChat) -> Unit) {
    var name by remember { mutableStateOf("") }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }
    var creating by remember { mutableStateOf(false) }
    val socialsViewModel: SocialsListViewModel = viewModel()
    val socials by socialsViewModel.socials.collectAsState()
    LaunchedEffect(Unit) { socialsViewModel.load() }
    val sheetState = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("Nuevo grupo", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Nombre del grupo") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            if (socials.isNotEmpty()) {
                Text(
                    "Añadir a…",
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = 16.dp, bottom = 4.dp)
                )
                LazyColumn(modifier = Modifier.fillMaxWidth().size(220.dp)) {
                    items(socials, key = { it.socialId }) { entry ->
                        val checked = selectedIds.contains(entry.profileId)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    selectedIds = if (checked) selectedIds - entry.profileId else selectedIds + entry.profileId
                                }
                                .padding(vertical = 4.dp)
                        ) {
                            Checkbox(checked = checked, onCheckedChange = null)
                            com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 28.dp)
                            Text(entry.displayName)
                        }
                    }
                }
            }
            Button(
                onClick = {
                    creating = true
                    scope.launch {
                        val group = groupsViewModel.createGroup(name, selectedIds.toList())
                        creating = false
                        if (group != null) onCreated(group)
                    }
                },
                enabled = name.isNotBlank() && !creating,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text(if (creating) "Creando…" else "Crear grupo")
            }
        }
    }
}
