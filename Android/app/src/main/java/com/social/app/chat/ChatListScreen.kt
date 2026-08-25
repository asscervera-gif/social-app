package com.social.app.chat

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
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
import androidx.compose.runtime.remember
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
fun ChatListScreen(viewModel: ChatListViewModel = viewModel(), onOpenChat: (String) -> Unit) {
    val chats by viewModel.chats.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

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
                    androidx.compose.material3.IconButton(onClick = { viewModel.toggleMute(entry) }) {
                        Text(if (entry.isMutedForMe) "🔕" else "🔔")
                    }
                }
                HorizontalDivider()
            }
        }
    }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
}
