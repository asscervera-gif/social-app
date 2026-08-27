package com.social.app.chat

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
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
    val allMessages by viewModel.messages.collectAsState()
    // "Eliminar para mí" real, comparado con WhatsApp -- resuelto en el
    // cliente (mismo criterio que muted_feed_keywords, 0116): la fila
    // sigue existiendo de verdad para la otra persona, solo se oculta
    // en MI propia lista. Ver ChatViewModel.deleteForMe(),
    // 0118_delete_message_for_me.sql.
    val messages = allMessages.filter { currentUserId !in it.deletedFor }
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
    // Recibo de lectura real ("Leído ✓✓"), comparado con WhatsApp/
    // Instagram/Messenger -- ver ChatViewModel.showReadReceipts,
    // 0091_read_receipts_toggle.sql.
    val showReadReceipts by viewModel.showReadReceipts.collectAsState()
    val compatibility by viewModel.compatibility.collectAsState()
    // Mensajes que desaparecen real para todo el chat, comparado con
    // WhatsApp/Instagram DM -- ver ChatViewModel.setDisappearingSeconds(),
    // 0115_disappearing_messages.sql.
    val disappearingSeconds by viewModel.disappearingSeconds.collectAsState()
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
    // Foto para ver una vez, comparado con WhatsApp/Instagram DM/
    // Snapchat -- se pregunta al elegir la foto, mismo momento real que
    // 0075_close_friends_stories.sql pregunta la audiencia de una
    // historia. Ver ChatViewModel.sendPhoto(), 0105_view_once_messages.sql.
    var showSearch by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val searchScope = rememberCoroutineScope()
    var pendingPhotoUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) pendingPhotoUri = uri
    }
    // Historial visual real del % de compatibilidad -- el dato ya
    // existía (compatibility_votes, 0032) pero nunca se leía, solo se
    // insertaba. Hueco #1 de la auditoría de sistemas propios de SOCIAL.
    var showCompatibilityHistory by remember { mutableStateOf(false) }
    val compatibilityHistory by viewModel.compatibilityHistory.collectAsState()

    LaunchedEffect(chatId) { viewModel.start() }
    DisposableEffect(chatId) { onDispose { viewModel.stop() } }

    Column(modifier = Modifier.fillMaxSize()) {
        LinearProgressIndicator(
            progress = { compatibility / 100f },
            modifier = Modifier.fillMaxWidth().height(10.dp).padding(horizontal = 16.dp)
        )
        Box(modifier = Modifier.fillMaxWidth()) {
            Text(
                "$compatibility% de compatibilidad · ver historial",
                modifier = Modifier.fillMaxWidth().padding(4.dp).clickable {
                    viewModel.loadCompatibilityHistory()
                    showCompatibilityHistory = true
                },
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
                // Buscar en el chat, comparado con WhatsApp/Telegram/
                // Messenger -- hueco real, ningún chat construido desde
                // cero esta sesión tenía forma de encontrar un mensaje
                // antiguo salvo desplazarse a mano. Alcance deliberado:
                // busca solo entre los mensajes ya cargados en memoria
                // (sin re-consultar el servidor), honesto si el mensaje
                // real está más atrás -- "Cargar anteriores" ya existe
                // arriba para eso.
                IconButton(onClick = { showSearch = true }) {
                    Icon(Icons.Filled.Search, contentDescription = "Buscar en el chat")
                }
                // Mensajes que desaparecen real para todo el chat,
                // comparado con WhatsApp/Instagram DM -- ver
                // ChatViewModel.setDisappearingSeconds(),
                // 0115_disappearing_messages.sql.
                var showDisappearingMenu by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { showDisappearingMenu = true }) {
                        Text(if (disappearingSeconds != null) "🔥" else "🕐")
                    }
                    DropdownMenu(expanded = showDisappearingMenu, onDismissRequest = { showDisappearingMenu = false }) {
                        DropdownMenuItem(text = { Text("Desactivado") }, onClick = {
                            showDisappearingMenu = false
                            viewModel.setDisappearingSeconds(null)
                        })
                        DropdownMenuItem(text = { Text("24 horas") }, onClick = {
                            showDisappearingMenu = false
                            viewModel.setDisappearingSeconds(86400)
                        })
                        DropdownMenuItem(text = { Text("7 días") }, onClick = {
                            showDisappearingMenu = false
                            viewModel.setDisappearingSeconds(604800)
                        })
                        DropdownMenuItem(text = { Text("90 días") }, onClick = {
                            showDisappearingMenu = false
                            viewModel.setDisappearingSeconds(7776000)
                        })
                    }
                }
            }
        }
        if (disappearingSeconds != null) {
            val label = when (disappearingSeconds) {
                86400 -> "24 horas"
                604800 -> "7 días"
                else -> "90 días"
            }
            Text(
                "🔥 Los mensajes nuevos desaparecen a las $label",
                modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        val isOpponentOnline by viewModel.isOpponentOnline.collectAsState()
        val opponentLastActiveAt by viewModel.opponentLastActiveAt.collectAsState()
        if (isOpponentOnline) {
            Text(
                "🟢 En línea",
                modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary
            )
        } else if (opponentLastActiveAt != null) {
            // "Últ. vez hace...", comparado con WhatsApp -- alcance
            // deliberado, sin interruptor de privacidad recíproco
            // todavía. Ver ChatViewModel.loadOpponentLastActive(),
            // 0119_last_active_at.sql.
            Text(
                "Últ. vez ${com.social.app.util.relativeTime(opponentLastActiveAt!!)}",
                modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
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

        // Fijar un mensaje real (propio o ajeno) para que aparezca
        // destacado arriba del chat, VISIBLE PARA TODOS los participantes
        // -- a diferencia de starred_messages (totalmente privado),
        // comparado con WhatsApp/Telegram, ver 0089_pin_message.sql.
        val pinnedMessage = messages.firstOrNull { it.pinnedAt != null }
        pinnedMessage?.let { pinned ->
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                shape = RoundedCornerShape(10.dp),
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

        val reactionEmojis = listOf("❤", "😂", "😮", "😢", "👍")
        LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) {
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
                        // Responder a un mensaje concreto (cita), comparado
                        // con WhatsApp/Telegram/iMessage/Instagram DM --
                        // busca el mensaje real citado en los ya cargados
                        // (mismo chat); si no está (p. ej. quedó fuera de
                        // la página cargada, o se borró y quedó en null
                        // por `on delete set null`), se omite sin más, sin
                        // texto de relleno inventado. Ver
                        // 0102_message_reply.sql.
                        message.replyToMessageId?.let { repliedId ->
                            val repliedMessage = messages.firstOrNull { it.id == repliedId }
                            if (repliedMessage != null) {
                                Column(
                                    modifier = Modifier
                                        .padding(top = 6.dp, start = 8.dp, end = 8.dp)
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
                        } else if (message.viewOnce && message.openedAt != null) {
                            // Foto real "para ver una vez" ya consumida,
                            // comparado con WhatsApp/Instagram DM/
                            // Snapchat -- el propio servidor ya vació
                            // media_url de verdad (0105_view_once_messages.sql),
                            // ni siquiera el remitente puede volver a verla.
                            Text(
                                "🔥 Foto vista",
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(if (isMine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                                    .combinedClickable(onClick = {}, onLongClick = { managingMessage = message })
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                                color = if (isMine) androidx.compose.ui.graphics.Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        } else if (message.viewOnce && message.mediaUrl != null) {
                            // Foto real "para ver una vez" todavía sin
                            // abrir -- el toque real solo tiene efecto
                            // para el destinatario (ChatViewModel.
                            // openViewOnceMessage()); el propio remitente
                            // no puede consumir la suya (protect_message_columns
                            // ya lo impide del lado del servidor).
                            Text(
                                if (isMine) "🔥 Enviada para ver una vez" else "🔥 Toca para ver una vez",
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(if (isMine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                                    .combinedClickable(
                                        onClick = {
                                            if (!isMine) {
                                                viewModel.openViewOnceMessage(message.id)?.let { url -> fullScreenImageUrl = url }
                                            }
                                        },
                                        onLongClick = { managingMessage = message }
                                    )
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                                color = if (isMine) androidx.compose.ui.graphics.Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                            )
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
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(
                                "↩ Responder",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.clickable { viewModel.setReplyingTo(message) }
                            )
                            // Foto para ver una vez, comparado con
                            // WhatsApp/Instagram DM/Snapchat -- nunca
                            // reenviable, igual que esas apps (todo el
                            // punto real es que solo la vea el
                            // destinatario elegido, una sola vez).
                            if (!message.viewOnce) {
                                Text(
                                    "↪ Reenviar",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.clickable { forwardingMessage = message }
                                )
                            }
                        }
                    }
                    if (isMine) {
                        // Recibo de lectura real, comparado con WhatsApp/
                        // Instagram/Messenger -- `showReadReceipts` ya es
                        // false si CUALQUIERA de los dos desactivó el
                        // suyo, ver ChatViewModel.loadReadReceiptsVisibility(),
                        // 0091_read_receipts_toggle.sql.
                        val showRead = message.readAt != null && showReadReceipts
                        // Entregado real (✓✓ gris), comparado con
                        // WhatsApp -- estado intermedio entre "Enviado"
                        // (✓) y "Leído" (✓✓ azul), ver 0117_message_delivered_status.sql.
                        val showDelivered = message.deliveredAt != null && showReadReceipts
                        Text(
                            when {
                                showRead -> "Leído ✓✓"
                                showDelivered -> "Entregado ✓✓"
                                else -> "Enviado ✓"
                            },
                            style = MaterialTheme.typography.labelSmall,
                            color = if (showRead) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
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

        // Responder a un mensaje concreto (cita), comparado con
        // WhatsApp/Telegram/iMessage/Instagram DM -- vista previa real de
        // a qué se está respondiendo, encima del compositor, con una
        // forma real de cancelarlo antes de enviar. Ver
        // ChatViewModel.replyingTo(), 0102_message_reply.sql.
        val replyingTo by viewModel.replyingTo.collectAsState()
        replyingTo?.let { quoted ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp)
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
                androidx.compose.material3.TextButton(onClick = { viewModel.setReplyingTo(null) }) {
                    Text("✕")
                }
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
    // Foto para ver una vez, comparado con WhatsApp/Instagram DM/
    // Snapchat -- ver ChatViewModel.sendPhoto(), 0105_view_once_messages.sql.
    pendingPhotoUri?.let { uri ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingPhotoUri = null },
            title = { Text("Enviar foto") },
            text = { Text("¿Cómo quieres enviarla?") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.sendPhoto(context, uri, viewOnce = true)
                    pendingPhotoUri = null
                }) { Text("🔥 Ver una vez") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = {
                    viewModel.sendPhoto(context, uri, viewOnce = false)
                    pendingPhotoUri = null
                }) { Text("Normal") }
            }
        )
    }
    if (showCompatibilityHistory) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showCompatibilityHistory = false },
            title = { Text("Historial de compatibilidad") },
            text = {
                if (compatibilityHistory.isEmpty()) {
                    Text("Todavía no hay ningún voto real de compatibilidad en este chat.")
                } else {
                    LazyColumn {
                        items(compatibilityHistory) { entry ->
                            val quien = if (entry.voterId == currentUserId) "Tú" else "La otra persona"
                            val signo = if (entry.delta > 0) "+" else ""
                            Text(
                                "$quien votó $signo${entry.delta} · ${com.social.app.util.relativeTime(entry.createdAt)}",
                                modifier = Modifier.padding(vertical = 4.dp)
                            )
                        }
                    }
                }
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { showCompatibilityHistory = false }) { Text("Cerrar") }
            }
        )
    }
    if (showSearch) {
        val matches = if (searchQuery.isBlank()) emptyList() else messages.filter {
            it.body?.contains(searchQuery, ignoreCase = true) == true
        }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showSearch = false },
            title = { Text("Buscar en el chat") },
            text = {
                Column {
                    OutlinedTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        placeholder = { Text("Texto a buscar") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    if (searchQuery.isNotBlank() && matches.isEmpty()) {
                        Text(
                            "Sin resultados entre los mensajes ya cargados. Prueba \"Cargar anteriores\" si es un mensaje viejo.",
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                    androidx.compose.foundation.lazy.LazyColumn(modifier = Modifier.padding(top = 8.dp)) {
                        items(matches) { match ->
                            Text(
                                match.body.orEmpty(),
                                maxLines = 1,
                                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp).clickable {
                                    val index = messages.indexOfFirst { it.id == match.id }
                                    // +1 si "Cargar anteriores" está visible arriba (ocupa el
                                    // primer item real de la LazyColumn).
                                    if (index >= 0) searchScope.launch { listState.animateScrollToItem(index + if (hasMoreHistory) 1 else 0) }
                                    showSearch = false
                                }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { showSearch = false }) { Text("Cerrar") }
            }
        )
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
    val clipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
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
                    // Responder a un mensaje concreto (cita), comparado con
                    // WhatsApp/Telegram/iMessage/Instagram DM -- sobre
                    // CUALQUIER mensaje (propio o ajeno), ver
                    // ChatViewModel.setReplyingTo(), 0102_message_reply.sql.
                    androidx.compose.material3.TextButton(onClick = {
                        viewModel.setReplyingTo(message)
                        managingMessage = null
                    }) { Text("Responder") }
                    // Copiar texto, comparado con WhatsApp/Telegram/
                    // Messenger -- hueco real, básico y universal,
                    // ningún chat de esta sesión lo tenía.
                    if (message.body != null) {
                        androidx.compose.material3.TextButton(onClick = {
                            clipboardManager.setText(androidx.compose.ui.text.AnnotatedString(message.body))
                            managingMessage = null
                        }) { Text("Copiar") }
                    }
                    // Fijar un mensaje real (propio o ajeno), VISIBLE PARA
                    // TODOS los participantes -- a diferencia de "Destacar"
                    // (arriba), totalmente privado. Ver
                    // ChatViewModel.togglePin(), 0089_pin_message.sql.
                    androidx.compose.material3.TextButton(onClick = {
                        viewModel.togglePin(message)
                        managingMessage = null
                    }) { Text(if (message.pinnedAt != null) "Desfijar mensaje" else "Fijar mensaje") }
                    androidx.compose.material3.TextButton(onClick = {
                        viewModel.toggleStar(message.id)
                        managingMessage = null
                    }) { Text(if (isStarred) "Quitar destacado" else "Destacar") }
                    // "Eliminar para mí" real, comparado con WhatsApp --
                    // sobre CUALQUIER mensaje (propio o ajeno): la otra
                    // persona lo sigue viendo con normalidad, solo
                    // desaparece de MI copia. Distinto real de "Borrar
                    // para todos" (abajo, solo el propio remitente),
                    // que sí lo borra de verdad para las dos personas.
                    // Ver ChatViewModel.deleteForMe(),
                    // 0118_delete_message_for_me.sql.
                    androidx.compose.material3.TextButton(onClick = {
                        viewModel.deleteForMe(message.id)
                        managingMessage = null
                    }) { Text("Eliminar para mí") }
                    if (isMineMessage) {
                        androidx.compose.material3.TextButton(onClick = {
                            viewModel.deleteMessage(message.id)
                            managingMessage = null
                        }) { Text("Borrar para todos") }
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
    // Velocidad de reproducción real (1x/1.5x/2x), comparado con
    // WhatsApp -- hueco real, básico en cualquier nota de voz grande.
    var speed by remember { mutableStateOf(1f) }

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
                        setOnPreparedListener {
                            try { playbackParams = playbackParams.setSpeed(speed) } catch (e: Exception) {}
                            start()
                        }
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
        Text(
            " ${speed}x",
            color = if (isMine) androidx.compose.ui.graphics.Color.White else androidx.compose.ui.graphics.Color.Unspecified,
            modifier = Modifier.clickable {
                speed = when (speed) { 1f -> 1.5f; 1.5f -> 2f; else -> 1f }
                player?.let {
                    try {
                        it.playbackParams = it.playbackParams.setSpeed(speed)
                    } catch (e: Exception) { /* no soportado en este dispositivo */ }
                }
            }
        )
    }
}

@Composable
private fun VoteButton(label: String, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier) {
        Text(label, style = MaterialTheme.typography.labelSmall)
    }
}
