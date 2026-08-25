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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
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
                }
            })
        }
    }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }

    selected?.let { entry ->
        NotificationActionsSheet(
            entry = entry,
            onOpenProfile = onOpenProfile,
            onOpenDuelResult = onOpenDuelResult,
            onDismiss = { selected = null }
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun NotificationActionsSheet(
    entry: NotificationEntry,
    onOpenProfile: (String) -> Unit,
    onOpenDuelResult: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()
    val socialLinks = remember { SocialLinkManager() }
    val follows = remember { com.social.app.chat.FollowManager() }
    val compatRequests = remember { com.social.app.chat.CompatRequestManager() }
    val socialId = entry.payload["social_id"]
    val actorId = entry.payload["actor_id"]
    val compatRequestId = entry.payload["compat_request_id"]
    val duelId = entry.payload["duel_id"]

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(24.dp)) {
            Text(entry.title(), style = MaterialTheme.typography.titleMedium)
            if (entry.kind == "follow" && actorId != null) {
                Button(
                    onClick = {
                        scope.launch {
                            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                            follows.follow(myId, actorId)
                            onDismiss()
                        }
                    },
                    modifier = Modifier.padding(top = 16.dp)
                ) { Text("Seguir de vuelta") }
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
                    modifier = Modifier.padding(top = 16.dp)
                ) { Text("Aceptar social") }
                OutlinedButton(
                    onClick = { scope.launch { socialLinks.respond(socialId, accept = false); onDismiss() } },
                    modifier = Modifier.padding(top = 8.dp)
                ) { Text("Rechazar") }
            }
            if (entry.kind == "compat_request" && compatRequestId != null) {
                Button(
                    onClick = { scope.launch { compatRequests.respond(compatRequestId, accept = true); onDismiss() } },
                    modifier = Modifier.padding(top = 16.dp)
                ) { Text("Compartir compatibilidad") }
                OutlinedButton(
                    onClick = { scope.launch { compatRequests.respond(compatRequestId, accept = false); onDismiss() } },
                    modifier = Modifier.padding(top = 8.dp)
                ) { Text("Rechazar") }
            }
            if (entry.kind == "fight" && duelId != null) {
                Button(
                    onClick = { onOpenDuelResult(duelId); onDismiss() },
                    modifier = Modifier.padding(top = 16.dp)
                ) { Text("Ver duelo") }
            }
            // Antes "Ver perfil" no existía en absoluto en Android (ni
            // siquiera como botón vacío, a diferencia de iOS).
            if (actorId != null) {
                OutlinedButton(
                    onClick = { onOpenProfile(actorId); onDismiss() },
                    modifier = Modifier.padding(top = 8.dp)
                ) { Text("Ver perfil") }
            }
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
