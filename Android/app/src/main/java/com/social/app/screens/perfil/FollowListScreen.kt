package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
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
import com.social.app.ui.theme.SocialColors

enum class FollowTab { FOLLOWING, FOLLOWERS }

/**
 * "Siguiendo"/"Seguidores" con búsqueda -- hueco real descrito en
 * FollowListViewModel.kt. Estructura EXACTA de `openFollow()` en el boceto
 * SOCIAL_APP.html: pestañas con contador + buscador + lista con botón de
 * seguir/dejar de seguir por fila. "Socials" no se duplica aquí -- sigue
 * siendo su propio destino real (SocialsListScreen, "Tus socials" en la
 * rejilla de accesos), evitando reescribir una pantalla ya construida y en
 * producción solo para encajarla en una tercera pestaña.
 */
@Composable
fun FollowListScreen(
    initialTab: FollowTab,
    viewModel: FollowListViewModel = viewModel(),
    onOpenProfile: (String) -> Unit
) {
    var tab by remember { mutableStateOf(initialTab) }
    var query by remember { mutableStateOf("") }
    val following by viewModel.following.collectAsState()
    val followers by viewModel.followers.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    LaunchedEffect(Unit) { viewModel.load() }

    val list = if (tab == FollowTab.FOLLOWING) following else followers
    val filtered = if (query.isBlank()) list else list.filter { it.displayName.contains(query, ignoreCase = true) }

    Column(modifier = Modifier.fillMaxWidth()) {
        TabRow(selectedTabIndex = tab.ordinal) {
            Tab(
                selected = tab == FollowTab.FOLLOWING,
                onClick = { tab = FollowTab.FOLLOWING },
                text = { Text("Siguiendo ${following.size}") }
            )
            Tab(
                selected = tab == FollowTab.FOLLOWERS,
                onClick = { tab = FollowTab.FOLLOWERS },
                text = { Text("Seguidores ${followers.size}") }
            )
        }
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("🔍 Buscar") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(12.dp)
        )
        errorMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp))
        }
        if (filtered.isEmpty() && errorMessage == null) {
            Text(
                if (tab == FollowTab.FOLLOWING) "No sigues a nadie todavía." else "Todavía no tienes seguidores.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth()) {
            items(filtered, key = { it.profileId }) { entry ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.weight(1f).clickable { onOpenProfile(entry.profileId) }
                    ) {
                        com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 44.dp)
                        Text(entry.displayName, modifier = Modifier.padding(start = 10.dp))
                    }
                    if (entry.isFollowing) {
                        OutlinedButton(onClick = { viewModel.toggleFollow(entry) }) { Text("Siguiendo") }
                    } else {
                        Button(
                            onClick = { viewModel.toggleFollow(entry) },
                            colors = ButtonDefaults.buttonColors(containerColor = SocialColors.Turquoise)
                        ) { Text("Seguir") }
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
