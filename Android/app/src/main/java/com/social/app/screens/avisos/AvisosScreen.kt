package com.social.app.screens.avisos

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
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
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.NotificationEntry
import com.social.app.chat.SocialLinkManager
import com.social.app.ui.theme.SocialColors
import com.social.app.util.relativeTime
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

/**
 * Lista de avisos: social, follow, fight, like, solicitud de %. Al tocar un
 * aviso de social pendiente, se abre una hoja para aceptar/rechazar —
 * equivalente Compose de NotificationActionsSheet en AvisosView.swift.
 * Antes Android no tenía NINGUNA implementación de este flujo (a diferencia
 * de iOS, que sí lo tenía cableado, aunque en ningún lado se envía el
 * social todavía — ver SocialLinkManager.kt para el porqué).
 *
 * Aviso de honestidad: asume que el backend rellena `payload.social_id` (para
 * responder) o `payload.chat_id` (una vez aceptado) al crear la notificación
 * de tipo "social" — mencionado como pendiente server-side en
 * `SocialLinkManager.swift`. Si esa pieza no existe, esta pantalla no tiene
 * nada que hacer; no es un bug del cliente.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AvisosScreen(
    onOpenChat: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
    onOpenDuelResult: (String) -> Unit,
    // Publicación individual real, comparado con Instagram/Twitter/
    // Facebook -- ver PostDetailScreen.kt para el hallazgo completo: un
    // aviso de "like"/"comentario" no llevaba a ningún sitio.
    onOpenPost: (String) -> Unit = {},
    // Hallazgo real de paso: un aviso de mensaje de GRUPO tampoco llevaba
    // a ningún sitio, a diferencia de "message" (chat 1:1).
    onOpenGroupChat: (String) -> Unit = {},
    viewModel: AvisosViewModel = viewModel()
) {
    val notifications by viewModel.notifications.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val actorProfiles by viewModel.actorProfiles.collectAsState()
    var selected by remember { mutableStateOf<NotificationEntry?>(null) }
    LaunchedEffect(Unit) { viewModel.start() }

    // Hallazgo real: comparado con Instagram/Twitter/Facebook, Avisos
    // tampoco tenía pull-to-refresh (ya añadido a Home/Match esta sesión).
    val pullState = rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            viewModel.refresh()
            pullState.endRefresh()
        }
    }

    androidx.compose.foundation.layout.Box(
        modifier = Modifier.fillMaxWidth().nestedScroll(pullState.nestedScrollConnection)
    ) {
    LazyColumn(modifier = Modifier.fillMaxWidth()) {
        // Hallazgo real, comparado con Gmail/Instagram/Twitter: cualquier
        // lista de notificaciones grande deja marcar todo como leído de
        // una vez, no solo aviso por aviso.
        if (notifications.any { it.readAt == null }) {
            item {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.End
                ) {
                    androidx.compose.material3.TextButton(onClick = { viewModel.markAllRead() }) {
                        Text("Marcar todo leído")
                    }
                }
            }
        }
        errorMessage?.let { message ->
            item { Text(message, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
        }
        items(notifications) { entry ->
            NotificationRow(entry, actorProfile = entry.payload["actor_id"]?.let { actorProfiles[it] }, onClick = {
                viewModel.markRead(entry)
                val chatId = entry.payload["chat_id"]
                when {
                    entry.kind == "social" && chatId != null -> onOpenChat(chatId)
                    entry.kind == "social" -> selected = entry
                    entry.kind == "follow" -> selected = entry
                    entry.kind == "compat_request" -> selected = entry
                    entry.kind == "fight" -> selected = entry
                    // Hallazgo real: aceptar un social o una solicitud de
                    // compatibilidad no notificaba nunca a quien la pidió
                    // -- ver 0046_notify_accepted.sql.
                    entry.kind == "social_accepted" -> selected = entry
                    entry.kind == "compat_accepted" -> selected = entry
                    // Hallazgo real, el hueco de mensajería más grande de
                    // la sesión: ningún mensaje nuevo generaba nunca un
                    // aviso -- ver 0047_message_notify_mute.sql. Va
                    // directo al chat, mismo criterio que "social" con
                    // chat_id: un aviso de mensaje no tiene ninguna acción
                    // que mostrar en la hoja genérica, solo abrir el chat.
                    entry.kind == "message" && chatId != null -> onOpenChat(chatId)
                    // Publicación individual real, comparado con Instagram/
                    // Twitter/Facebook -- `payload.post_id` ya existía
                    // desde 0007_likes.sql/0008_comments.sql, pero ningún
                    // cliente lo usaba nunca: tocar el aviso era un tap
                    // muerto (marcaba leído y ya). Ver PostDetailScreen.kt.
                    (entry.kind == "like" || entry.kind == "comment") && entry.payload["post_id"] != null ->
                        onOpenPost(entry.payload["post_id"]!!)
                    // Hallazgo real de paso: mismo hueco exacto que
                    // "message" pero para un mensaje de GRUPO
                    // (0058_group_message_notify.sql ya manda
                    // group_chat_id desde esa ronda, sin cliente que lo usara).
                    entry.kind == "group_message" && entry.payload["group_chat_id"] != null ->
                        onOpenGroupChat(entry.payload["group_chat_id"]!!)
                }
            })
        }
    }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }

    selected?.let { entry ->
        NotificationActionsSheet(
            entry = entry,
            actorProfile = entry.payload["actor_id"]?.let { actorProfiles[it] },
            onOpenChat = onOpenChat,
            onOpenProfile = onOpenProfile,
            onOpenDuelResult = onOpenDuelResult,
            onDismiss = { selected = null }
        )
    }
}

/** Frase de contexto por tipo de aviso -- mismo criterio que `context` en
 * el `openSheet()` de SOCIAL_APP.html: explica qué significa el aviso
 * antes de mostrar las acciones, en vez de solo un título suelto. */
private fun contextFor(kind: String): String = when (kind) {
    "social" -> "Te ha enviado un social. Acéptalo para conectar."
    "follow" -> "Ha solicitado seguirte."
    "fight" -> "Te ha retado a un duelo de preguntas."
    "compat_request" -> "Quiere ver vuestra compatibilidad. Acéptalo para desvelarla mutuamente."
    "like", "comment", "reel_like", "reel_comment" -> "Ha interactuado con tu contenido."
    "social_accepted" -> "Aceptó tu social."
    "compat_accepted" -> "Compartió su compatibilidad contigo."
    else -> "Nueva notificación."
}

/**
 * Hoja de acciones al tocar un aviso -- reconstruida siguiendo la
 * ESTRUCTURA exacta de `openSheet()` en SOCIAL_APP.html (el boceto pedido
 * "exactamente igual"): cabecera con avatar+nombre real, frase de contexto,
 * acción primaria según el tipo, y un menú universal de acciones (mensaje/
 * social/perfil/bloquear) que antes no existía -- solo había botones
 * sueltos condicionados a que el payload trajera una clave concreta, sin
 * cabecera ni contexto ni forma de mandar mensaje o social directamente
 * desde aquí.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun NotificationActionsSheet(
    entry: NotificationEntry,
    actorProfile: com.social.app.backend.model.Profile?,
    onOpenChat: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
    onOpenDuelResult: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()
    val socialLinks = remember { SocialLinkManager() }
    val follows = remember { com.social.app.chat.FollowManager() }
    val compatRequests = remember { com.social.app.chat.CompatRequestManager() }
    var showReport by remember { mutableStateOf(false) }
    val socialId = entry.payload["social_id"]
    val actorId = entry.payload["actor_id"]
    val compatRequestId = entry.payload["compat_request_id"]
    val duelId = entry.payload["duel_id"]

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(horizontal = 20.dp).padding(bottom = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                com.social.app.avatar.AvatarView(config = actorProfile?.avatarConfig ?: emptyMap(), size = 52.dp)
                Text(actorProfile?.displayName ?: entry.title(), style = MaterialTheme.typography.titleMedium)
            }
            Text(
                contextFor(entry.kind),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 10.dp, bottom = 16.dp)
            )

            if (entry.kind == "follow" && actorId != null) {
                Button(
                    onClick = {
                        scope.launch {
                            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                            follows.follow(myId, actorId)
                            onDismiss()
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Green),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("✓ Seguir de vuelta") }
            }
            // Hallazgo real: estos botones estaban gateados solo por la
            // presencia de la clave en el payload, no por entry.kind --
            // un aviso "social_accepted" (0046_notify_accepted.sql)
            // también trae social_id, así que sin el chequeo de kind
            // mostraría "Aceptar social"/"Rechazar" sobre un social YA
            // aceptado (el UPDATE fallaría en silencio por RLS, ya que
            // solo el destinatario original puede responder -- ver
            // socials_update en 0002_rls.sql), confundiendo a quien lo
            // envió. Mismo criterio que el switch(entry.kind) ya correcto
            // en AvisosView.swift.
            if (entry.kind == "social" && socialId != null) {
                Button(
                    onClick = {
                        scope.launch {
                            socialLinks.respond(socialId, accept = true)
                            com.social.app.backend.AnalyticsManager.track("social_accepted")
                            onDismiss()
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Green),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("✓ Aceptar social") }
                OutlinedButton(
                    onClick = { scope.launch { socialLinks.respond(socialId, accept = false); onDismiss() } },
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("✕ Rechazar") }
            }
            if (entry.kind == "compat_request" && compatRequestId != null) {
                Button(
                    onClick = { scope.launch { compatRequests.respond(compatRequestId, accept = true); onDismiss() } },
                    colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Green),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("✓ Mostrar compatibilidad") }
                OutlinedButton(
                    onClick = { scope.launch { compatRequests.respond(compatRequestId, accept = false); onDismiss() } },
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("✕ Denegar") }
            }
            if (entry.kind == "fight" && duelId != null) {
                Button(
                    onClick = { onOpenDuelResult(duelId); onDismiss() },
                    colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Purple),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("⚔️ Ver duelo") }
            }

            // Menú universal -- hallazgo real comparado con Instagram/
            // WhatsApp: antes no había forma de mandar un mensaje o un
            // social directamente desde un aviso, solo responder al aviso
            // concreto o navegar al perfil. `getOrCreateChat` (nuevo,
            // SocialLinkManager.kt) crea el chat si hace falta, mismo
            // criterio que "mensaje directo" en cualquier app grande.
            if (actorId != null) {
                Button(
                    onClick = {
                        scope.launch {
                            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                            val chatId = socialLinks.getOrCreateChat(myId, actorId)
                            onDismiss()
                            if (chatId != null) onOpenChat(chatId)
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Turquoise),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("💬 Enviar mensaje") }
                if (entry.kind != "social") {
                    OutlinedButton(
                        onClick = {
                            scope.launch {
                                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                                socialLinks.sendSocial(myId, actorId)
                                onDismiss()
                            }
                        },
                        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                    ) { Text("🤝 Enviar social") }
                }
                OutlinedButton(
                    onClick = { onOpenProfile(actorId); onDismiss() },
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                ) { Text("👤 Ver perfil") }
                TextButton(
                    onClick = { showReport = true },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("🚫 Bloquear o denunciar") }
            }
        }
    }

    if (showReport && actorId != null) {
        val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
        if (myId != null) {
            com.social.app.safety.ReportSheet(
                reporterId = myId,
                reportedId = actorId,
                onDismiss = { showReport = false; onDismiss() }
            )
        }
    }
}

@Composable
private fun NotificationRow(entry: NotificationEntry, actorProfile: com.social.app.backend.model.Profile?, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
        // chats/duelos: solo había un emoji genérico por tipo de aviso,
        // nunca el avatar de quién lo disparó -- comparado con la pestaña
        // "Actividad" de Instagram, que siempre muestra la foto de perfil
        // del actor como elemento visual principal.
        com.social.app.avatar.AvatarView(config = actorProfile?.avatarConfig ?: emptyMap(), size = 40.dp)
        Text(entry.icon())
        Column(modifier = Modifier.weight(1f)) {
            Text(entry.title(), style = MaterialTheme.typography.bodyMedium)
            // Hallazgo real: mismo patrón que los posts — `created_at` se
            // decodificaba pero Avisos nunca mostraba cuándo pasó nada.
            Text(
                relativeTime(entry.createdAt),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        if (entry.readAt == null) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(MaterialTheme.colorScheme.primary, CircleShape)
            )
        }
    }
}
