package com.social.app.chat

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import com.social.app.screens.perfil.SocialsListViewModel
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

/**
 * Hilo de un chat de grupo real, comparado con WhatsApp/Instagram/
 * Messenger/Facebook -- ver GroupChatViewModel.kt para el hallazgo
 * completo. Mismo patrón visual que ChatScreen.kt (1:1). Reacciones
 * (0060_group_message_reactions.sql), "visto por"
 * (0061_group_message_reads.sql), notas de voz
 * (0062_group_message_audio.sql) y fotos (media_url, ya en el esquema
 * desde 0057_group_chats.sql) reales.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun GroupChatScreen(
    groupChatId: String,
    groupName: String,
    onBack: () -> Unit,
    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat -- ver PostDetailScreen.kt para el hallazgo
    // completo.
    onOpenPost: (String) -> Unit = {},
    // Videollamada de GRUPO real (0083_group_calls.sql), comparado con
    // WhatsApp/Messenger/Telegram -- mismo `CallManager` global ya usado
    // en ChatScreen.kt para el 1:1 (montado una sola vez en
    // RootTabView.kt), este chat solo INICIA la llamada.
    callManager: com.social.app.calls.CallManager? = null,
    // @menciones reales dentro de un chat de GRUPO (0090_group_message_mentions.sql),
    // comparado con WhatsApp/Messenger/Telegram -- cierra el alcance
    // deliberado documentado antes: tocar "@usuario" ahora SÍ abre ese
    // perfil, mismo patrón exacto ya usado en CommentsSheet.kt.
    onOpenProfile: (String) -> Unit = {}
) {
    val viewModel = remember(groupChatId) { GroupChatViewModel(groupChatId) }
    val allGroupMessages by viewModel.messages.collectAsState()
    val members by viewModel.members.collectAsState()
    // Administradores reales de grupo, comparado con WhatsApp/Telegram/
    // Messenger -- ver 0107_group_chat_admins.sql.
    val adminIds by viewModel.adminIds.collectAsState()
    val reactions by viewModel.reactions.collectAsState()
    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql).
    val starredMessageIds by viewModel.starredMessageIds.collectAsState()
    val reads by viewModel.reads.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // @menciones reales dentro de un chat de GRUPO (0090_group_message_mentions.sql),
    // comparado con WhatsApp/Messenger/Telegram -- mismo patrón exacto
    // que CommentsSheet.kt para resolver "@usuario" -> id real de perfil.
    val mentionScope = rememberCoroutineScope()
    val mentionResolver = remember { com.social.app.util.MentionResolver() }
    // "En línea" y "escribiendo…" reales en un chat de grupo, comparado
    // con WhatsApp/Messenger -- ver GroupChatViewModel.kt para el
    // hallazgo completo (conjuntos en vez de un único booleano, a
    // diferencia del chat 1:1).
    val onlineMemberIds by viewModel.onlineMemberIds.collectAsState()
    val typingMemberIds by viewModel.typingMemberIds.collectAsState()
    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat.
    val sharedPosts by viewModel.sharedPosts.collectAsState()
    val sharedPostAuthors by viewModel.sharedPostAuthors.collectAsState()
    // Nombre editable y foto de grupo real, comparado con WhatsApp/
    // Messenger/Telegram -- ver GroupChatViewModel.kt para el hallazgo
    // completo (RLS ya existía desde 0057, solo faltaba cliente).
    val groupChat by viewModel.groupChat.collectAsState()
    var draft by remember { mutableStateOf("") }
    var showMembers by remember { mutableStateOf(false) }
    // Editar/borrar un mensaje ya enviado en un grupo real
    // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    // Telegram/Messenger -- mismo menú real que ChatScreen.kt (chat 1:1).
    var managingMessage by remember { mutableStateOf<GroupMessage?>(null) }
    val groupClipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
    var groupCustomReactionMessageId by remember { mutableStateOf<String?>(null) }
    var editingMessage by remember { mutableStateOf<GroupMessage?>(null) }
    var editedMessageText by remember { mutableStateOf("") }
    // Denunciar un mensaje concreto de un chat de grupo real
    // (0067_reports_group_message_reference.sql), comparado con
    // Instagram/WhatsApp/Messenger -- mismo menú real que ChatScreen.kt
    // (chat 1:1), pero aquí el denunciado es quien ESCRIBIÓ ese mensaje en
    // concreto, no un único "oponente" fijo como en el 1:1.
    var reportMessage by remember { mutableStateOf<GroupMessage?>(null) }
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var forwardingMessage by remember { mutableStateOf<GroupMessage?>(null) }
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    // "Eliminar para mí" real, comparado con WhatsApp -- resuelto en el
    // cliente (mismo criterio que ChatScreen.kt, 0118). Ver
    // GroupChatViewModel.deleteForMe(), 0120_delete_group_message_for_me.sql.
    val messages = allGroupMessages.filter { myId !in it.deletedFor }
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

    // Fotos reales en un chat de grupo, comparado con WhatsApp/Instagram/
    // Messenger/Facebook -- mismo patrón exacto que ChatScreen.kt (1:1).
    var fullScreenImageUrl by remember { mutableStateOf<String?>(null) }
    // Añadir un pie de foto real, comparado con WhatsApp/Telegram/
    // Instagram DM -- mismo hueco real ya cerrado en el chat 1:1
    // (ChatScreen.kt).
    var pendingGroupPhotoUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val pickImage = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri -> uri?.let { pendingGroupPhotoUri = it } }
    // Vídeo real en el chat de grupo, comparado con WhatsApp/Telegram/
    // iMessage -- mismo patrón exacto que ChatScreen.kt (1:1).
    var pendingGroupVideoUri by remember { mutableStateOf<android.net.Uri?>(null) }
    var fullScreenVideoUrl by remember { mutableStateOf<String?>(null) }
    // Escuchar la nota de voz real antes de mandarla también en el chat de
    // grupo, cierra el alcance deliberado de la ronda anterior (solo
    // 1:1) -- comparado con WhatsApp/Telegram, mismo patrón exacto que
    // ChatScreen.kt.
    var pendingGroupVoiceFile by remember { mutableStateOf<java.io.File?>(null) }
    val pickVideo = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri -> uri?.let { pendingGroupVideoUri = it } }

    LaunchedEffect(groupChatId) { viewModel.load() }
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    com.social.app.ui.theme.BackScaffold(
        title = groupName,
        onBack = onBack,
        actions = {
            // Videollamada/llamada de voz de GRUPO real
            // (0083_group_calls.sql), comparado con WhatsApp/Messenger/
            // Telegram -- mismos botones que ChatScreen.kt (1:1), aquí
            // llaman a TODO el grupo de una vez en vez de a una sola
            // persona.
            IconButton(onClick = { callManager?.startGroupCall(groupChatId, "audio") }) {
                Icon(Icons.Filled.Call, contentDescription = "Llamar al grupo")
            }
            IconButton(onClick = { callManager?.startGroupCall(groupChatId, "video") }) {
                Icon(Icons.Filled.Videocam, contentDescription = "Videollamada de grupo")
            }
            TextButton(onClick = { showMembers = true }) { Text("👥 ${members.size}") }
        }
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(8.dp)) }
            // "En línea" real en un chat de grupo, comparado con
            // WhatsApp/Messenger -- mismo texto que ChatScreen.kt (1:1)
            // pero con el conteo, ya que aquí puede haber varios a la vez.
            if (onlineMemberIds.isNotEmpty()) {
                Text(
                    "🟢 ${onlineMemberIds.size} en línea",
                    modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            // Fijar un mensaje de grupo real (propio o ajeno) para que
            // aparezca destacado arriba del chat, VISIBLE PARA TODOS los
            // miembros -- a diferencia de starred_messages (totalmente
            // privado), comparado con WhatsApp/Telegram, ver
            // 0089_pin_message.sql.
            val pinnedMessage = messages.firstOrNull { it.pinnedAt != null }
            pinnedMessage?.let { pinned ->
                androidx.compose.material3.Surface(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                    color = MaterialTheme.colorScheme.secondaryContainer
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("📌", modifier = Modifier.padding(end = 8.dp))
                        Text(
                            pinned.body ?: if (pinned.mediaUrl != null) "📷 Foto" else if (pinned.audioUrl != null) "🎤 Nota de voz" else "Mensaje fijado",
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.bodyMedium
                        )
                        IconButton(onClick = { viewModel.togglePin(pinned) }) {
                            Icon(Icons.Filled.Close, contentDescription = "Desfijar")
                        }
                    }
                }
            }
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
                    // Deslizar para responder, comparado con WhatsApp/
                    // Telegram/iMessage -- mismo patrón exacto que
                    // ChatScreen.kt (chat 1:1).
                    val swipeOffsetX = remember(message.id) { androidx.compose.animation.core.Animatable(0f) }
                    val swipeScope = rememberCoroutineScope()
                    val swipeThresholdPx = with(androidx.compose.ui.platform.LocalDensity.current) { 56.dp.toPx() }
                    Box(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            "↩",
                            modifier = Modifier
                                .align(Alignment.CenterStart)
                                .padding(start = 8.dp)
                                .alpha((swipeOffsetX.value / swipeThresholdPx).coerceIn(0f, 1f)),
                            style = MaterialTheme.typography.headlineSmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                    Column(
                        horizontalAlignment = if (isMine) Alignment.End else Alignment.Start,
                        modifier = Modifier
                            .fillMaxWidth()
                            .offset { androidx.compose.ui.unit.IntOffset(swipeOffsetX.value.roundToInt(), 0) }
                            .draggable(
                                orientation = androidx.compose.foundation.gestures.Orientation.Horizontal,
                                state = androidx.compose.foundation.gestures.rememberDraggableState { delta ->
                                    swipeScope.launch {
                                        swipeOffsetX.snapTo((swipeOffsetX.value + delta).coerceIn(0f, swipeThresholdPx * 1.4f))
                                    }
                                },
                                onDragStopped = {
                                    if (swipeOffsetX.value > swipeThresholdPx) {
                                        viewModel.setReplyingTo(message)
                                    }
                                    swipeScope.launch { swipeOffsetX.animateTo(0f) }
                                }
                            )
                    ) {
                        if (!isMine) {
                            Text(
                                sender?.displayName ?: "…",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        // Responder a un mensaje concreto (cita), comparado
                        // con WhatsApp/Telegram/iMessage/Instagram DM --
                        // busca el mensaje real citado en los ya cargados
                        // (mismo grupo); si no está, se omite sin más, sin
                        // texto de relleno inventado. Ver
                        // 0102_message_reply.sql.
                        message.replyToMessageId?.let { repliedId ->
                            val repliedMessage = messages.firstOrNull { it.id == repliedId }
                            if (repliedMessage != null) {
                                Column(
                                    modifier = Modifier
                                        .padding(bottom = 2.dp)
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
                                        .padding(horizontal = 8.dp, vertical = 4.dp)
                                ) {
                                    Text(
                                        repliedMessage.body?.take(80)
                                            ?: if (repliedMessage.mediaUrl != null) "📷 Foto" else if (repliedMessage.audioUrl != null) "🎤 Nota de voz" else "Mensaje",
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1
                                    )
                                }
                            }
                        }
                        // Nota de voz real (0062_group_message_audio.sql),
                        // comparado con WhatsApp/Messenger/Telegram --
                        // mismo reproductor nativo que ChatScreen.kt (1:1).
                        val audioUrl = message.audioUrl
                        val mediaUrl = message.mediaUrl
                        // Enviar una publicación a un chat de grupo real
                        // (0069_message_shared_post.sql), comparado con
                        // Instagram/TikTok/Twitter/Snapchat -- toque en
                        // cualquier parte de la vista previa abre la
                        // publicación completa real (PostDetailScreen.kt),
                        // mismo patrón exacto que ChatScreen.kt (chat 1:1).
                        if (message.sharedPostId != null) {
                            val sharedPostId = message.sharedPostId
                            val sharedPost = sharedPosts[sharedPostId]
                            val sharedAuthor = sharedPost?.let { sharedPostAuthors[it.authorId] }
                            Column(modifier = Modifier.padding(8.dp).clickable { onOpenPost(sharedPostId) }) {
                                if (sharedPost?.mediaUrl != null) {
                                    androidx.compose.foundation.Image(
                                        painter = coil.compose.rememberAsyncImagePainter(sharedPost.mediaUrl),
                                        contentDescription = null,
                                        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                        modifier = Modifier.size(200.dp).clip(RoundedCornerShape(10.dp))
                                    )
                                }
                                Text(
                                    "Publicación de ${sharedAuthor?.displayName ?: "…"}",
                                    style = MaterialTheme.typography.labelSmall,
                                    modifier = Modifier.padding(top = 4.dp)
                                )
                                sharedPost?.caption?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            }
                        } else if (audioUrl != null) {
                            GroupAudioMessageBubble(url = audioUrl, isMine = isMine)
                        } else if (message.isVideo && mediaUrl != null) {
                            // Vídeo real en el chat de grupo, comparado con
                            // WhatsApp/Telegram/iMessage -- mismo patrón
                            // exacto que ChatScreen.kt (1:1).
                            Box(
                                modifier = Modifier.size(200.dp).clip(RoundedCornerShape(12.dp))
                                    .background(androidx.compose.ui.graphics.Color.Black)
                                    .clickable { fullScreenVideoUrl = mediaUrl },
                                contentAlignment = Alignment.Center
                            ) {
                                Text("▶", color = androidx.compose.ui.graphics.Color.White, style = MaterialTheme.typography.headlineLarge)
                            }
                        } else if (mediaUrl != null) {
                            // Fotos reales en un chat de grupo, comparado
                            // con WhatsApp/Instagram/Messenger/Facebook --
                            // mediaUrl ya existía en el esquema
                            // (0057_group_chats.sql), solo faltaba la UI.
                            androidx.compose.foundation.Image(
                                painter = coil.compose.rememberAsyncImagePainter(mediaUrl),
                                contentDescription = null,
                                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                modifier = Modifier
                                    .size(200.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .clickable { fullScreenImageUrl = mediaUrl }
                            )
                        } else {
                            // @menciones reales dentro de un chat de GRUPO
                            // (0090_group_message_mentions.sql), comparado
                            // con WhatsApp/Messenger/Telegram -- resalta
                            // "@usuario" real igual que en captions/
                            // comentarios (MentionHashtagText.kt). Cierra
                            // el alcance deliberado documentado antes:
                            // tocar la mención ahora SÍ abre ese perfil.
                            com.social.app.util.MentionHashtagText(
                                text = message.body ?: "",
                                baseColor = if (isMine) MaterialTheme.colorScheme.onPrimaryContainer else androidx.compose.material3.LocalContentColor.current,
                                onOpenMention = { username ->
                                    mentionScope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenProfile) }
                                },
                                modifier = Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(
                                        if (isMine) MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                                        else MaterialTheme.colorScheme.surfaceVariant
                                    )
                                    .combinedClickable(
                                        onClick = { showPicker = !showPicker },
                                        onLongClick = { managingMessage = message }
                                    )
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
                                // Reaccionar con CUALQUIER emoji,
                                // comparado con Telegram/Messenger/Slack
                                // -- mismo hueco real ya cerrado en el
                                // chat 1:1 (ChatScreen.kt).
                                Text(
                                    "➕",
                                    style = MaterialTheme.typography.titleMedium,
                                    modifier = Modifier.clickable {
                                        groupCustomReactionMessageId = message.id
                                        showPicker = false
                                    }
                                )
                            }
                        }
                        // Editar un mensaje ya enviado en un grupo real
                        // (0065_group_messages_edit_delete.sql), comparado
                        // con WhatsApp/Telegram/Messenger -- mismo aviso
                        // visual que ChatScreen.kt (chat 1:1).
                        if (message.editedAt != null) {
                            Text(
                                "Editado",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        // Reenviar un mensaje real (0072_message_forward.sql),
                        // comparado con WhatsApp/Telegram/Messenger --
                        // mismo patrón exacto que ChatScreen.kt (chat 1:1).
                        if (message.isForwarded) {
                            Text(
                                "Reenviado",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        if (message.body != null || message.mediaUrl != null || message.audioUrl != null) {
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text(
                                    "↩ Responder",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.clickable { viewModel.setReplyingTo(message) }
                                )
                                Text(
                                    "↪ Reenviar",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.clickable { forwardingMessage = message }
                                )
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
            }
            // "Escribiendo…" real en un chat de grupo, comparado con
            // WhatsApp/Messenger -- resuelve los IDs a nombres usando la
            // lista de miembros ya cargada, y a diferencia del chat 1:1
            // puede haber varias personas escribiendo a la vez.
            val typingNames = typingMemberIds
                .filter { it != myId }
                .mapNotNull { id -> members.firstOrNull { it.id == id }?.displayName }
            if (typingNames.isNotEmpty()) {
                val text = when (typingNames.size) {
                    1 -> "${typingNames[0]} está escribiendo…"
                    else -> "${typingNames[0]} y ${typingNames.size - 1} más están escribiendo…"
                }
                Text(
                    text,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp)
                )
            }
            // Responder a un mensaje concreto (cita), comparado con
            // WhatsApp/Telegram/iMessage/Instagram DM -- vista previa real
            // de a qué se está respondiendo, encima del compositor, con
            // una forma real de cancelarlo antes de enviar. Ver
            // GroupChatViewModel.replyingTo(), 0102_message_reply.sql.
            val replyingTo by viewModel.replyingTo.collectAsState()
            replyingTo?.let { quoted ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Respondiendo",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                        Text(
                            quoted.body?.take(80) ?: if (quoted.mediaUrl != null) "📷 Foto" else if (quoted.audioUrl != null) "🎤 Nota de voz" else "Mensaje",
                            style = MaterialTheme.typography.bodySmall,
                            maxLines = 1
                        )
                    }
                    TextButton(onClick = { viewModel.setReplyingTo(null) }) {
                        Text("✕")
                    }
                }
            }
            Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                // Fotos reales en un chat de grupo, comparado con
                // WhatsApp/Instagram/Messenger/Facebook -- mismo patrón
                // exacto que ChatScreen.kt (1:1).
                OutlinedButton(onClick = { pickImage.launch("image/*") }, modifier = Modifier.padding(end = 8.dp)) {
                    Text("📷")
                }
                // Vídeo real en el chat de grupo, comparado con WhatsApp/
                // Telegram/iMessage -- mismo patrón exacto que
                // ChatScreen.kt (1:1).
                OutlinedButton(onClick = { pickVideo.launch("video/*") }, modifier = Modifier.padding(end = 8.dp)) {
                    Text("🎬")
                }
                // Nota de voz real (0062_group_message_audio.sql), mismo
                // patrón exacto que ChatScreen.kt (1:1): MediaRecorder
                // nativo vía VoiceRecorder.kt, sin SDK de terceros.
                OutlinedButton(
                    onClick = {
                        if (isRecording) {
                            isRecording = false
                            voiceRecorder.stop()?.let { pendingGroupVoiceFile = it }
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
                    onValueChange = { draft = it; viewModel.notifyTyping() },
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

    fullScreenImageUrl?.let { url ->
        com.social.app.util.FullScreenImageViewer(url = url, onDismiss = { fullScreenImageUrl = null })
    }
    fullScreenVideoUrl?.let { url ->
        com.social.app.util.FullScreenVideoViewer(url = url, onDismiss = { fullScreenVideoUrl = null })
    }

    if (showMembers) {
        MembersSheet(
            groupChatViewModel = viewModel,
            members = members,
            adminIds = adminIds,
            groupChat = groupChat,
            myId = myId,
            onDismiss = { showMembers = false },
            onLeave = {
                showMembers = false
                viewModel.leaveGroup(onBack)
            }
        )
    }

    // Editar/borrar un mensaje ya enviado en un grupo real
    // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    // Telegram/Messenger -- mismo menú real que ChatScreen.kt (chat 1:1).
    pendingGroupPhotoUri?.let { uri ->
        var groupPhotoCaption by remember(uri) { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingGroupPhotoUri = null },
            title = { Text("Enviar foto") },
            text = {
                OutlinedTextField(
                    value = groupPhotoCaption,
                    onValueChange = { groupPhotoCaption = it },
                    placeholder = { Text("Añadir un comentario (opcional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.sendPhoto(context, uri, caption = groupPhotoCaption)
                    pendingGroupPhotoUri = null
                }) { Text("Enviar") }
            },
            dismissButton = {
                TextButton(onClick = { pendingGroupPhotoUri = null }) { Text("Cancelar") }
            }
        )
    }
    pendingGroupVoiceFile?.let { file ->
        var isPreviewPlaying by remember(file) { mutableStateOf(false) }
        var previewPlayer by remember(file) { mutableStateOf<android.media.MediaPlayer?>(null) }
        androidx.compose.runtime.DisposableEffect(file) {
            onDispose { previewPlayer?.release(); previewPlayer = null }
        }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { previewPlayer?.release(); pendingGroupVoiceFile = null },
            title = { Text("Nota de voz") },
            text = {
                Text(
                    if (isPreviewPlaying) "⏸ Reproduciendo…" else "▶ Escuchar antes de mandarla",
                    modifier = Modifier.clickable {
                        if (isPreviewPlaying) {
                            previewPlayer?.pause()
                            isPreviewPlaying = false
                        } else {
                            val p = previewPlayer ?: android.media.MediaPlayer().apply {
                                setDataSource(file.absolutePath)
                                setOnCompletionListener { isPreviewPlaying = false }
                                prepare()
                            }
                            previewPlayer = p
                            p.start()
                            isPreviewPlaying = true
                        }
                    }
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    previewPlayer?.release()
                    viewModel.sendVoiceNote(file)
                    pendingGroupVoiceFile = null
                }) { Text("Enviar") }
            },
            dismissButton = {
                TextButton(onClick = {
                    previewPlayer?.release()
                    pendingGroupVoiceFile = null
                }) { Text("Descartar") }
            }
        )
    }
    pendingGroupVideoUri?.let { uri ->
        var groupVideoCaption by remember(uri) { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingGroupVideoUri = null },
            title = { Text("Enviar vídeo") },
            text = {
                OutlinedTextField(
                    value = groupVideoCaption,
                    onValueChange = { groupVideoCaption = it },
                    placeholder = { Text("Añadir un comentario (opcional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.sendVideo(context, uri, caption = groupVideoCaption)
                    pendingGroupVideoUri = null
                }) { Text("Enviar") }
            },
            dismissButton = {
                TextButton(onClick = { pendingGroupVideoUri = null }) { Text("Cancelar") }
            }
        )
    }
    groupCustomReactionMessageId?.let { messageId ->
        var customEmoji by remember { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { groupCustomReactionMessageId = null },
            title = { Text("Reaccionar con...") },
            text = {
                OutlinedTextField(
                    value = customEmoji,
                    onValueChange = { if (it.length <= 4) customEmoji = it },
                    placeholder = { Text("Escribe un emoji real (usa el teclado 😊)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        if (customEmoji.isNotBlank()) viewModel.toggleReaction(messageId, customEmoji)
                        groupCustomReactionMessageId = null
                    },
                    enabled = customEmoji.isNotBlank()
                ) { Text("Reaccionar") }
            },
            dismissButton = {
                TextButton(onClick = { groupCustomReactionMessageId = null }) { Text("Cancelar") }
            }
        )
    }
    managingMessage?.let { message ->
        val isMineMessage = message.senderId == myId
        // Mensajes destacados reales, comparado con WhatsApp -- sobre
        // CUALQUIER mensaje de grupo (propio o ajeno), ver
        // GroupChatViewModel.toggleStar(), 0087_starred_messages.sql.
        // Mismo menú real, ahora también abierto al mantener pulsado un
        // mensaje AJENO (antes iba directo a denunciar sin dejar
        // destacarlo).
        val isStarred = starredMessageIds.contains(message.id)
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { managingMessage = null },
            title = { Text("Mensaje") },
            text = {},
            confirmButton = {
                if (isMineMessage) {
                    TextButton(onClick = {
                        editingMessage = message
                        editedMessageText = message.body ?: ""
                        managingMessage = null
                    }) { Text("Editar") }
                } else {
                    TextButton(onClick = {
                        reportMessage = message
                        managingMessage = null
                    }) { Text("Denunciar") }
                }
            },
            dismissButton = {
                Row {
                    // Responder a un mensaje concreto (cita), comparado con
                    // WhatsApp/Telegram/iMessage/Instagram DM -- sobre
                    // CUALQUIER mensaje (propio o ajeno), ver
                    // GroupChatViewModel.setReplyingTo(), 0102_message_reply.sql.
                    TextButton(onClick = {
                        viewModel.setReplyingTo(message)
                        managingMessage = null
                    }) { Text("Responder") }
                    // Copiar texto, comparado con WhatsApp/Telegram/
                    // Messenger -- mismo hueco real ya cerrado en el
                    // chat 1:1 (ChatScreen.kt).
                    if (message.body != null) {
                        TextButton(onClick = {
                            groupClipboardManager.setText(androidx.compose.ui.text.AnnotatedString(message.body))
                            managingMessage = null
                        }) { Text("Copiar") }
                    }
                    // Fijar un mensaje de grupo real (propio o ajeno),
                    // VISIBLE PARA TODOS los miembros -- a diferencia de
                    // "Destacar" (arriba), totalmente privado. Ver
                    // GroupChatViewModel.togglePin(), 0089_pin_message.sql.
                    TextButton(onClick = {
                        viewModel.togglePin(message)
                        managingMessage = null
                    }) { Text(if (message.pinnedAt != null) "Desfijar mensaje" else "Fijar mensaje") }
                    TextButton(onClick = {
                        viewModel.toggleStar(message.id)
                        managingMessage = null
                    }) { Text(if (isStarred) "Quitar destacado" else "Destacar") }
                    // "Eliminar para mí" real, comparado con WhatsApp --
                    // sobre CUALQUIER mensaje (propio o ajeno): el resto
                    // del grupo lo sigue viendo con normalidad. Distinto
                    // de "Borrar para todos" (abajo, solo el propio
                    // remitente). Ver GroupChatViewModel.deleteForMe(),
                    // 0120_delete_group_message_for_me.sql.
                    TextButton(onClick = {
                        viewModel.deleteForMe(message.id)
                        managingMessage = null
                    }) { Text("Eliminar para mí") }
                    if (isMineMessage) {
                        TextButton(onClick = {
                            viewModel.deleteMessage(message.id)
                            managingMessage = null
                        }) { Text("Borrar para todos") }
                    }
                    TextButton(onClick = { managingMessage = null }) { Text("Cancelar") }
                }
            }
        )
    }
    editingMessage?.let { message ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { editingMessage = null },
            title = { Text("Editar mensaje") },
            text = {
                Column {
                    OutlinedTextField(
                        value = editedMessageText,
                        onValueChange = { editedMessageText = it },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text(
                        "${editedMessageText.length}/2000",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (editedMessageText.length > 2000) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.editMessage(message.id, editedMessageText)
                        editingMessage = null
                    },
                    enabled = editedMessageText.isNotEmpty() && editedMessageText.length <= 2000
                ) { Text("Guardar") }
            },
            dismissButton = {
                TextButton(onClick = { editingMessage = null }) { Text("Cancelar") }
            }
        )
    }
    // Denunciar un mensaje concreto de un chat de grupo real
    // (0067_reports_group_message_reference.sql), comparado con
    // Instagram/WhatsApp/Messenger.
    reportMessage?.let { message ->
        myId?.let { reporterId ->
            com.social.app.safety.ReportSheet(
                reporterId = reporterId,
                reportedId = message.senderId,
                groupMessageId = message.id,
                onDismiss = { reportMessage = null }
            )
        }
    }
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    forwardingMessage?.let { message ->
        ForwardMessageSheet(
            body = message.body,
            mediaUrl = message.mediaUrl,
            audioUrl = message.audioUrl,
            onDismiss = { forwardingMessage = null }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MembersSheet(
    groupChatViewModel: GroupChatViewModel,
    members: List<com.social.app.backend.model.Profile>,
    // Administradores reales de grupo, comparado con WhatsApp/Telegram/
    // Messenger -- ver 0107_group_chat_admins.sql.
    adminIds: Set<String>,
    groupChat: GroupChat?,
    myId: String?,
    onDismiss: () -> Unit,
    onLeave: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()
    var showAddPicker by remember { mutableStateOf(false) }
    val socialsViewModel: SocialsListViewModel = viewModel()
    val socials by socialsViewModel.socials.collectAsState()
    LaunchedEffect(Unit) { socialsViewModel.load() }

    // Nombre editable y foto de grupo real, comparado con WhatsApp/
    // Messenger/Telegram -- el creador o cualquier admin real puede
    // tocarlos (RLS `group_chats_update_own`/`_update_by_admin`,
    // 0057/0108_group_chat_rename_by_admin.sql).
    val isCreator = groupChat != null && groupChat.createdBy == myId
    // Administradores reales de grupo, comparado con WhatsApp/Telegram/
    // Messenger -- el creador real siempre es admin (0107), pero aquí se
    // comprueba con adminIds y no solo isCreator para que un admin
    // ascendido (no creador) también vea las mismas acciones reales.
    val isAdmin = myId != null && myId in adminIds
    var editingName by remember { mutableStateOf(false) }
    var nameDraft by remember(groupChat?.name) { mutableStateOf(groupChat?.name.orEmpty()) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val pickGroupPhoto = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri -> uri?.let { groupChatViewModel.updatePhoto(context, it) } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.foundation.Image(
                    painter = coil.compose.rememberAsyncImagePainter(groupChat?.photoUrl),
                    contentDescription = null,
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(androidx.compose.foundation.shape.CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .let { if (isCreator || isAdmin) it.clickable { pickGroupPhoto.launch("image/*") } else it }
                )
                if (editingName) {
                    OutlinedTextField(
                        value = nameDraft,
                        onValueChange = { nameDraft = it },
                        modifier = Modifier.padding(start = 12.dp).weight(1f),
                        singleLine = true
                    )
                    TextButton(onClick = {
                        groupChatViewModel.renameGroup(nameDraft)
                        editingName = false
                    }) { Text("Guardar") }
                } else {
                    Text(
                        groupChat?.name ?: "Miembros del grupo",
                        style = MaterialTheme.typography.titleLarge,
                        modifier = Modifier.padding(start = 12.dp).weight(1f)
                    )
                    // Renombrar el grupo/cambiar su foto también para
                    // admins, comparado con WhatsApp/Telegram/Messenger
                    // -- ver 0108_group_chat_rename_by_admin.sql.
                    if (isCreator || isAdmin) {
                        TextButton(onClick = { editingName = true }) { Text("✏") }
                    }
                }
            }
            members.forEach { member ->
                val memberIsAdmin = member.id in adminIds
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                    com.social.app.avatar.AvatarView(config = member.avatarConfig ?: emptyMap(), size = 32.dp)
                    Row(modifier = Modifier.padding(start = 10.dp).weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        Text(member.displayName)
                        // Administradores reales de grupo, comparado con
                        // WhatsApp/Telegram/Messenger -- ver
                        // 0107_group_chat_admins.sql.
                        if (memberIsAdmin) {
                            Text(
                                " · Admin",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                    }
                    // Ascender/descender a un admin real, comparado con
                    // WhatsApp/Telegram/Messenger -- solo otro admin real
                    // lo ve, y nunca sobre sí mismo.
                    if (isAdmin && member.id != myId) {
                        TextButton(onClick = { groupChatViewModel.toggleAdmin(member.id, !memberIsAdmin) }) {
                            Text(if (memberIsAdmin) "Quitar admin" else "Hacer admin")
                        }
                    }
                    // Expulsar a otro miembro real, comparado con
                    // WhatsApp/Messenger/Telegram -- el creador real o
                    // cualquier admin real lo ve, y nunca sobre sí mismo
                    // (para eso ya está "Salir del grupo").
                    if (isAdmin && member.id != myId) {
                        TextButton(onClick = { groupChatViewModel.kickMember(member.id) }) {
                            Text("Quitar", color = MaterialTheme.colorScheme.error)
                        }
                    }
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
