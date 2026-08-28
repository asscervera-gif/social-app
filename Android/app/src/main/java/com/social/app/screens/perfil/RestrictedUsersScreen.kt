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
import androidx.compose.ui.unit.dp

/**
 * Lista de cuentas restringidas con opción de deshacerlo -- equivalente
 * exacto de BlockedUsersScreen.kt, pero sobre `restricts`
 * (0093_restrict_account.sql). Restringir es deliberadamente más suave
 * que bloquear (sus comentarios solo se ocultan a los demás, nunca se
 * entera de nada) -- comparado con Instagram.
 */
@Composable
fun RestrictedUsersScreen() {
    val vm = remember { RestrictedUsersViewModel() }
    val restricted by vm.restricted.collectAsState()
    // Fecha real de restricción, comparado con Instagram -- ver
    // RestrictedUsersViewModel.restrictedAt().
    val restrictedAt by vm.restrictedAt.collectAsState()
    val isLoading by vm.isLoading.collectAsState()
    val errorMessage by vm.errorMessage.collectAsState()

    LaunchedEffect(Unit) { vm.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Cuentas restringidas", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }

        if (isLoading && restricted.isEmpty()) {
            CircularProgressIndicator(modifier = Modifier.padding(top = 24.dp))
        } else if (restricted.isEmpty()) {
            Text(
                "No has restringido a nadie.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 24.dp)
            )
        } else {
            LazyColumn(modifier = Modifier.padding(top = 16.dp)) {
                items(restricted, key = { it.id }) { profile ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            com.social.app.avatar.AvatarView(config = profile.avatarConfig ?: emptyMap(), size = 40.dp)
                            Column(modifier = Modifier.padding(start = 12.dp)) {
                                Text(profile.displayName)
                                restrictedAt[profile.id]?.takeIf { it.isNotBlank() }?.let {
                                    Text(
                                        "Restringido ${com.social.app.util.relativeTime(it)}",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                        OutlinedButton(onClick = { vm.unrestrict(profile.id) }) {
                            Text("Dejar de restringir")
                        }
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}
