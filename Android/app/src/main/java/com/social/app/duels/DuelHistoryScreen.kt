package com.social.app.duels

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Historial de duelos ("Fights") — antes un botón vacío en iOS y ni
 * siquiera existente en Android. Toca un duelo pasado para ver el
 * resultado completo con DuelResultScreen, que ya existía pero no tenía
 * ningún punto de entrada real más allá de las notificaciones.
 */
@Composable
fun DuelHistoryScreen(viewModel: DuelHistoryViewModel = viewModel(), onOpenDuel: (String) -> Unit) {
    val duels by viewModel.duels.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Tus duelos", style = MaterialTheme.typography.headlineSmall)
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.padding(top = 12.dp))
        }
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (!isLoading && duels.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no has hecho ningún duelo.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(duels) { duel ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenDuel(duel.id) }
                        .padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text(duel.opponentName ?: "Duelo")
                        Text(
                            duel.createdAt.take(10),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    val delta = duel.compatibilityDelta
                    Text(
                        delta?.let { "${if (it >= 0) "+" else ""}$it" } ?: "…",
                        color = if ((delta ?: 0) >= 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error
                    )
                }
            }
        }
    }
}
