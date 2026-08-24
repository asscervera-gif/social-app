package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Cabecera + las 15 secciones editables del perfil completo — equivalente
 * Compose de FullProfileView en PerfilView.swift. Antes esta pantalla solo
 * mostraba nombre/bio de forma fija; las secciones no existían en Android
 * en absoluto (a diferencia de iOS, donde ya eran tocables/editables).
 * El "Avatar" y otras subsecciones con pantalla propia (tienda, StoreKit)
 * siguen sin equivalente Android — eso sí requiere Google Play Billing,
 * una dependencia de pago real, fuera de alcance de una corrección rápida.
 */
@Composable
fun PerfilScreen(
    viewModel: PerfilViewModel = viewModel(),
    onOpenAjustes: () -> Unit = {},
    onOpenDuelHistory: () -> Unit = {},
    onOpenChatList: () -> Unit = {},
    onOpenMyPosts: () -> Unit = {},
    onOpenSocials: () -> Unit = {},
    onOpenSavedPosts: () -> Unit = {}
) {
    val profile by viewModel.profile.collectAsState()
    val sections by viewModel.sections.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val postCount by viewModel.postCount.collectAsState()
    val socialCount by viewModel.socialCount.collectAsState()
    var editingKey by remember { mutableStateOf<String?>(null) }
    var showEditProfile by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { viewModel.load() }

    LazyColumn(modifier = Modifier.fillMaxWidth()) {
        item {
            Column(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                com.social.app.avatar.AvatarView(config = profile?.avatarConfig ?: emptyMap(), size = 96.dp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(profile?.displayName ?: "Tu nombre", style = MaterialTheme.typography.titleLarge)
                    // Hallazgo real: `is_verified` se consultaba en varias
                    // pantallas pero nunca se renderizaba como badge en
                    // ningún sitio de la app — dato muerto.
                    if (profile?.isVerified == true) {
                        Text(" ✔️", color = MaterialTheme.colorScheme.primary)
                    }
                }
                Text(
                    "$postCount publicaciones · $followersCount seguidores · $followingCount siguiendo · $socialCount socials",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                profile?.bio?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                // Hallazgo real: no había forma de editar nombre/bio/color
                // de avatar en ningún sitio, comparado con cualquier app
                // grande — solo las 15 secciones eran editables.
                androidx.compose.material3.OutlinedButton(
                    onClick = { showEditProfile = true },
                    modifier = Modifier.padding(top = 8.dp)
                ) { Text("Editar perfil") }
                // Hallazgo real: este Row sin scroll horizontal empujaba
                // "Ajustes" (el último botón) fuera de la pantalla en
                // cuanto había 6 accesos — literalmente imposible de tocar,
                // no solo un problema visual, encontrado al intentar
                // navegar a Ajustes durante una prueba en el emulador.
                Row(modifier = Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState())) {
                    androidx.compose.material3.TextButton(onClick = onOpenDuelHistory) { Text("⚡ Tus duelos") }
                    // Hallazgo real: no había ningún punto de entrada a la
                    // lista de chats en ninguna plataforma (ver
                    // ChatListViewModel.kt para el detalle completo).
                    androidx.compose.material3.TextButton(onClick = onOpenChatList) { Text("💬 Tus chats") }
                    // Hallazgo real: Android nunca tuvo la rejilla de 6
                    // subsecciones de iOS ("Tus publicaciones" incluida) —
                    // con el compositor ya real, esta entrada deja de
                    // depender de Storage (ver MyPostsScreen.kt).
                    androidx.compose.material3.TextButton(onClick = onOpenMyPosts) { Text("🖼 Tus publicaciones") }
                    // Hallazgo real: "socials" (vínculo mutuo, el concepto
                    // de relación central de la app) no tenía ninguna
                    // pantalla de lista en ninguna plataforma, solo el
                    // número (ver SocialsListViewModel.kt).
                    androidx.compose.material3.TextButton(onClick = onOpenSocials) { Text("👥 Tus socials") }
                    // Hallazgo real: guardar un post (icono de marcador en
                    // PostCard, HomeViewModel.toggleSave) llevaba varias
                    // pasadas guardando de verdad en `saved_posts`, pero no
                    // había ninguna pantalla para ver lo guardado —
                    // comparado con la colección "Guardado" de Instagram.
                    androidx.compose.material3.TextButton(onClick = onOpenSavedPosts) { Text("🔖 Guardados") }
                    androidx.compose.material3.TextButton(onClick = onOpenAjustes) { Text("Ajustes") }
                }
            }
        }
        items(PerfilViewModel.SECTION_KEYS) { key ->
            val existing = sections.firstOrNull { it.sectionKey == key }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { editingKey = key }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(key.replace('_', ' ').replaceFirstChar { it.uppercase() })
                Text(
                    existing?.content?.get("texto")?.takeIf { it.isNotBlank() } ?: "Añadir",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
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
        EditProfileSheet(
            initialName = profile?.displayName ?: "",
            initialBio = profile?.bio ?: "",
            initialColor = profile?.avatarConfig?.get("colorSeed") ?: "8B5CF6",
            onDismiss = { showEditProfile = false },
            onSave = { name, bio, color -> viewModel.updateBasicInfo(name, bio, color) }
        )
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
