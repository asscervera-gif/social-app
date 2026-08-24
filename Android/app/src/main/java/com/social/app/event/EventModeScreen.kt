package com.social.app.event

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth

/** Banner de evento activo + ranking de socials — equivalente Compose de
 * EventModeView.swift. Solo se renderiza cuando hay un evento activo cerca.
 * Incluye el botón "Unirse" que faltaba: joinEvent() ya existía en el
 * ViewModel pero no había ningún punto de entrada en la UI para llamarlo. */
@Composable
fun EventModeBanner(viewModel: EventModeViewModel = viewModel()) {
    val event by viewModel.activeEvent.collectAsState()
    val ranking by viewModel.ranking.collectAsState()
    val hasJoined by viewModel.hasJoined.collectAsState()
    val density by viewModel.density.collectAsState()

    val currentEvent = event ?: return

    Surface(
        modifier = Modifier.fillMaxWidth().padding(12.dp),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("✨ Estás en: ${currentEvent.name}", style = MaterialTheme.typography.titleMedium)
            // Hallazgo real, alineado con growth_strategy.md sección 6:
            // la métrica que de verdad importa es la "densidad efectiva"
            // (cuánta gente hay AHORA en este evento concreto), y el
            // valor tiene que sentirse en los primeros 30 segundos —
            // antes de esta pasada, `ranking` ya se cargaba en cuanto se
            // detectaba el evento (incluso sin haberse unido), pero nada
            // en la UI mostraba ese número hasta después de unirse. Ahora
            // es lo primero que se ve.
            if (ranking.isNotEmpty()) {
                Text(
                    "👥 ${ranking.size} ${if (ranking.size == 1) "persona" else "personas"} aquí ahora",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            // La densidad real (% de asistentes con la app activa en los
            // últimos 15 min, `event_density()`) es la métrica que
            // growth_strategy.md marca como la que de verdad importa —
            // más informativa que el número total de asistentes de
            // arriba, que no distingue quién sigue realmente aquí ahora.
            density?.let {
                Text(
                    "🔥 $it% activos ahora mismo",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (!hasJoined) {
                Button(onClick = {
                    val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@Button
                    viewModel.joinEvent(currentEvent.id, userId)
                }) {
                    Text("Unirme al evento")
                }
            } else {
                Text("Ranking de socials del evento", style = MaterialTheme.typography.labelMedium)
                ranking.forEachIndexed { index, attendee ->
                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("${index + 1}. ${attendee.displayName}")
                        Text("${attendee.socialCount} socials", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}
