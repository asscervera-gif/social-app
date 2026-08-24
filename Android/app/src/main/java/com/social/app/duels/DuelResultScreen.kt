package com.social.app.duels

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Visor de solo lectura para un duelo YA completado — equivalente Compose
 * de DuelResultView.swift. Distinto de DuelScreen, que siempre arranca un
 * duelo NUEVO llamando a la IA. Antes "Ver duelo" no existía en absoluto
 * en Android.
 */
@Composable
fun DuelResultScreen(duelId: String) {
    @Serializable
    data class DuelRow(
        @SerialName("compatibility_delta") val compatibilityDelta: Int? = null,
        val explanation: String? = null,
        @SerialName("initiator_id") val initiatorId: String? = null,
        @SerialName("opponent_id") val opponentId: String? = null
    )

    @Serializable
    data class NameRow(@SerialName("display_name") val displayName: String)

    var delta by remember { mutableStateOf<Int?>(null) }
    var explanation by remember { mutableStateOf<String?>(null) }
    var opponentName by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Hallazgo real: igual que en DuelHistoryScreen antes de esta pasada,
    // este visor de resultado nunca mostraba contra quién fue el duelo.
    LaunchedEffect(duelId) {
        try {
            val row = SupabaseManager.client.from("duels")
                .select { filter { eq("id", duelId) } }
                .decodeSingle<DuelRow>()
            delta = row.compatibilityDelta ?: 0
            explanation = row.explanation

            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            val otherId = if (row.initiatorId == myId) row.opponentId else row.initiatorId
            if (otherId != null) {
                opponentName = try {
                    SupabaseManager.client.from("profiles")
                        .select { filter { eq("id", otherId) } }
                        .decodeSingleOrNull<NameRow>()?.displayName
                } catch (e: Exception) {
                    null
                }
            }
        } catch (e: Exception) {
            errorMessage = "No se pudo cargar el duelo."
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        val currentDelta = delta
        when {
            currentDelta != null -> {
                opponentName?.let {
                    Text("Duelo contra $it", style = MaterialTheme.typography.labelLarge)
                }
                Text(
                    "${if (currentDelta >= 0) "+" else ""}$currentDelta de compatibilidad",
                    style = MaterialTheme.typography.titleMedium
                )
                explanation?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
                }
            }
            errorMessage != null -> Text(errorMessage!!, color = MaterialTheme.colorScheme.error)
            else -> CircularProgressIndicator()
        }
    }
}
