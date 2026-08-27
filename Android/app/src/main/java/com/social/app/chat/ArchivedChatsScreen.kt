package com.social.app.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Archivados real, comparado con WhatsApp/Telegram: "Ocultar conversación"
 * (0044_chats_hide.sql) era un viaje solo de ida -- el chat desaparecía de
 * "Tus chats" sin ninguna forma real de volver a verlo salvo esperar a que
 * la otra persona escribiera de nuevo (eso lo desoculta solo). Esta
 * pantalla es el filtro INVERSO real de ChatListScreen.kt, reutilizando
 * tal cual hidden_by_a/hidden_by_b -- sin migración nueva.
 */
@Composable
fun ArchivedChatsScreen(viewModel: ChatListViewModel = viewModel(), onOpenChat: (String) -> Unit) {
    val archivedChats by viewModel.archivedChats.collectAsState()

    DisposableEffect(Unit) {
        viewModel.loadArchived()
        onDispose {}
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        if (archivedChats.isEmpty()) {
            Text(
                "No tienes ninguna conversación archivada.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(archivedChats, key = { it.chat.id }) { entry ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenChat(entry.chat.id) }
                        .padding(vertical = 12.dp)
                ) {
                    com.social.app.avatar.AvatarView(config = entry.otherAvatarConfig ?: emptyMap(), size = 44.dp)
                    Column(modifier = Modifier.padding(start = 12.dp).weight(1f)) {
                        Text(entry.otherName, style = MaterialTheme.typography.titleSmall)
                        Text(
                            entry.lastMessage?.takeIf { it.isNotBlank() } ?: "Sin mensajes todavía",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1
                        )
                    }
                    OutlinedButton(onClick = { viewModel.unhideChat(entry) }) {
                        Text("Desarchivar")
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
