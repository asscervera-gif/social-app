//
//  DuelViewModel.swift
//  Social
//
//  Orquesta un duelo completo: generación de preguntas, respuestas del
//  usuario, y cálculo final del delta de compatibilidad.
//
//  Hallazgo de integridad corregido: ya no cuenta aciertos en el cliente —
//  `sessionID` viaja a `scoreDuel` en vez de las preguntas completas (ver
//  AnthropicDuelService.swift/duel-ai/index.ts).
//

import Foundation

@MainActor
final class DuelViewModel: ObservableObject {

    enum Stage {
        case loading, answering, scoring, finished
    }

    let chatID: UUID
    private let initiatorID: UUID
    private let opponentID: UUID
    private let service: AnthropicDuelService
    private var sessionID: UUID?

    @Published var stage: Stage = .loading
    @Published var questions: [DuelQuestion] = []
    @Published var currentIndex = 0
    @Published var answers: [Int] = []
    @Published var delta: Int?
    @Published var explanation: String?
    @Published var errorMessage: String?

    init(chatID: UUID, initiatorID: UUID, opponentID: UUID) {
        self.chatID = chatID
        self.initiatorID = initiatorID
        self.opponentID = opponentID
        self.service = AnthropicDuelService()
    }

    /// Reutilizada tal cual para "🔁 Retar de nuevo" (DuelView.swift,
    /// stage == .finished) -- hueco real #3 de la auditoría de sistemas
    /// propios de SOCIAL: antes cada duelo nuevo exigía volver a entrar
    /// por ChatView desde cero. Hallazgo real al reutilizar este mismo
    /// ViewModel para la revancha (no uno nuevo): `currentIndex`/
    /// `answers` no se reiniciaban -- un segundo duelo en la misma
    /// instancia arrastraba las respuestas y el índice del anterior,
    /// disparando `finish()` de inmediato en la primera respuesta nueva.
    /// Mismo bug real ya corregido en la versión Kotlin equivalente.
    func start(opponentSections: [ProfileSection]) async {
        stage = .loading
        currentIndex = 0
        answers = []
        delta = nil
        explanation = nil
        errorMessage = nil
        do {
            let response = try await service.generateDuelQuestions(about: opponentSections)
            sessionID = response.sessionId
            questions = response.questions
            stage = .answering
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: solo se registraba `duel_completed` —
            // sin `duel_started` es imposible medir cuánta gente empieza
            // un duelo y lo abandona antes de terminarlo.
            AnalyticsManager.track("duel_started")
        } catch {
            errorMessage = "No se pudo generar el duelo: \(error.localizedDescription)"
        }
    }

    func answer(_ optionIndex: Int) {
        answers.append(optionIndex)
        if currentIndex + 1 < questions.count {
            currentIndex += 1
        } else {
            Task { await finish() }
        }
    }

    /// Hallazgo de integridad real corregido esta pasada: antes este
    /// ViewModel insertaba la fila en `duels` él mismo (ver `save()`,
    /// eliminada) — un cliente modificado podía guardar cualquier
    /// delta/explanation inventado sin jugar un duelo real. Ahora
    /// `scoreDuel` ya deja el resultado guardado de verdad en el servidor
    /// (Edge Function `duel-ai`, `service_role`); este cliente ya no
    /// escribe `duels` en absoluto. Mismo fix ya construido en la versión
    /// Kotlin equivalente.
    private func finish() async {
        guard let sessionID else {
            errorMessage = "No se pudo calcular el resultado del duelo."
            return
        }
        stage = .scoring
        do {
            let result = try await service.scoreDuel(sessionID: sessionID, answers: answers, chatID: chatID, opponentID: opponentID)
            delta = result.delta
            explanation = result.explanation
            AnalyticsManager.track("duel_completed")
            stage = .finished
        } catch {
            errorMessage = "No se pudo calcular el resultado del duelo."
        }
    }
}
