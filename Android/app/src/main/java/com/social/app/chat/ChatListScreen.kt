package com.social.app.chat

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Lista de chats — no existía en ninguna plataforma (ver ChatListViewModel
 * para el hallazgo completo). Punto de entrada nuevo desde Perfil.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ChatListScreen(viewModel: ChatListViewModel = viewModel(), onOpenChat: (String) -> Unit, onOpenArchived: () -> Unit = {}) {
    val chats by viewModel.chats.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // Nota efímera real sobre el propio perfil, comparado con Instagram/
    // Facebook Messenger -- ver ChatListViewModel.setMyNote(),
    // 0110_profile_notes.sql.
    val myNote by viewModel.myNote.collectAsState()
    var showNoteDialog by remember { mutableStateOf(false) }
    var noteDraft by remember { mutableStateOf("") }

    DisposableEffect(Unit) {
        viewModel.start()
        onDispose { viewModel.stop() }
    }

    // Hallazgo real: comparado con Instagram/Twitter/Facebook (y con
    // Home/Match/Avisos, ya corregidas esta sesión), "Tus chats" tampoco
    // tenía pull-to-refresh.
    val pullState = rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            viewModel.load()
            pullState.endRefresh()
        }
    }

    Box(modifier = Modifier.fillMaxSize().nestedScroll(pullState.nestedScrollConnection)) {
    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Tus chats", style = MaterialTheme.typography.headlineSmall)
        // Nota efímera real sobre el propio perfil, comparado con
        // Instagram/Facebook Messenger -- caduca sola a las 24h (ver
        // ChatListViewModel.setMyNote(), 0110_profile_notes.sql).
        Text(
            myNote?.let { "📝 $it" } ?: "📝 Escribe una nota (dura 24h)…",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp).clickable {
                noteDraft = myNote ?: ""
                showNoteDialog = true
            }
        )
        // "Archivados" real, comparado con WhatsApp/Telegram -- antes
        // "Ocultar conversación" (0044_chats_hide.sql) era un viaje solo
        // de ida, sin ninguna sección real para volver a verlos. Ver
        // ArchivedChatsScreen.kt/ChatListViewModel.loadArchived().
        Text(
            "🗄 Archivados",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(top = 8.dp).clickable { onOpenArchived() }
        )
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.padding(top = 12.dp))
        }
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (!isLoading && chats.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no tienes ningún chat.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(chats, key = { it.chat.id }) { entry ->
                // Deslizar para archivar, comparado con WhatsApp/Telegram
                // -- gesto real ausente hasta ahora en Android (iOS ya
                // tenía `.swipeActions` completo desde la ronda de
                // Archivados; aquí solo faltaba el gesto en sí, el menú de
                // mantener pulsado seguía cubriendo el resto de acciones).
                val dismissState = androidx.compose.material3.rememberSwipeToDismissBoxState(
                    confirmValueChange = { value ->
                        if (value == androidx.compose.material3.SwipeToDismissBoxValue.StartToEnd) {
                            viewModel.hideChat(entry)
                        }
                        false
                    }
                )
                androidx.compose.material3.SwipeToDismissBox(
                    state = dismissState,
                    enableDismissFromStartToEnd = true,
                    enableDismissFromEndToStart = false,
                    backgroundContent = {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(MaterialTheme.colorScheme.errorContainer)
                                .padding(start = 20.dp),
                            contentAlignment = Alignment.CenterStart
                        ) {
                            Text("🗄 Archivar", color = MaterialTheme.colorScheme.onErrorContainer)
                        }
                    }
                ) {
                androidx.compose.foundation.layout.Row(
                    verticalAlignment = Alignment.CenterVertically,
                    // Hallazgo real, comparado con WhatsApp/Instagram/
                    // Messenger: no había ninguna forma de quitar una
                    // conversación de la lista (ver
                    // ChatListViewModel.hideChat(), 0044_chats_hide.sql).
                    // Mantener pulsado para ocultar, mismo patrón ya
                    // usado para borrar un mensaje propio en ChatScreen.kt.
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.background)
                        .combinedClickable(
                            onClick = { onOpenChat(entry.chat.id) },
                            onLongClick = { viewModel.hideChat(entry) }
                        )
                        .padding(vertical = 12.dp)
                ) {
                    // Hallazgo real, comparado con WhatsApp/Instagram/
                    // Messenger: la lista de chats solo mostraba el
                    // nombre, nunca el avatar de la otra persona -- el
                    // identificador visual principal de cualquier lista
                    // de conversaciones.
                    com.social.app.avatar.AvatarView(config = entry.otherAvatarConfig ?: emptyMap(), size = 44.dp)
                    Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
                        Text(
                            entry.otherName,
                            style = if (entry.hasUnread) {
                                MaterialTheme.typography.titleSmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                            } else {
                                MaterialTheme.typography.titleSmall
                            }
                        )
                        // Nota efímera real de la otra persona, comparado
                        // con Instagram/Facebook Messenger -- ya filtrada
                        // por caducidad de 24h en ChatListViewModel.
                        entry.otherNoteText?.let {
                            Text(
                                "📝 $it",
                                style = MaterialTheme.typography.bodySmall.copy(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic),
                                color = MaterialTheme.colorScheme.primary,
                                maxLines = 1
                            )
                        }
                        Text(
                            entry.lastMessage?.takeIf { it.isNotBlank() } ?: "Sin mensajes todavía",
                            style = if (entry.hasUnread) {
                                MaterialTheme.typography.bodySmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                            } else {
                                MaterialTheme.typography.bodySmall
                            },
                            color = if (entry.hasUnread) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1
                        )
                    }
                    // Hallazgo real, comparado con WhatsApp/Instagram/
                    // Messenger: "Tus chats" no distinguía visualmente qué
                    // conversaciones tenían mensajes sin leer, solo el
                    // badge total de la pestaña Avisos.
                    if (entry.hasUnread) {
                        androidx.compose.foundation.layout.Box(
                            modifier = Modifier
                                .padding(end = 4.dp)
                                .size(10.dp)
                                .background(MaterialTheme.colorScheme.primary, androidx.compose.foundation.shape.CircleShape)
                        )
                    }
                    // Hallazgo real, comparado con WhatsApp/Instagram/
                    // Messenger: no había ninguna forma de silenciar una
                    // conversación sin salir ni bloquear -- ver
                    // 0047_message_notify_mute.sql. El propio icono ya
                    // comunica el estado (🔔 activo / 🔕 silenciado), sin
                    // necesitar una insignia aparte junto al nombre.
                    // Fijar un chat arriba de la lista, comparado con
                    // WhatsApp/Telegram/Messenger -- ver
                    // ChatListViewModel.togglePin(), 0081_pin_chats.sql.
                    androidx.compose.material3.IconButton(onClick = { viewModel.togglePin(entry) }) {
                        Text(if (entry.isPinnedForMe) "📌" else "📍")
                    }
                    // Marcar como no leído manualmente, comparado con
                    // WhatsApp/Telegram/Messenger -- capa personal por
                    // encima del estado real de lectura, NUNCA toca el
                    // recibo de lectura real que ve la otra persona (ver
                    // ChatListViewModel.toggleMarkUnread(),
                    // 0088_mark_chat_unread.sql).
                    androidx.compose.material3.IconButton(onClick = { viewModel.toggleMarkUnread(entry) }) {
                        Text(if (entry.markedUnreadForMe) "✅" else "✉️")
                    }
                    // Silenciar con una duración real elegida (8 horas / 1
                    // semana / siempre), comparado con WhatsApp/Telegram --
                    // antes solo existía un interruptor sin expiración (ver
                    // ChatListViewModel.muteChatFor(), 0082_mute_until.sql).
                    var showMuteMenu by remember { mutableStateOf(false) }
                    Box {
                        androidx.compose.material3.IconButton(onClick = {
                            if (entry.isMutedForMe) viewModel.unmuteChat(entry) else showMuteMenu = true
                        }) {
                            Text(if (entry.isMutedForMe) "🔕" else "🔔")
                        }
                        DropdownMenu(expanded = showMuteMenu, onDismissRequest = { showMuteMenu = false }) {
                            DropdownMenuItem(text = { Text("8 horas") }, onClick = {
                                showMuteMenu = false
                                viewModel.muteChatFor(entry, java.time.Instant.now().plusSeconds(8 * 3600))
                            })
                            DropdownMenuItem(text = { Text("1 semana") }, onClick = {
                                showMuteMenu = false
                                viewModel.muteChatFor(entry, java.time.Instant.now().plusSeconds(7 * 24 * 3600))
                            })
                            DropdownMenuItem(text = { Text("Siempre") }, onClick = {
                                showMuteMenu = false
                                viewModel.muteChatFor(entry, null)
                            })
                        }
                    }
                }
                }
                HorizontalDivider()
            }
        }
    }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
    if (showNoteDialog) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showNoteDialog = false },
            title = { Text("Tu nota (dura 24h)") },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = noteDraft,
                    onValueChange = { if (it.length <= 60) noteDraft = it },
                    placeholder = { Text("¿Qué estás pensando?") }
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.setMyNote(noteDraft)
                    showNoteDialog = false
                }) { Text("Guardar") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { showNoteDialog = false }) { Text("Cancelar") }
            }
        )
    }
}
