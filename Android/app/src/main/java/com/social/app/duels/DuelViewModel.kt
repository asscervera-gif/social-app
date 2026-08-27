package com.social.app.duels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.model.DuelQuestion
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class DuelStage { LOADING, ANSWERING, SCORING, FINISHED }

/** Orquesta un duelo completo — equivalente Kotlin de DuelViewModel.swift.
 * Hallazgo de integridad corregido: ya no cuenta aciertos en el cliente
 * (`sessionId` en vez de las preguntas completas viaja a `scoreDuel`, ver
 * AnthropicDuelService.kt/duel-ai/index.ts). */
class DuelViewModel(private val chatId: String, private val opponentId: String) : ViewModel() {

    private val service = AnthropicDuelService()

    private val _stage = MutableStateFlow(DuelStage.LOADING)
    val stage: StateFlow<DuelStage> = _stage.asStateFlow()

    private val _questions = MutableStateFlow<List<DuelQuestion>>(emptyList())
    val questions: StateFlow<List<DuelQuestion>> = _questions.asStateFlow()

    private var sessionId: String? = null

    private val _currentIndex = MutableStateFlow(0)
    val currentIndex: StateFlow<Int> = _currentIndex.asStateFlow()

    private val answers = mutableListOf<Int>()

    private val _delta = MutableStateFlow<Int?>(null)
    val delta: StateFlow<Int?> = _delta.asStateFlow()

    private val _explanation = MutableStateFlow<String?>(null)
    val explanation: StateFlow<String?> = _explanation.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    /** Reutilizada tal cual para "🔁 Retar de nuevo" (DuelScreen.kt,
     * DuelStage.FINISHED) -- hueco real #3 de la auditoría de sistemas
     * propios de SOCIAL: antes cada duelo nuevo exigía volver a entrar
     * por ChatScreen desde cero. Hallazgo real al reutilizar este mismo
     * ViewModel para la revancha (no uno nuevo): `_currentIndex`/
     * `answers` no se reiniciaban -- un segundo duelo en la misma
     * instancia arrastraba las respuestas y el índice del anterior,
     * disparando `finish()` de inmediato en la primera respuesta nueva. */
    fun start(opponentSections: List<Pair<String, Map<String, String>>>) {
        viewModelScope.launch {
            _stage.value = DuelStage.LOADING
            _currentIndex.value = 0
            answers.clear()
            _delta.value = null
            _explanation.value = null
            _errorMessage.value = null
            try {
                val response = service.generateDuelQuestions(opponentSections)
                sessionId = response.sessionId
                _questions.value = response.questions
                _stage.value = DuelStage.ANSWERING
                // Hallazgo real: solo se registraba `duel_completed` —
                // sin `duel_started` es imposible medir cuánta gente
                // empieza un duelo y lo abandona antes de terminarlo.
                com.social.app.backend.AnalyticsManager.track("duel_started")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo generar el duelo: ${e.message}"
            }
        }
    }

    fun answer(optionIndex: Int) {
        answers.add(optionIndex)
        if (_currentIndex.value + 1 < _questions.value.size) {
            _currentIndex.value += 1
        } else {
            finish()
        }
    }

    private fun finish() {
        val currentSessionId = sessionId ?: run {
            _errorMessage.value = "No se pudo calcular el resultado del duelo."
            return
        }
        viewModelScope.launch {
            _stage.value = DuelStage.SCORING
            try {
                // Hallazgo de integridad real corregido esta pasada: antes
                // este ViewModel insertaba la fila en `duels` él mismo
                // (ver `save()`, eliminada) — un cliente modificado podía
                // guardar cualquier delta/explanation inventado sin jugar
                // un duelo real. Ahora `scoreDuel` ya deja el resultado
                // guardado de verdad en el servidor (Edge Function
                // `duel-ai`, `service_role`); este cliente ya no escribe
                // `duels` en absoluto.
                val (delta, explanation) = service.scoreDuel(currentSessionId, answers, chatId, opponentId)
                _delta.value = delta
                _explanation.value = explanation
                com.social.app.backend.AnalyticsManager.track("duel_completed")
                _stage.value = DuelStage.FINISHED
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo calcular el resultado del duelo."
            }
        }
    }
}
