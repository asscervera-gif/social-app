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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
 * (Premium) -- ver ProfileVisitsViewModel.kt/0132_profile_visits.sql.
 * Misma estructura que FollowListScreen.kt (avatar + nombre + toque para
 * abrir el perfil), sin botones de seguir/eliminar -- aquí solo se
 * consulta, no se actúa.
 */
@Composable
fun ProfileVisitsScreen(
    viewModel: ProfileVisitsViewModel = viewModel(),
    onOpenProfile: (String) -> Unit
) {
    val visits by viewModel.visits.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth()) {
        errorMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
        }
        if (visits.isEmpty() && errorMessage == null) {
            Text(
                "Todavía nadie ha visitado tu perfil.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth()) {
            items(visits, key = { it.profileId }) { entry ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                        .clickable { onOpenProfile(entry.profileId) },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        com.social.app.avatar.AvatarView(config = entry.avatarConfig ?: emptyMap(), size = 44.dp)
                        Text(entry.displayName, modifier = Modifier.padding(start = 10.dp))
                    }
                    Text(
                        com.social.app.util.relativeTime(entry.visitedAt),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                HorizontalDivider()
            }
        }
    }
}
