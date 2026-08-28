package com.social.app.duels

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
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
 * Duelo de preguntas — equivalente Compose de DuelView.swift. Menos de 60s,
 * una pregunta a la vez, resultado con delta y explicación al terminar.
 */
@Composable
fun DuelScreen(chatId: String, opponentId: String, opponentSections: List<Pair<String, Map<String, String>>>) {
    val viewModel = remember(chatId) { DuelViewModel(chatId, opponentId) }
    val stage by viewModel.stage.collectAsState()
    val questions by viewModel.questions.collectAsState()
    val currentIndex by viewModel.currentIndex.collectAsState()
    val delta by viewModel.delta.collectAsState()
    val explanation by viewModel.explanation.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // Cuenta atrás real por pregunta, comparado con el patrón de trivia
    // por turnos tipo Kahoot -- ver DuelViewModel.startTimer().
    val timeLeft by viewModel.timeLeft.collectAsState()

    LaunchedEffect(chatId) { viewModel.start(opponentSections) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        when (stage) {
            DuelStage.LOADING -> {
                CircularProgressIndicator()
                Text("Preparando el duelo…")
            }
            DuelStage.ANSWERING -> {
                val question = questions.getOrNull(currentIndex)
                if (question != null) {
                    Text("Pregunta ${currentIndex + 1} de ${questions.size}", style = MaterialTheme.typography.labelMedium)
                    Text(
                        "⏱ ${timeLeft}s",
                        style = MaterialTheme.typography.labelLarge,
                        color = if (timeLeft <= 3) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(question.prompt, style = MaterialTheme.typography.titleMedium)
                    question.options.forEachIndexed { index, option ->
                        OutlinedButton(onClick = { viewModel.answer(index) }, modifier = Modifier.fillMaxWidth()) {
                            Text(option)
                        }
                    }
                }
            }
            DuelStage.SCORING -> {
                CircularProgressIndicator()
                Text("Calculando compatibilidad…")
            }
            DuelStage.FINISHED -> {
                Text(if ((delta ?: 0) >= 0) "📈" else "📉", style = MaterialTheme.typography.headlineLarge)
                Text("${if ((delta ?: 0) >= 0) "+" else ""}${delta ?: 0} de compatibilidad", style = MaterialTheme.typography.titleMedium)
                explanation?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                // Revancha real, comparado con juegos/apps de citas con
                // duelos de preguntas -- antes exigía volver a entrar por
                // ChatScreen ("⚡ Retar a duelo") desde cero cada vez.
                Button(onClick = { viewModel.start(opponentSections) }) {
                    Text("🔁 Retar de nuevo")
                }
            }
        }

        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
}
