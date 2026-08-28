package com.social.app.screens.perfil

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.draw.clip
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.ui.theme.SocialColors

/**
 * Cabecera + las 15 secciones editables del perfil completo -- equivalente
 * Compose de FullProfileView en PerfilView.swift.
 *
 * Hallazgo real, reportado directamente por el usuario probando la app de
 * verdad ("el perfil se ve super feo, nada organizado, no está en
 * recuadros grandes"): esta pantalla era una lista plana de
 * `TextButton`/`Text` sin ninguna organización visual real, muy alejada
 * del boceto de producto (`perfil_boceto.html`, en la raíz del
 * repositorio) -- cabecera con contadores en tarjetas, rejilla 3x2 de
 * accesos reales, y las 15 secciones como tarjetas con icono + etiqueta de
 * visibilidad, no texto suelto. Reconstruida siguiendo ese boceto al pie
 * de la letra en la ESTRUCTURA VISUAL, pero sin inventar datos que no
 * existen de verdad: el boceto usa 15 categorías de ejemplo distintas
 * ("Identidad y datos básicos", "Familia y origen"...) que NO son las 15
 * claves reales ya construidas en `PerfilViewModel.SECTION_KEYS` (con su
 * propio esquema RLS/iOS ya en producción) -- se mantienen las claves
 * reales, solo se les da la misma vestimenta visual (tarjeta + icono +
 * etiqueta pública/privada) que pide el boceto. Tampoco existen "Reels" ni
 * "En directo" en esta app (fuera del alcance de producto, ver
 * growth_strategy.md) -- la rejilla usa los 6 accesos reales que ya
 * existían como botones sueltos (Avatar/editar, Duelos, Publicaciones,
 * Socials, Guardados, Chats), no relleno inventado.
 */
private val SECTION_ICONS = mapOf(
    "sobre_mi" to "🪪", "trabajo" to "💼", "estudios" to "🎓", "musica" to "🎵",
    "cine" to "🎬", "deportes" to "⚽", "viajes" to "✈️", "comida" to "🍽️",
    "mascotas" to "🐾", "idiomas" to "🗣️", "signo" to "♈", "altura" to "📏",
    "busco" to "🎯", "redes" to "🔗", "curiosidad" to "💭"
)

private data class ProfileNavItem(val icon: String, val label: String, val onClick: () -> Unit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PerfilScreen(
    viewModel: PerfilViewModel = viewModel(),
    onOpenAjustes: () -> Unit = {},
    onOpenDuelHistory: () -> Unit = {},
    onOpenChatList: () -> Unit = {},
    onOpenMyPosts: () -> Unit = {},
    onOpenSocials: () -> Unit = {},
    onOpenSavedPosts: () -> Unit = {},
    onOpenFollowing: () -> Unit = {},
    onOpenFollowers: () -> Unit = {},
    onOpenReels: () -> Unit = {},
    onOpenLive: () -> Unit = {},
    onOpenGroupChats: () -> Unit = {},
    onOpenStarredMessages: () -> Unit = {},
    onOpenBroadcastLists: () -> Unit = {},
    // "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
    // (Premium) -- ver ProfileVisitsScreen.kt, 0132_profile_visits.sql.
    onOpenProfileVisits: () -> Unit = {}
) {
    val context = LocalContext.current
    val profile by viewModel.profile.collectAsState()
    val sections by viewModel.sections.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val postCount by viewModel.postCount.collectAsState()
    val socialCount by viewModel.socialCount.collectAsState()
    val latestPostMediaUrl by viewModel.latestPostMediaUrl.collectAsState()
    var editingKey by remember { mutableStateOf<String?>(null) }
    var showEditProfile by remember { mutableStateOf(false) }
    var showNewPost by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { viewModel.load() }

    val navItems = listOf(
        ProfileNavItem("🦊", "Avatar") { showEditProfile = true },
        // Reels (0050_reels.sql) -- primera vez que hay un acceso real,
        // antes ni siquiera existía la UI de cliente. 7º hueco de la
        // rejilla 3x2 original: se añade, no se quita ninguno de los 6 ya
        // reales (Guardados/Tus chats siguen sin otro punto de entrada en
        // la app, quitarlos habría sido una regresión real).
        ProfileNavItem("🎬", "Reels", onOpenReels),
        // "Directo" (0056_live_streams.sql) -- último hueco grande de
        // SOCIAL_APP.html, comparado con Instagram/TikTok Live. 8º hueco
        // de la rejilla, mismo criterio que Reels: se añade sin quitar
        // ninguno de los 7 ya reales.
        ProfileNavItem("🔴", "Directos", onOpenLive),
        ProfileNavItem("⚔️", "Duelos", onOpenDuelHistory),
        ProfileNavItem("🖼", "Tus publicaciones", onOpenMyPosts),
        ProfileNavItem("👥", "Tus socials", onOpenSocials),
        ProfileNavItem("🔖", "Guardados", onOpenSavedPosts),
        ProfileNavItem("💬", "Tus chats", onOpenChatList),
        // Chats de grupo (0057_group_chats.sql) -- comparado con WhatsApp/
        // Instagram/Messenger/Facebook, mismo criterio que Reels/Directos:
        // se añade sin quitar ninguno de los ya reales.
        ProfileNavItem("👥", "Grupos", onOpenGroupChats),
        // Mensajes destacados reales, comparado con WhatsApp
        // (0087_starred_messages.sql) -- mismo criterio que Reels/
        // Directos/Grupos: se añade sin quitar ninguno de los ya reales.
        ProfileNavItem("⭐", "Destacados", onOpenStarredMessages),
        // Listas de difusión reales, comparado con WhatsApp
        // (0103_broadcast_lists.sql) -- mismo criterio que el resto:
        // se añade sin quitar ninguno de los ya reales.
        ProfileNavItem("📢", "Difusión", onOpenBroadcastLists),
        // "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
        // (Premium) -- 0132_profile_visits.sql, mismo criterio que el
        // resto: se añade sin quitar ninguno de los ya reales.
        ProfileNavItem("👣", "Visitas", onOpenProfileVisits)
    )
    val filledSections = sections.count { it.content["texto"]?.isNotBlank() == true }
    val completion = (filledSections * 100) / PerfilViewModel.SECTION_KEYS.size.coerceAtLeast(1)

    LazyColumn(modifier = Modifier.fillMaxWidth()) {
        item {
            // Barra superior real -- antes el nombre y el acceso a
            // Ajustes vivían mezclados dentro del bloque centrado de más
            // abajo, sin ninguna jerarquía visual clara.
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(profile?.displayName ?: "Tu perfil", style = MaterialTheme.typography.titleMedium)
                        if (profile?.isVerified == true) {
                            Text(" ✔️", color = SocialColors.Turquoise)
                        }
                    }
                    // Nombre de usuario único real (@handle,
                    // 0073_profile_username.sql), comparado con
                    // Instagram/Twitter/TikTok -- distinto del nombre para
                    // mostrar, que sí puede repetirse y cambiar libremente.
                    profile?.username?.let {
                        Text(
                            "@$it",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                // Compartir perfil, comparado con Instagram/Twitter/
                // TikTok -- hueco real, básico y universal, ausente
                // hasta ahora. Aviso de honestidad: sin enlace real
                // (ningún esquema de deep link registrado todavía en
                // AndroidManifest.xml) -- comparte el @usuario real
                // como texto, para buscarlo dentro de la app, no un
                // enlace que abriría nada al tocarlo.
                profile?.username?.let { username ->
                    IconButton(onClick = {
                        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(android.content.Intent.EXTRA_TEXT, "Añádeme en SOCIAL: @$username")
                        }
                        context.startActivity(android.content.Intent.createChooser(intent, "Compartir perfil"))
                    }) {
                        Text("📤")
                    }
                }
                IconButton(onClick = onOpenAjustes) {
                    Icon(Icons.Filled.Settings, contentDescription = "Ajustes")
                }
            }

            // Cabecera: avatar + publicar + contadores en tarjetas --
            // antes un solo renglón de texto plano ("128 publicaciones ·
            // 312 seguidores..."), sin ninguna jerarquía visual, muy lejos
            // del boceto real (perfil_boceto.html).
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.Top
            ) {
                RotatingProfileHeaderImage(
                    avatarConfig = profile?.avatarConfig ?: emptyMap(),
                    photoUrl = latestPostMediaUrl,
                    size = 76.dp
                )
                Column(modifier = Modifier.padding(start = 14.dp).weight(1f)) {
                    Button(
                        onClick = { showNewPost = true },
                        modifier = Modifier.fillMaxWidth(),
                        // Hallazgo real, parte del hueco de modo oscuro:
                        // `SocialColors.Ink` es un literal FIJO -- en modo
                        // oscuro (fondo ya oscuro) un botón "Ink" casi
                        // negro se volvía casi invisible. `onBackground`/
                        // `background` ya se invierten solos entre claro y
                        // oscuro (ver SocialTheme.kt), así que este botón
                        // se adapta sin lógica propia.
                        colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.onBackground,
                            contentColor = MaterialTheme.colorScheme.background
                        )
                    ) { Text("＋ Publicar") }
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        // Hallazgo real, comparado con Instagram/Twitter/
                        // TikTok: estos contadores ya eran reales, pero
                        // tocarlos no hacía nada -- ahora abren la lista de
                        // verdad (FollowListScreen/SocialsListScreen), no
                        // solo el número suelto.
                        ProfileCounter(postCount.toString(), "Pubs", Modifier.weight(1f))
                        ProfileCounter(followingCount.toString(), "Sigo", Modifier.weight(1f).clickable(onClick = onOpenFollowing))
                        ProfileCounter(followersCount.toString(), "Seguid.", Modifier.weight(1f).clickable(onClick = onOpenFollowers))
                        ProfileCounter(socialCount.toString(), "Socials", Modifier.weight(1f).clickable(onClick = onOpenSocials))
                    }
                }
            }
            profile?.bio?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            }
            // Enlace externo real en el perfil ("link in bio",
            // 0077_profile_website.sql), comparado con Instagram/TikTok/
            // Twitter.
            profile?.websiteUrl?.let { url ->
                Text(
                    url.removePrefix("https://").removePrefix("http://"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .padding(horizontal = 16.dp)
                        .clickable {
                            try {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            } catch (e: Exception) {
                                // URL malformada o sin app que la maneje -- no crítico.
                            }
                        }
                )
            }
            errorMessage?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp))
            }

            // Destacados reales de historias en el perfil, comparado con
            // Instagram -- fila de círculos justo debajo de la bio, ver
            // StoryHighlightsRow.kt/0101_story_highlights.sql.
            profile?.let { StoryHighlightsRow(profileId = it.id) }

            // Tarjeta "tu perfil completo" con el % real (secciones con
            // texto de verdad / 15) -- mismo hallazgo del boceto, pero con
            // un número calculado de los datos reales, no inventado.
            Card(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("📋 Tu perfil completo", style = MaterialTheme.typography.bodyMedium)
                    Text("$completion% ›", color = SocialColors.Green, style = MaterialTheme.typography.bodyMedium)
                }
            }

            // Rejilla 3x2 de accesos reales -- antes un Row con scroll
            // horizontal de TextButton sueltos que, con 6 accesos, dejaba
            // "Ajustes" literalmente imposible de tocar sin descubrir que
            // había que deslizar (hallazgo real ya corregido esa vez, pero
            // seguía sin parecerse en nada al boceto). `LazyVerticalGrid`
            // no puede anidarse dentro de un `LazyColumn` sin una altura
            // fija -- rejilla manual con `Row`, más simple y sin ese límite.
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                navItems.chunked(3).forEach { rowItems ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        rowItems.forEach { navItem ->
                            ProfileNavCell(navItem, Modifier.weight(1f))
                        }
                        repeat(3 - rowItems.size) { Box(modifier = Modifier.weight(1f)) }
                    }
                }
            }
            Text(
                "Tu perfil completo",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }
        items(PerfilViewModel.SECTION_KEYS) { key ->
            val existing = sections.firstOrNull { it.sectionKey == key }
            val value = existing?.content?.get("texto")?.takeIf { it.isNotBlank() }
            Card(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clickable { editingKey = key },
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(SECTION_ICONS[key] ?: "•", modifier = Modifier.padding(end = 8.dp))
                            Text(
                                key.replace('_', ' ').replaceFirstChar { it.uppercase() },
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold
                            )
                        }
                        // Etiqueta de visibilidad real -- boceto pedía
                        // "🌐 público"/"🔒 privado" en vez de texto suelto.
                        val isPublic = existing?.isPublic ?: true
                        Text(
                            if (isPublic) "🌐 público" else "🔒 privado",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (isPublic) SocialColors.Turquoise else SocialColors.Magenta
                        )
                    }
                    Text(
                        value ?: "＋ Añadir dato",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (value != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }
        }
        item { Box(modifier = Modifier.padding(bottom = 24.dp)) }
    }

    editingKey?.let { key ->
        SectionEditSheet(
            existing = sections.firstOrNull { it.sectionKey == key },
            onSave = { text, isPublic ->
                viewModel.saveSection(key, text, isPublic)
                editingKey = null
            },
            onDismiss = { editingKey = null }
        )
    }

    if (showEditProfile) {
        val usernameErrorMessage by viewModel.usernameErrorMessage.collectAsState()
        EditProfileSheet(
            initialName = profile?.displayName ?: "",
            initialBio = profile?.bio ?: "",
            initialSkin = profile?.avatarConfig?.get("skin") ?: com.social.app.avatar.AvatarLook.SKIN_TONES.first(),
            initialHair = profile?.avatarConfig?.get("hair") ?: com.social.app.avatar.AvatarLook.HAIR_TONES.first(),
            initialTop = profile?.avatarConfig?.get("top") ?: com.social.app.avatar.AvatarLook.TOP_COLORS.first(),
            initialUsername = profile?.username ?: "",
            usernameErrorMessage = usernameErrorMessage,
            initialWebsiteUrl = profile?.websiteUrl ?: "",
            onDismiss = { showEditProfile = false },
            onSave = { name, bio, skin, hair, top, websiteUrl -> viewModel.updateBasicInfo(name, bio, skin, hair, top, websiteUrl) },
            onSaveUsername = { username -> viewModel.updateUsername(username) }
        )
    }

    if (showNewPost) {
        com.social.app.screens.home.NewPostSheet(
            onDismiss = { showNewPost = false },
            onPosted = { viewModel.load() }
        )
    }
}

/**
 * Hallazgo real, comparado con SOCIAL_APP.html: la cabecera del perfil
 * alterna cada 3.5s entre el avatar y una foto real (`setInterval(flip,3500)`
 * en el boceto) -- antes solo se mostraba el avatar fijo, sin rotación
 * alguna. Sin una tabla de "foto de perfil" propia todavía, la fuente
 * honesta más cercana es la última publicación real con foto
 * (`PerfilViewModel.latestPostMediaUrl`) -- si no hay ninguna, se queda
 * solo con el avatar, sin fingir una rotación vacía.
 */
@Composable
private fun RotatingProfileHeaderImage(avatarConfig: Map<String, String>, photoUrl: String?, size: androidx.compose.ui.unit.Dp) {
    if (photoUrl == null) {
        com.social.app.avatar.AvatarView(config = avatarConfig, size = size)
        return
    }
    var showAvatar by remember { mutableStateOf(true) }
    LaunchedEffect(photoUrl) {
        while (true) {
            kotlinx.coroutines.delay(3500)
            showAvatar = !showAvatar
        }
    }
    Box(modifier = Modifier.size(size), contentAlignment = Alignment.BottomEnd) {
        androidx.compose.animation.Crossfade(targetState = showAvatar, label = "avatar_photo_rotation") { isAvatar ->
            if (isAvatar) {
                com.social.app.avatar.AvatarView(config = avatarConfig, size = size)
            } else {
                androidx.compose.foundation.Image(
                    painter = coil.compose.rememberAsyncImagePainter(photoUrl),
                    contentDescription = null,
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                    modifier = Modifier.size(size).clip(androidx.compose.foundation.shape.CircleShape)
                )
            }
        }
        Text(
            if (showAvatar) "avatar" else "foto",
            style = MaterialTheme.typography.labelSmall.copy(fontSize = 8.sp),
            color = Color.White,
            modifier = Modifier
                .padding(2.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(Color.Black.copy(alpha = 0.5f))
                .padding(horizontal = 4.dp, vertical = 1.dp)
        )
    }
}

@Composable
private fun ProfileCounter(value: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(9.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(value, style = MaterialTheme.typography.labelLarge)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ProfileNavCell(item: ProfileNavItem, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier.aspectRatio(1.1f).clickable(onClick = item.onClick),
        border = BorderStroke(1.5.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(item.icon, style = MaterialTheme.typography.titleLarge)
            Text(
                item.label,
                style = MaterialTheme.typography.labelSmall,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                maxLines = 2
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SectionEditSheet(existing: ProfileSection?, onSave: (String, Boolean) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(existing?.content?.get("texto") ?: "") }
    var isPublic by remember { mutableStateOf(existing?.isPublic ?: true) }
    val sheetState = rememberModalBottomSheetState()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth()
            )
            // Hallazgo real, mismo criterio ya aplicado a caption/nombre/
            // bio/detalles de denuncia: el límite de 2000 caracteres es
            // real (profile_sections_texto_length,
            // 0024_more_text_length_limits.sql) y ya se valida antes de
            // guardar (PerfilViewModel.kt.saveSection), pero nada avisaba
            // mientras se escribe.
            Text(
                "${text.length}/2000",
                style = MaterialTheme.typography.labelSmall,
                color = if (text.length > 2000) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(checked = isPublic, onCheckedChange = { isPublic = it })
                Text("Visible públicamente")
            }
            Button(
                onClick = { onSave(text, isPublic) },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            ) {
                Text("Guardar")
            }
        }
    }
}
