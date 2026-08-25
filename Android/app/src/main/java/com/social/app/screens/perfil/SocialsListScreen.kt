package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Lista de socials aceptados — no existía en ninguna plataforma (ver
 * SocialsListViewModel.kt para el hallazgo completo).
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SocialsListScreen(viewModel: SocialsListViewModel = viewModel(), onOpenProfile: (String) -> Unit) {
    val socials by viewModel.socials.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    // Hallazgo real, mismo criterio ya aplicado en Home/Match/ChatList/
    // Guardados/Tus publicaciones: comparado con Instagram/Twitter/
    // Facebook, esta pantalla no tenía pull-to-refresh.
    val pullState = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            viewModel.load()
            pullState.endRefresh()
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(16.dp)
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        Text("Tus socials", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (socials.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no tienes ningún social.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        androidx.compose.foundation.layout.Box(modifier = Modifier.fillMaxWidth()) {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(socials, key = { it.socialId }) { entry ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.weight(1f).clickable { onOpenProfile(entry.profileId) }
                        ) {
                            // Hallazgo real, mismo hueco raíz ya cerrado en
                            // el feed/comentarios/chats/duelos/avisos:
                            // "Tus socials" tampoco mostraba avatar.
                            com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 40.dp)
                            Text(entry.displayName, modifier = Modifier.padding(start = 10.dp))
                        }
                        // Hallazgo real: no había forma de quitar un social
                        // aceptado — `socials` no tenía ninguna política de
                        // delete hasta esta pasada (0020_socials_delete.sql).
                        TextButton(onClick = { viewModel.removeSocial(entry.socialId) }) {
                            Text("Quitar")
                        }
                    }
                    HorizontalDivider()
                }
            }
            androidx.compose.material3.pulltorefresh.PullToRefreshContainer(
                state = pullState,
                modifier = Modifier.align(Alignment.TopCenter)
            )
        }
    }
}
