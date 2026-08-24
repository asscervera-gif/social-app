package com.social.app.screens.perfil

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
    var profile by remember { mutableStateOf<Profile?>(null) }
    var sections by remember { mutableStateOf<List<ProfileSection>>(emptyList()) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var myId by remember { mutableStateOf<String?>(null) }
    var isFollowing by remember { mutableStateOf(false) }
    var followBusy by remember { mutableStateOf(false) }
    val followManager = remember { FollowManager() }
    val scope = rememberCoroutineScope()

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
                .select(columns = Columns.raw("id,display_name,bio,avatar_config,is_verified")) { filter { eq("id", profileId) } }
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
            if (uid != profileId) isFollowing = followManager.isFollowing(uid, profileId)
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
            profile?.bio?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }

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
}
