package com.social.app.screens.perfil

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp

/**
 * Lista de bloqueados con opción de desbloquear — no existía en ninguna
 * plataforma (ver BlockedUsersViewModel para el hallazgo completo).
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun BlockedUsersScreen() {
    val vm = remember { BlockedUsersViewModel() }
    val blocked by vm.blocked.collectAsState()
    // Fecha real de bloqueo, comparado con Instagram/Twitter-X -- ver
    // BlockedUsersViewModel.blockedAt().
    val blockedAt by vm.blockedAt.collectAsState()
    val isLoading by vm.isLoading.collectAsState()
    val errorMessage by vm.errorMessage.collectAsState()

    LaunchedEffect(Unit) { vm.load() }

    // Hallazgo real, mismo criterio ya aplicado en el resto de listas de
    // Perfil (Guardados/Tus publicaciones/Tus socials, pasada anterior):
    // comparado con Instagram/Twitter/Facebook, esta pantalla no tenía
    // pull-to-refresh.
    val pullState = androidx.compose.material3.pulltorefresh.rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            vm.load()
            pullState.endRefresh()
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth().padding(16.dp)
            .nestedScroll(pullState.nestedScrollConnection)
    ) {
        Text("Usuarios bloqueados", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }

        if (isLoading && blocked.isEmpty()) {
            CircularProgressIndicator(modifier = Modifier.padding(top = 24.dp))
        } else if (blocked.isEmpty()) {
            Text(
                "No has bloqueado a nadie.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 24.dp)
            )
        } else {
            androidx.compose.foundation.layout.Box(modifier = Modifier.fillMaxWidth()) {
                LazyColumn(modifier = Modifier.padding(top = 16.dp)) {
                    items(blocked, key = { it.id }) { profile ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                com.social.app.avatar.AvatarView(config = profile.avatarConfig ?: emptyMap(), size = 40.dp)
                                Column(modifier = Modifier.padding(start = 12.dp)) {
                                    Text(profile.displayName)
                                    blockedAt[profile.id]?.takeIf { it.isNotBlank() }?.let {
                                        Text(
                                            "Bloqueado ${com.social.app.util.relativeTime(it)}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                            OutlinedButton(onClick = { vm.unblock(profile.id) }) {
                                Text("Desbloquear")
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
}
