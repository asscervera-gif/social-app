package com.social.app.duels

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import com.social.app.backend.StorageUploader
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.launch
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
    // "Compartir el resultado de un duelo como Historia" real, comparado
    // con Wordle/Kahoot -- ver renderDuelResultCard() (DuelResultCard.kt).
    var isSharing by remember { mutableStateOf(false) }
    var shareMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

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
                // "Compartir el resultado de un duelo como Historia"
                // real, comparado con Wordle/Kahoot -- reutiliza el
                // mismo mecanismo real de `stories` ya usado por
                // "compartir post a Historia" (0129_story_shared_post.sql),
                // aquí con una tarjeta generada en memoria en vez de una
                // foto ya existente.
                Button(
                    onClick = {
                        scope.launch {
                            isSharing = true
                            try {
                                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id
                                if (userId != null) {
                                    val bitmap = renderDuelResultCard(opponentName ?: "alguien", currentDelta)
                                    val stream = java.io.ByteArrayOutputStream()
                                    bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, stream)
                                    val url = StorageUploader.uploadBytes(stream.toByteArray(), userId, "jpg")
                                    SupabaseManager.client.from("stories").insert(
                                        mapOf("author_id" to userId, "media_url" to url)
                                    )
                                    shareMessage = "Compartido a tu historia"
                                }
                            } catch (e: Exception) {
                                shareMessage = "No se pudo compartir a tu historia."
                            }
                            isSharing = false
                        }
                    },
                    enabled = !isSharing,
                    modifier = Modifier.padding(top = 16.dp)
                ) {
                    Text(if (isSharing) "Compartiendo…" else "Compartir como Historia")
                }
                shareMessage?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 8.dp))
                }
            }
            errorMessage != null -> Text(errorMessage!!, color = MaterialTheme.colorScheme.error)
            else -> CircularProgressIndicator()
        }
    }
}
