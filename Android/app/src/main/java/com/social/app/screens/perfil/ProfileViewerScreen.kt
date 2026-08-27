package com.social.app.screens.perfil

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
import com.social.app.chat.FollowManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.launch

/**
 * Visor de perfil de solo lectura para OTRA persona — equivalente Compose
 * de ProfileViewerView.swift. Antes "Ver perfil" no existía en absoluto en
 * Android (ni siquiera como botón vacío, a diferencia de iOS).
 */
@Composable
fun ProfileViewerScreen(profileId: String) {
    val context = LocalContext.current
    var profile by remember { mutableStateOf<Profile?>(null) }
    var sections by remember { mutableStateOf<List<ProfileSection>>(emptyList()) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var myId by remember { mutableStateOf<String?>(null) }
    var isFollowing by remember { mutableStateOf(false) }
    var followBusy by remember { mutableStateOf(false) }
    val followManager = remember { FollowManager() }
    // Activar avisos de publicaciones de esta cuenta real ("🔔"),
    // comparado con Instagram/Twitter/X -- solo tiene sentido real una
    // vez que ya la sigues (mismo criterio real que esas apps: la
    // campana solo aparece tras seguir). Ver
    // com.social.app.chat.PostNotificationManager, 0098_post_notifications.sql.
    var isSubscribedToPosts by remember { mutableStateOf(false) }
    var subscriptionBusy by remember { mutableStateOf(false) }
    val postNotificationManager = remember { com.social.app.chat.PostNotificationManager() }
    val scope = rememberCoroutineScope()
    // Hallazgo real, comparado con Instagram/Twitter/TikTok: el visor de
    // OTRA persona solo tenía "Seguir" -- ningún "Bloquear" ni "Denunciar"
    // directo, pese a que ReportSheet ya incluye ambas acciones reales.
    // El overlay global (SafetyToolbar) tiene un bug ya documentado (sin
    // target real en contexto, denuncia por defecto al PROPIO usuario) --
    // aquí sí hay un target real, el sitio correcto para esta acción.
    var showReportSheet by remember { mutableStateOf(false) }

    LaunchedEffect(profileId) {
        try {
            // Optimización: este visor solo muestra nombre, bio, avatar y
            // verificación, no hace falta traer interests/compat_public/etc.
            // avatar_config faltaba aquí (hallazgo real: Android nunca
            // renderizaba ningún avatar en ningún sitio, ver AvatarView.kt).
            // is_verified se consultaba en varias pantallas pero nunca se
            // renderizaba como badge en ningún sitio — dato muerto, mismo
            // patrón que otros hallazgos de esta sesión.
            profile = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name,bio,avatar_config,is_verified,username,website_url")) { filter { eq("id", profileId) } }
                .decodeSingle()
            sections = SupabaseManager.client.from("profile_sections")
                .select { filter { eq("profile_id", profileId) } }
                .decodeList()
        } catch (e: Exception) {
            errorMessage = "No se pudo cargar el perfil."
        }

        // Hallazgo real: no había ningún botón "Seguir" directo en este
        // visor, solo "seguir de vuelta" desde una notificación — ver
        // FollowManager.kt para el detalle completo.
        myId = SupabaseManager.client.auth.currentUserOrNull()?.id
        myId?.let { uid ->
            if (uid != profileId) {
                isFollowing = followManager.isFollowing(uid, profileId)
                isSubscribedToPosts = postNotificationManager.isSubscribed(uid, profileId)
            }
        }
    }

    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        item {
            com.social.app.avatar.AvatarView(config = profile?.avatarConfig ?: emptyMap(), size = 80.dp)
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(profile?.displayName ?: "Perfil", style = MaterialTheme.typography.titleLarge)
                if (profile?.isVerified == true) {
                    Text(" ✔️", color = MaterialTheme.colorScheme.primary)
                }
            }
            // Nombre de usuario único real (@handle,
            // 0073_profile_username.sql), comparado con Instagram/
            // Twitter/TikTok -- distinto del nombre para mostrar, que sí
            // puede repetirse y cambiar libremente.
            profile?.username?.let {
                Text(
                    "@$it",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            profile?.bio?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            // Enlace externo real en el perfil ("link in bio",
            // 0077_profile_website.sql), comparado con Instagram/TikTok/
            // Twitter.
            profile?.websiteUrl?.let { url ->
                Text(
                    url.removePrefix("https://").removePrefix("http://"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.clickable {
                        try {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        } catch (e: Exception) {
                            // URL malformada o sin app que la maneje -- no crítico.
                        }
                    }
                )
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }

            // Destacados reales de historias en el perfil, comparado con
            // Instagram -- misma fila que en el propio perfil
            // (PerfilScreen.kt), ver StoryHighlightsRow.kt/
            // 0101_story_highlights.sql.
            StoryHighlightsRow(profileId = profileId)

            if (myId != null && myId != profileId) {
                Row(modifier = Modifier.padding(top = 12.dp)) {
                    val onToggle = {
                        val uid = myId!!
                        followBusy = true
                        scope.launch {
                            if (isFollowing) followManager.unfollow(uid, profileId)
                            else followManager.follow(uid, profileId)
                            isFollowing = !isFollowing
                            followBusy = false
                        }
                        Unit
                    }
                    if (isFollowing) {
                        OutlinedButton(onClick = onToggle, enabled = !followBusy) { Text("Siguiendo") }
                    } else {
                        Button(onClick = onToggle, enabled = !followBusy) { Text("Seguir") }
                    }
                    // Activar avisos de publicaciones de esta cuenta real
                    // ("🔔"), comparado con Instagram/Twitter/X -- solo
                    // aparece una vez que ya la sigues.
                    if (isFollowing) {
                        OutlinedButton(
                            onClick = {
                                val uid = myId!!
                                subscriptionBusy = true
                                scope.launch {
                                    if (isSubscribedToPosts) postNotificationManager.unsubscribe(uid, profileId)
                                    else postNotificationManager.subscribe(uid, profileId)
                                    isSubscribedToPosts = !isSubscribedToPosts
                                    subscriptionBusy = false
                                }
                            },
                            enabled = !subscriptionBusy,
                            modifier = Modifier.padding(start = 8.dp)
                        ) { Text(if (isSubscribedToPosts) "🔔" else "🔕") }
                    }
                    OutlinedButton(
                        onClick = { showReportSheet = true },
                        colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(
                            contentColor = MaterialTheme.colorScheme.error
                        ),
                        modifier = Modifier.padding(start = 8.dp)
                    ) { Text("⚠") }
                }
            }
        }
        // Solo secciones públicas — este es el visor de OTRA persona, no el propio editor.
        items(sections.filter { it.isPublic }) { section ->
            val text = section.content["texto"]
            if (!text.isNullOrEmpty()) {
                Column(modifier = Modifier.padding(top = 12.dp)) {
                    Text(
                        section.sectionKey.replace('_', ' ').replaceFirstChar { it.uppercase() },
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(text)
                }
            }
        }
    }
    if (showReportSheet && myId != null) {
        com.social.app.safety.ReportSheet(
            reporterId = myId!!,
            reportedId = profileId,
            onDismiss = { showReportSheet = false }
        )
    }
}
