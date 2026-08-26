package com.social.app.chat

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.rememberAsyncImagePainter

/**
 * Chat con barra de compatibilidad en vivo — equivalente Compose de
 * ChatView.swift. Botones +1/+10/+100 y -1/-10/-100, actividad sugerida al
 * superar 50%, mismo comportamiento que iOS y que el prototipo web.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ChatScreen(
    chatId: String,
    currentUserId: String,
    onStartDuel: (opponentId: String) -> Unit = {},
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat -- ver
    // PostDetailScreen.kt para el hallazgo completo: antes tocar la vista
    // previa de una publicación compartida solo abría la foto, sin
    // pantalla propia de "post".
    onOpenPost: (String) -> Unit = {},
    // Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado
    // con WhatsApp/Messenger/Instagram -- `callManager` es el mismo
    // global de RootTabView.kt (una llamada puede llegar en cualquier
    // pestaña), este chat solo la INICIA.
    callManager: com.social.app.calls.CallManager? = null
) {
    val viewModel = remember(chatId) { ChatViewModel(chatId) }
    val messages by viewModel.messages.collectAsState()
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat.
    val sharedPosts by viewModel.sharedPosts.collectAsState()
    val sharedPostAuthors by viewModel.sharedPostAuthors.collectAsState()
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    val storyPreviews by viewModel.storyPreviews.collectAsState()
    val reactions by viewModel.reactions.collectAsState()
    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql).
    val starredMessageIds by viewModel.starredMessageIds.collectAsState()
    val compatibility by viewModel.compatibility.collectAsState()
    val opponentId by viewModel.opponentId.collectAsState()
    val suggestedActivity by viewModel.suggestedActivity.collectAsState()
    val icebreaker by viewModel.icebreaker.collectAsState()
    val hasMoreHistory by viewModel.hasMoreHistory.collectAsState()
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // forma de tocar una foto del chat para verla a tamaño completo,
    // solo la miniatura recortada de 200dp.
    var fullScreenImageUrl by remember { mutableStateOf<String?>(null) }
    val isLoadingOlder by viewModel.isLoadingOlder.collectAsState()
    var draft by remember { mutableStateOf("") }
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // ninguna forma de denunciar o bloquear a la otra persona DESDE el
    // propio chat -- justo donde ocurre la mayoría del acoso real, según
    // cualquier app de mensajería grande. ReportSheet ya existe y ya
    // incluye ambas acciones, solo faltaba este punto de entrada.
    var showReportSheet by remember { mutableStateOf(false) }
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: no había
    // forma de denunciar un MENSAJE concreto, solo a la otra persona en
    // general -- mantener pulsado un mensaje ajeno (el propio ya usa
    // mantener pulsado para borrar) lo denuncia con referencia real al
    // mensaje. Ver 0048_reports_message_reference.sql.
    var reportMessageId by remember { mutableStateOf<String?>(null) }
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: mantener
    // pulsado un mensaje propio lo borraba al instante, SIN confirmación
    // -- y no había forma de corregirlo, solo de borrarlo entero. Ahora
    // mantener pulsado abre un menú real (Editar/Borrar/Cancelar) en vez
    // de un borrado directo -- ver 0049_messages_edit.sql.
    var managingMessage by remember { mutableStateOf<com.social.app.backend.model.ChatMessage?>(null) }
    var editingMessage by remember { mutableStateOf<com.social.app.backend.model.ChatMessage?>(null) }
    var editedMessageText by remember { mutableStateOf("") }
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var forwardingMessage by remember { mutableStateOf<com.social.app.backend.model.ChatMessage?>(null) }
    val context = LocalContext.current
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) viewModel.sendPhoto(context, uri)
    }

    LaunchedEffect(chatId) { viewModel.start() }
    DisposableEffect(chatId) { onDispose { viewModel.stop() } }

    Column(modifier = Modifier.fillMaxSize()) {
        LinearProgressIndicator(
            progress = { compatibility / 100f },
            modifier = Modifier.fillMaxWidth().height(10.dp).padding(horizontal = 16.dp)
        )
        Box(modifier = Modifier.fillMaxWidth()) {
            Text(
                "$compatibility% de compatibilidad",
                modifier = Modifier.fillMaxWidth().padding(4.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = MaterialTheme.typography.labelMedium
            )
            Row(modifier = Modifier.align(Alignment.CenterEnd)) {
                // Videollamada/llamada de voz 1:1 real (0079_calls.sql),
                // comparado con WhatsApp/Messenger/Instagram -- mensajería
                // sin llamada directa desde el propio chat es la excepción
                // hoy, no la norma.
                opponentId?.let { opponent ->
                    IconButton(onClick = { callManager?.startCall(chatId, opponent, "audio") }) {
                        Icon(Icons.Filled.Call, contentDescription = "Llamar")
                    }
                    IconButton(onClick = { callManager?.startCall(chatId, opponent, "video") }) {
                        Icon(Icons.Filled.Videocam, contentDescription = "Videollamada")
                    }
                }
                IconButton(onClick = { showReportSheet = true }) {
                    Icon(Icons.Filled.Warning, contentDescription = "Denunciar", tint = MaterialTheme.colorScheme.error)
                }
            }
        }
        val isOpponentOnline by viewModel.isOpponentOnline.collectAsState()
        if (isOpponentOnline) {
            Text(
                "🟢 En línea",
                modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                VoteButton("-100") { viewModel.vote(-100) }
                VoteButton("-10") { viewModel.vote(-10) }
                VoteButton("-1") { viewModel.vote(-1) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                VoteButton("+1") { viewModel.vote(1) }
                VoteButton("+10") { viewModel.vote(10) }
                VoteButton("+100") { viewModel.vote(100) }
            }
        }

        // Antes DuelScreen no tenía ningún punto de entrada real en la app
        // (la ruta de navegación existía en RootTabView.kt pero nadie
        // navegaba a ella) — este es el sitio natural: retar al duelo desde
        // el chat con esa persona.
        opponentId?.let { opponent ->
            Button(
                onClick = { onStartDuel(opponent) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)
            ) {
                Text("⚡ Retar a duelo")
            }
        }

        // Antes esto era un texto fijo hardcodeado, no reflejaba la fila real
        // de la tabla `activities` (mismo bug que ChatViewModel.swift ya
        // evitaba consultando de verdad). Ahora sale de suggestedActivity.
        suggestedActivity?.let { activity ->
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.tertiaryContainer
            ) {
                Text("✨ Actividad sugerida: $activity", modifier = Modifier.padding(10.dp))
            }
        }

        val reactionEmojis = listOf("❤", "😂", "😮", "😢", "👍")
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
            // Hueco real: sin esto, un chat con más de 100 mensajes perdía
            // silenciosamente todo lo anterior a los últimos 100, sin forma
            // de volver a verlo (ver ChatViewModel.loadOlderMessages()).
            if (hasMoreHistory) {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        horizontalArrangement = Arrangement.Center
                    ) {
                        if (isLoadingOlder) {
                            androidx.compose.material3.CircularProgressIndicator(modifier = Modifier.size(20.dp))
                        } else {
                            OutlinedButton(onClick = { viewModel.loadOlderMessages() }) {
                                Text("Cargar mensajes anteriores")
                            }
                        }
                    }
                }
            }
            items(messages) { message ->
                val isMine = message.senderId == currentUserId
                var showPicker by remember { mutableStateOf(false) }
                Column(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
                    horizontalAlignment = if (isMine) Alignment.End else Alignment.Start
                ) {
                    Surface(
                        shape = RoundedCornerShape(14.dp),
                        color = if (isMine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
                        // Hallazgo real: no había forma de borrar un mensaje
                        // propio — mantener pulsado el tuyo lo borra (ver
                        // 0022_messages_delete.sql).
                        modifier = Modifier.combinedClickable(
                            onClick = { showPicker = !showPicker },
                            onLongClick = { managingMessage = message }
                        )
                    ) {
                        // Enviar una publicación a un chat real
                        // (0069_message_shared_post.sql), comparado con
                        // Instagram/TikTok/Twitter/Snapchat -- toque en
                        // cualquier parte de la vista previa abre la
                        // publicación completa real (PostDetailScreen.kt),
                        // mismo criterio que Instagram/Messenger: antes
                        // solo abría la foto a tamaño completo.
                        if (message.storyId != null) {
                            // Responder a una historia real
                            // (0071_message_story_reply.sql), comparado
                            // con Instagram/WhatsApp Status/Snapchat --
                            // "Historia ya no disponible" si expiró/se
                            // borró (stories_select filtra expires_at,
                            // comportamiento correcto, no un fallo).
                            val storyPreview = storyPreviews[message.storyId]
                            Column(modifier = Modifier.padding(8.dp)) {
                                if (storyPreview != null) {
                                    Image(
                                        painter = rememberAsyncImagePainter(storyPreview.mediaUrl),
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.size(120.dp).clip(RoundedCornerShape(10.dp))
                                    )
                                }
                                Text(
                                    if (isMine) "Respondiste a una historia" else "Respondió a tu historia",
                                    style = MaterialTheme.typography.labelSmall
                                )
                                if (storyPreview == null) {
                                    Text("Historia ya no disponible", style = MaterialTheme.typography.labelSmall)
                                }
                                message.body?.let { Text(it, modifier = Modifier.padding(top = 4.dp)) }
                            }
                        } else if (message.sharedPostId != null) {
                            val sharedPostId = message.sharedPostId
                            val sharedPost = sharedPosts[sharedPostId]
                            val sharedAuthor = sharedPost?.let { sharedPostAuthors[it.authorId] }
                            Column(modifier = Modifier.padding(8.dp).clickable { onOpenPost(sharedPostId) }) {
                                if (sharedPost?.mediaUrl != null) {
                                    Image(
                                        painter = rememberAsyncImagePainter(sharedPost.mediaUrl),
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
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
                        } else if (message.mediaUrl != null) {
                            Image(
                                painter = rememberAsyncImagePainter(message.mediaUrl),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                // Toque propio (distinto del de la burbuja):
                                // abre la foto a tamaño completo en vez de
                                // alternar el selector de reacciones --
                                // mantener pulsado sigue borrando el propio
                                // mensaje, igual que el resto de la burbuja.
                                modifier = Modifier.size(200.dp).clip(RoundedCornerShape(14.dp))
                                    .combinedClickable(
                                        onClick = { fullScreenImageUrl = message.mediaUrl },
                                        onLongClick = { managingMessage = message }
                                    )
                            )
                        } else if (message.audioUrl != null) {
                            // Última pieza real de "chat funcional" — nota
                            // de voz, reproducción con MediaPlayer nativo.
                            AudioMessageBubble(url = message.audioUrl, isMine = isMine)
                        } else {
                            Text(message.body ?: "", modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp))
                        }
                    }
                    // Hallazgo real: última pieza de "chat funcional con
                    // fotos, voz, reacciones, read receipts" alcanzable sin
                    // infraestructura nueva — ver 0018_message_reactions.sql.
                    // Toque en la burbuja abre/cierra un selector rápido de
                    // emojis; las reacciones existentes se agrupan con su
                    // recuento, resaltadas si el usuario ya reaccionó así.
                    val messageReactions = reactions[message.id].orEmpty()
                    if (messageReactions.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            messageReactions.groupBy { it.emoji }.forEach { (emoji, group) ->
                                val iReacted = group.any { it.userId == currentUserId }
                                Surface(
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
                    // Hallazgo real, comparado con WhatsApp/Telegram/
                    // Messenger: mismo aviso visual que esas apps cuando un
                    // mensaje se corrigió después de enviarse -- ver
                    // 0049_messages_edit.sql.
                    if (message.editedAt != null) {
                        Text(
                            "Editado",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    // Reenviar un mensaje real (0072_message_forward.sql),
                    // comparado con WhatsApp/Telegram/Messenger --
                    // etiqueta real cuando corresponde, y un tap target
                    // siempre visible (no solo con mantener pulsado, ya
                    // usado para editar/borrar/denunciar) para reenviar
                    // cualquier mensaje real (propio o ajeno) con
                    // contenido real (texto/foto/audio) -- las publicaciones
                    // compartidas/respuestas a historias quedan fuera de
                    // alcance a propósito (sin body/media/audio propios).
                    if (message.isForwarded) {
                        Text(
                            "Reenviado",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (message.body != null || message.mediaUrl != null || message.audioUrl != null) {
                        Text(
                            "↪ Reenviar",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.clickable { forwardingMessage = message }
                        )
                    }
                    if (isMine) {
                        Text(
                            if (message.readAt != null) "Leído ✓✓" else "Enviado ✓",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (message.readAt != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        val isOpponentTyping by viewModel.isOpponentTyping.collectAsState()
        if (isOpponentTyping) {
            Text(
                "Escribiendo…",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp)
            )
        }

        // "Potenciar la IA" (petición explícita del usuario), comparado
        // con Hinge/Bumble: sugerencia real para arrancar la conversación
        // en un chat nuevo — nunca se envía sola, solo rellena el campo.
        icebreaker?.let { suggestion ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp)
                    .clickable { draft = suggestion; viewModel.dismissIcebreaker() },
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("✨", modifier = Modifier.padding(end = 8.dp))
                Text(
                    suggestion,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                androidx.compose.material3.TextButton(onClick = { viewModel.dismissIcebreaker() }) {
                    Text("✕")
                }
            }
        }

        // Última pieza real de "chat funcional con fotos, voz, reacciones,
        // read receipts" — grabación nativa con MediaRecorder (ver
        // VoiceRecorder.kt), sin SDK de terceros.
        val voiceRecorder = remember { VoiceRecorder(context) }
        var isRecording by remember { mutableStateOf(false) }
        val recordPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                voiceRecorder.start()
                isRecording = true
            }
        }

        Row(modifier = Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { pickImage.launch("image/*") }, modifier = Modifier.padding(end = 8.dp)) {
                Text("📷")
            }
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
                onValueChange = { draft = it; viewModel.notifyTyping() },
                modifier = Modifier.weight(1f),
                placeholder = { Text(if (isRecording) "Grabando…" else "Escribe un mensaje…") },
                enabled = !isRecording
            )
            Button(onClick = { viewModel.sendMessage(draft); draft = "" }, modifier = Modifier.padding(start = 8.dp), enabled = !isRecording) {
                Text("➤")
            }
        }
    }
    fullScreenImageUrl?.let { url ->
        com.social.app.util.FullScreenImageViewer(url = url, onDismiss = { fullScreenImageUrl = null })
    }
    if (showReportSheet) {
        opponentId?.let { opponent ->
            com.social.app.safety.ReportSheet(
                reporterId = currentUserId,
                reportedId = opponent,
                onDismiss = { showReportSheet = false }
            )
        }
    }
    reportMessageId?.let { messageId ->
        opponentId?.let { opponent ->
            com.social.app.safety.ReportSheet(
                reporterId = currentUserId,
                reportedId = opponent,
                messageId = messageId,
                onDismiss = { reportMessageId = null }
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
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: mantener
    // pulsado un mensaje propio lo borraba al instante sin confirmación --
    // ahora un menú real, ver 0049_messages_edit.sql.
    managingMessage?.let { message ->
        val isMineMessage = message.senderId == currentUserId
        // Mensajes destacados reales, comparado con WhatsApp -- sobre
        // CUALQUIER mensaje (propio o ajeno), ver ChatViewModel.toggleStar(),
        // 0087_starred_messages.sql. Mismo menú real, ahora también abierto
        // al mantener pulsado un mensaje AJENO (antes iba directo a
        // denunciar sin dejar destacarlo).
        val isStarred = starredMessageIds.contains(message.id)
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { managingMessage = null },
            title = { Text("Mensaje") },
            text = {},
            confirmButton = {
                if (isMineMessage) {
                    androidx.compose.material3.TextButton(onClick = {
                        editingMessage = message
                        editedMessageText = message.body ?: ""
                        managingMessage = null
                    }) { Text("Editar") }
                } else {
                    androidx.compose.material3.TextButton(onClick = {
                        reportMessageId = message.id
                        managingMessage = null
                    }) { Text("Denunciar") }
                }
            },
            dismissButton = {
                Row {
                    androidx.compose.material3.TextButton(onClick = {
                        viewModel.toggleStar(message.id)
                        managingMessage = null
                    }) { Text(if (isStarred) "Quitar destacado" else "Destacar") }
                    if (isMineMessage) {
                        androidx.compose.material3.TextButton(onClick = {
                            viewModel.deleteMessage(message.id)
                            managingMessage = null
                        }) { Text("Borrar") }
                    }
                    androidx.compose.material3.TextButton(onClick = { managingMessage = null }) { Text("Cancelar") }
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
                    androidx.compose.material3.OutlinedTextField(
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
                androidx.compose.material3.TextButton(
                    onClick = {
                        viewModel.editMessage(message.id, editedMessageText)
                        editingMessage = null
                    },
                    enabled = editedMessageText.isNotEmpty() && editedMessageText.length <= 2000
                ) { Text("Guardar") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { editingMessage = null }) { Text("Cancelar") }
            }
        )
    }
}

/** Reproductor de nota de voz — `MediaPlayer` nativo, sin SDK de terceros,
 * mismo criterio que `VoiceRecorder`. Se libera al salir de composición
 * para no dejar el reproductor vivo en segundo plano. */
@Composable
private fun AudioMessageBubble(url: String, isMine: Boolean) {
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
        Text(" Nota de voz", color = if (isMine) androidx.compose.ui.graphics.Color.White else androidx.compose.ui.graphics.Color.Unspecified)
    }
}

@Composable
private fun VoteButton(label: String, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier) {
        Text(label, style = MaterialTheme.typography.labelSmall)
    }
}
