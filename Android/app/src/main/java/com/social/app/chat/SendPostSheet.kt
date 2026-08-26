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
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class NewSharedMessage(
    @SerialName("chat_id") val chatId: String,
    @SerialName("sender_id") val senderId: String,
    @SerialName("shared_post_id") val sharedPostId: String
)

@Serializable
private data class NewSharedGroupMessage(
    @SerialName("group_chat_id") val groupChatId: String,
    @SerialName("sender_id") val senderId: String,
    @SerialName("shared_post_id") val sharedPostId: String
)

/**
 * "Enviar a…" real, comparado con Instagram/TikTok/Twitter/Snapchat: en
 * las cuatro apps, el icono ➤ de una publicación abre este selector
 * interno (un chat 1:1, un grupo) -- el mecanismo de distribución más
 * usado de esas apps, más que el "compartir" externo al sistema. Antes,
 * el mismo icono en HomeScreen.kt solo abría el share sheet nativo de
 * Android (texto plano hacia otra app), sin ninguna forma de mandar la
 * publicación como mensaje real dentro de la propia app.
 *
 * Reutiliza tal cual ChatListViewModel/GroupChatsViewModel (ya construidos
 * para "Tus chats"/"Grupos") solo para listar a quién se puede enviar --
 * el envío en sí es un insert directo, sin necesitar una instancia
 * completa de ChatViewModel/GroupChatViewModel para un chat concreto.
 * "Compartir externamente" se mantiene como opción secundaria al final,
 * mismo comportamiento que ya existía antes de esta ronda.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SendPostSheet(postId: String, onShareExternal: () -> Unit, onDismiss: () -> Unit) {
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
                SupabaseManager.client.from("messages").insert(NewSharedMessage(chatId, userId, postId))
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
                SupabaseManager.client.from("group_messages").insert(NewSharedGroupMessage(groupChatId, userId, postId))
                onDismiss()
            } catch (e: Exception) {
                // Sin bloquear la hoja si falla -- el usuario puede reintentar.
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("Enviar a…", style = MaterialTheme.typography.titleLarge)
            if (chats.isEmpty() && groups.isEmpty()) {
                Text(
                    "Todavía no tienes chats ni grupos para enviar.",
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
            TextButton(
                onClick = {
                    onShareExternal()
                    onDismiss()
                },
                modifier = Modifier.padding(top = 12.dp)
            ) {
                Text("Compartir externamente")
            }
        }
    }
}
