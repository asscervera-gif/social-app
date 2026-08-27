package com.social.app.calls

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
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
 * Historial de llamadas real, comparado con WhatsApp/Messenger/FaceTime --
 * ver CallHistoryViewModel.kt para el hallazgo completo. Icono real por
 * dirección/resultado (📞↗/📞↙ entrante-saliente, ❌ perdida), duración
 * real cuando la llamada de verdad terminó con alguien al otro lado
 * (`ended_at - created_at`, solo si `status = 'ended'` -- una `declined`/
 * `missed` real nunca tuvo duración real que mostrar).
 */
@Composable
fun CallHistoryScreen(viewModel: CallHistoryViewModel = remember { CallHistoryViewModel() }) {
    val entries by viewModel.entries.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (isLoading && entries.isEmpty()) {
            CircularProgressIndicator(modifier = Modifier.padding(top = 12.dp))
        }
        if (!isLoading && entries.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no tienes ninguna llamada.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(entries, key = { it.call.id }) { entry ->
                val call = entry.call
                val missed = call.status == "declined" || call.status == "missed"
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
                ) {
                    Text(
                        when {
                            missed -> "❌"
                            entry.isOutgoing -> "📞↗"
                            else -> "📞↙"
                        },
                        modifier = Modifier.padding(end = 10.dp)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            (if (entry.isGroup) "👥 " else "") + entry.otherName,
                            style = MaterialTheme.typography.titleSmall,
                            color = if (missed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            com.social.app.util.relativeTime(call.createdAt) + if (call.kind == "video") " · Vídeo" else " · Voz",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    // Duración real solo si la llamada de verdad terminó
                    // con alguien al otro lado -- una perdida/rechazada
                    // nunca tuvo duración real, mostrarla inventaría un
                    // dato que no existe.
                    if (call.status == "ended" && call.endedAt != null) {
                        val duration = try {
                            val start = java.time.Instant.parse(call.createdAt)
                            val end = java.time.Instant.parse(call.endedAt)
                            val secs = java.time.Duration.between(start, end).seconds.coerceAtLeast(0)
                            "%d:%02d".format(secs / 60, secs % 60)
                        } catch (e: Exception) {
                            null
                        }
                        duration?.let {
                            Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
