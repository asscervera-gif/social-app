package com.social.app.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class NewForwardedMessage(
    @SerialName("chat_id") val chatId: String,
    @SerialName("sender_id") val senderId: String,
    val body: String? = null,
    @SerialName("media_url") val mediaUrl: String? = null,
    @SerialName("audio_url") val audioUrl: String? = null,
    @SerialName("is_forwarded") val isForwarded: Boolean = true
)

@Serializable
private data class NewForwardedGroupMessage(
    @SerialName("group_chat_id") val groupChatId: String,
    @SerialName("sender_id") val senderId: String,
    val body: String? = null,
    @SerialName("media_url") val mediaUrl: String? = null,
    @SerialName("audio_url") val audioUrl: String? = null,
    @SerialName("is_forwarded") val isForwarded: Boolean = true
)

/**
 * Reenviar un mensaje real (0072_message_forward.sql), comparado con
 * WhatsApp/Telegram/Messenger: cualquier mensaje (propio o ajeno) se
 * puede mandar a otro chat o grupo -- uno de los gestos de mensajería más
 * usados de esas apps, sin ninguna forma real en SOCIAL hasta esta ronda.
 * Mismo selector "Enviar a…" que SendPostSheet.kt (reutiliza
 * ChatListViewModel/GroupChatsViewModel igual, solo para listar a quién
 * enviar), duplicado en vez de compartido porque cada uno inserta un
 * contenido distinto (shared_post_id vs. body/media_url/audio_url +
 * is_forwarded) -- mismo criterio ya aplicado a GroupAudioMessageBubble.
 * Solo copia texto/foto/audio -- reenviar una publicación compartida o
 * una respuesta a una historia queda fuera de alcance a propósito (esos
 * mensajes no llevan body/media/audio propios, solo una referencia).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForwardMessageSheet(body: String?, mediaUrl: String?, audioUrl: String?, onDismiss: () -> Unit) {
    val chatListViewModel: ChatListViewModel = viewModel()
    val groupsViewModel: GroupChatsViewModel = viewModel()
    val chats by chatListViewModel.chats.collectAsState()
    val groups by groupsViewModel.groups.collectAsState()
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState()

    LaunchedEffect(Unit) {
        chatListViewModel.load()
        groupsViewModel.load()
    }

    fun sendToChat(chatId: String) {
        scope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("messages").insert(NewForwardedMessage(chatId, userId, body, mediaUrl, audioUrl))
                onDismiss()
            } catch (e: Exception) {
                // Sin bloquear la hoja si falla -- el usuario puede reintentar.
            }
        }
    }

    fun sendToGroup(groupChatId: String) {
        scope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("group_messages").insert(NewForwardedGroupMessage(groupChatId, userId, body, mediaUrl, audioUrl))
                onDismiss()
            } catch (e: Exception) {
                // Sin bloquear la hoja si falla -- el usuario puede reintentar.
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("Reenviar a…", style = MaterialTheme.typography.titleLarge)
            if (chats.isEmpty() && groups.isEmpty()) {
                Text(
                    "Todavía no tienes chats ni grupos para reenviar.",
                    modifier = Modifier.padding(top = 12.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            chats.forEach { entry ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { sendToChat(entry.chat.id) }
                        .padding(vertical = 8.dp)
                ) {
                    com.social.app.avatar.AvatarView(config = entry.otherAvatarConfig ?: emptyMap(), size = 36.dp)
                    Text(entry.otherName, modifier = Modifier.padding(start = 12.dp))
                }
            }
            groups.forEach { group ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { sendToGroup(group.id) }
                        .padding(vertical = 8.dp)
                ) {
                    Text("👥", modifier = Modifier.padding(end = 12.dp))
                    Text(group.name)
                }
            }
        }
    }
}
