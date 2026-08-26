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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import com.social.app.screens.perfil.SocialsListViewModel
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

/**
 * Hilo de un chat de grupo real, comparado con WhatsApp/Instagram/
 * Messenger/Facebook -- ver GroupChatViewModel.kt para el hallazgo
 * completo. Mismo patrón visual que ChatScreen.kt (1:1). Reacciones
 * (0060_group_message_reactions.sql) y "visto por"
 * (0061_group_message_reads.sql) reales -- voz sigue pendiente, hueco
 * real documentado.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupChatScreen(groupChatId: String, groupName: String, onBack: () -> Unit) {
    val viewModel = remember(groupChatId) { GroupChatViewModel(groupChatId) }
    val messages by viewModel.messages.collectAsState()
    val members by viewModel.members.collectAsState()
    val reactions by viewModel.reactions.collectAsState()
    val reads by viewModel.reads.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    var draft by remember { mutableStateOf("") }
    var showMembers by remember { mutableStateOf(false) }
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    val listState = rememberLazyListState()

    // Nota de voz real (0062_group_message_audio.sql) -- mismo patrón
    // exacto que ChatScreen.kt (1:1).
    val context = androidx.compose.ui.platform.LocalContext.current
    val voiceRecorder = remember { VoiceRecorder(context) }
    var isRecording by remember { mutableStateOf(false) }
    val recordPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            voiceRecorder.start()
            isRecording = true
        }
    }

    LaunchedEffect(groupChatId) { viewModel.load() }
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    com.social.app.ui.theme.BackScaffold(
        title = groupName,
        onBack = onBack,
        actions = {
            TextButton(onClick = { showMembers = true }) { Text("👥 ${members.size}") }
        }
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(8.dp)) }
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                items(messages, key = { it.id }) { message ->
                    val sender = members.firstOrNull { it.id == message.senderId }
                    val isMine = message.senderId == myId
                    // Reacciones reales a mensajes de grupo
                    // (0060_group_message_reactions.sql), comparado con
                    // WhatsApp/Messenger/Instagram -- mismo patrón exacto
                    // que ChatScreen.kt (chat 1:1): tocar la burbuja abre/
                    // cierra un selector rápido de emojis.
                    var showPicker by remember(message.id) { mutableStateOf(false) }
                    val reactionEmojis = listOf("❤", "😂", "😮", "😢", "👍")
                    Column(
                        horizontalAlignment = if (isMine) Alignment.End else Alignment.Start,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        if (!isMine) {
                            Text(
                                sender?.displayName ?: "…",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        // Nota de voz real (0062_group_message_audio.sql),
                        // comparado con WhatsApp/Messenger/Telegram --
                        // mismo reproductor nativo que ChatScreen.kt (1:1).
                        val audioUrl = message.audioUrl
                        if (audioUrl != null) {
                            GroupAudioMessageBubble(url = audioUrl, isMine = isMine)
                        } else {
                            Text(
                                message.body ?: "",
                                modifier = Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(
                                        if (isMine) MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                                        else MaterialTheme.colorScheme.surfaceVariant
                                    )
                                    .clickable { showPicker = !showPicker }
                                    .padding(horizontal = 12.dp, vertical = 8.dp)
                            )
                        }
                        val messageReactions = reactions[message.id].orEmpty()
                        if (messageReactions.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 2.dp)) {
                                messageReactions.groupBy { it.emoji }.forEach { (emoji, group) ->
                                    val iReacted = group.any { it.userId == myId }
                                    androidx.compose.material3.Surface(
                                        shape = RoundedCornerShape(10.dp),
                                        color = if (iReacted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                                        modifier = Modifier.clickable { viewModel.toggleReaction(message.id, emoji) }
                                    ) {
                                        Text("$emoji ${group.size}", modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp), style = MaterialTheme.typography.labelSmall)
                                    }
                                }
                            }
                        }
                        if (showPicker) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 4.dp)) {
                                reactionEmojis.forEach { emoji ->
                                    Text(
                                        emoji,
                                        style = MaterialTheme.typography.titleMedium,
                                        modifier = Modifier.clickable {
                                            viewModel.toggleReaction(message.id, emoji)
                                            showPicker = false
                                        }
                                    )
                                }
                            }
                        }
                        // "Visto por" real (0061_group_message_reads.sql),
                        // comparado con WhatsApp/Messenger -- solo en los
                        // propios mensajes, igual que esas apps solo
                        // muestran el recibo de lectura de lo que TÚ enviaste.
                        if (isMine) {
                            val readCount = reads[message.id]?.count { it != myId } ?: 0
                            if (readCount > 0) {
                                Text(
                                    "Visto por $readCount",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 2.dp)
                                )
                            }
                        }
                    }
                }
            }
            Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                // Nota de voz real (0062_group_message_audio.sql), mismo
                // patrón exacto que ChatScreen.kt (1:1): MediaRecorder
                // nativo vía VoiceRecorder.kt, sin SDK de terceros.
                OutlinedButton(
                    onClick = {
                        if (isRecording) {
                            isRecording = false
                            voiceRecorder.stop()?.let { viewModel.sendVoiceNote(it) }
                        } else {
                            recordPermission.launch(android.Manifest.permission.RECORD_AUDIO)
                        }
                    },
                    modifier = Modifier.padding(end = 8.dp)
                ) {
                    Text(if (isRecording) "⏹" else "🎙")
                }
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text(if (isRecording) "Grabando…" else "Mensaje…") },
                    enabled = !isRecording
                )
                Button(
                    onClick = {
                        viewModel.sendMessage(draft)
                        draft = ""
                    },
                    modifier = Modifier.padding(start = 8.dp),
                    enabled = !isRecording
                ) {
                    Text("➤")
                }
            }
        }
    }

    if (showMembers) {
        MembersSheet(
            groupChatViewModel = viewModel,
            members = members,
            onDismiss = { showMembers = false },
            onLeave = {
                showMembers = false
                viewModel.leaveGroup(onBack)
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MembersSheet(
    groupChatViewModel: GroupChatViewModel,
    members: List<com.social.app.backend.model.Profile>,
    onDismiss: () -> Unit,
    onLeave: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()
    var showAddPicker by remember { mutableStateOf(false) }
    val socialsViewModel: SocialsListViewModel = viewModel()
    val socials by socialsViewModel.socials.collectAsState()
    LaunchedEffect(Unit) { socialsViewModel.load() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text("Miembros del grupo", style = MaterialTheme.typography.titleLarge)
            members.forEach { member ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                    com.social.app.avatar.AvatarView(config = member.avatarConfig ?: emptyMap(), size = 32.dp)
                    Text(member.displayName, modifier = Modifier.padding(start = 10.dp))
                }
            }
            TextButton(onClick = { showAddPicker = true }, modifier = Modifier.padding(top = 8.dp)) {
                Text("+ Añadir a alguien")
            }
            if (showAddPicker) {
                val memberIds = members.map { it.id }.toSet()
                socials.filter { it.profileId !in memberIds }.forEach { entry ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                groupChatViewModel.addMember(entry.profileId)
                                showAddPicker = false
                            }
                            .padding(vertical = 6.dp)
                    ) {
                        com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 28.dp)
                        Text(entry.displayName, modifier = Modifier.padding(start = 10.dp))
                    }
                }
            }
            TextButton(onClick = onLeave, modifier = Modifier.padding(top = 12.dp)) {
                Text("Salir del grupo", color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/** Reproductor de nota de voz de grupo -- `MediaPlayer` nativo, mismo
 * criterio exacto que `AudioMessageBubble` (ChatScreen.kt, chat 1:1),
 * duplicado en vez de compartido porque ese composable es privado a su
 * propio archivo (visibilidad de nivel de archivo en Kotlin). */
@Composable
private fun GroupAudioMessageBubble(url: String, isMine: Boolean) {
    var isPlaying by remember { mutableStateOf(false) }
    var player by remember { mutableStateOf<android.media.MediaPlayer?>(null) }

    androidx.compose.runtime.DisposableEffect(url) {
        onDispose {
            player?.release()
            player = null
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (isMine) MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                else MaterialTheme.colorScheme.surfaceVariant
            )
            .clickable {
                if (isPlaying) {
                    player?.pause()
                    isPlaying = false
                } else {
                    val p = player ?: android.media.MediaPlayer().apply {
                        setDataSource(url)
                        setOnCompletionListener { isPlaying = false }
                        prepareAsync()
                        setOnPreparedListener { start() }
                    }
                    player = p
                    if (p.isPlaying.not()) {
                        try { p.start() } catch (e: Exception) { /* aún preparando */ }
                    }
                    isPlaying = true
                }
            }
            .padding(horizontal = 14.dp, vertical = 10.dp)
    ) {
        Text(if (isPlaying) "⏸" else "▶")
        Text(" Nota de voz")
    }
}
