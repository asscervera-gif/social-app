package com.social.app.screens.perfil

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * "Mejores amigos" real para historias (0075_close_friends_stories.sql),
 * comparado con Instagram (Close Friends) y Snapchat -- ver
 * CloseFriendsViewModel.kt para el hallazgo completo. Mismo patrón visual
 * que SocialsListScreen.kt, con un `Switch` en vez de un botón "Quitar"
 * porque aquí la acción es un estado binario (está o no en la lista), no
 * una eliminación destructiva de una relación.
 */
@Composable
fun CloseFriendsScreen(viewModel: CloseFriendsViewModel = viewModel()) {
    val candidates by viewModel.candidates.collectAsState()
    val closeFriendIds by viewModel.closeFriendIds.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Mejores amigos", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Las historias marcadas como \"Mejores amigos\" solo las ve la gente que actives aquí.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp)
        )
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (candidates.isEmpty() && errorMessage == null) {
            Text(
                "Necesitas al menos un social aceptado para añadirlo a mejores amigos.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 16.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(candidates, key = { it.profileId }) { entry ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                        com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 40.dp)
                        Text(entry.displayName, modifier = Modifier.padding(start = 10.dp))
                    }
                    Switch(
                        checked = entry.profileId in closeFriendIds,
                        onCheckedChange = { viewModel.toggle(entry.profileId) }
                    )
                }
                HorizontalDivider()
            }
        }
    }
}
