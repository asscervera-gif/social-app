//
//  AnthropicDuelService.swift
//  Social
//
//  Genera las 5 preguntas del duelo y, al terminar, el delta de compatibilidad
//  y su explicación. La llamada real a la API de Anthropic vive en la Supabase
//  Edge Function `duel-ai` (supabase/functions/duel-ai/index.ts): ahí está la
//  ANTHROPIC_API_KEY, nunca en este binario. Este servicio solo invoca esa
//  función a través del cliente Supabase, que ya adjunta el JWT del usuario.
//
//  Despliega la función antes de usar esto:
//    supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//    supabase functions deploy duel-ai
//
//  Hallazgo de integridad corregido: antes `scoreDuel` calculaba
//  `correctCount` en el propio cliente comparando contra `q.correctIndex`,
//  que el servidor mandaba en claro junto a las preguntas — cualquiera
//  podía ver la respuesta correcta antes de elegir. Ahora
//  `generate_questions` devuelve un `sessionId` (las preguntas completas
//  se quedan solo en `duel_sessions` en el servidor) y `score_duel` manda
//  las respuestas del usuario, no un conteo que el cliente pudiera
//  inventar — el servidor calcula el acierto real.
//

import Foundation

struct DuelGenerateResponse: Decodable {
    let sessionId: UUID
    let questions: [DuelQuestion]
}

struct AnthropicDuelService {

    /// Genera 5 preguntas de opción múltiple sobre `opponentSections`.
    func generateDuelQuestions(about opponentSections: [ProfileSection]) async throws -> DuelGenerateResponse {
        struct RequestBody: Encodable {
            let action = "generate_questions"
            let opponentSections: [SectionPayload]
        }
        struct SectionPayload: Encodable {
            let section_key: String
            let content: [String: String]
        }

        let payload = RequestBody(
            opponentSections: opponentSections.map { SectionPayload(section_key: $0.sectionKey, content: $0.content) }
        )

        return try await invokeDuelAI(body: payload)
    }

    /// Calcula el delta de compatibilidad y una explicación corta.
    ///
    /// Hallazgo de integridad real corregido esta pasada: antes el
    /// cliente insertaba la fila en `duels` él mismo con el delta que
    /// esta llamada devolvía — un cliente modificado podía inventar
    /// cualquier valor sin pasar por aquí. Ahora es la propia Edge
    /// Function (`service_role`) la que crea la fila real tras verificar
    /// la sesión — `chatID`/`opponentID` viajan para que sepa dónde
    /// guardarla (ver `duels_insert` revocada en
    /// 0035_duels_insert_service_role_only.sql). Mismo fix ya construido
    /// en la versión Kotlin equivalente.
    func scoreDuel(sessionID: UUID, answers: [Int], chatID: UUID, opponentID: UUID) async throws -> (delta: Int, explanation: String) {
        struct RequestBody: Encodable {
            let action = "score_duel"
            let sessionId: UUID
            let answers: [Int]
            let chatId: UUID
            let opponentId: UUID
        }
        struct ScoreResponse: Decodable {
            let delta: Int
            let explanation: String
        }

        let payload = RequestBody(sessionId: sessionID, answers: answers, chatId: chatID, opponentId: opponentID)
        let result: ScoreResponse = try await invokeDuelAI(body: payload)
        return (result.delta, result.explanation)
    }

    // Hallazgo real, primer resultado de tener por fin un compilador de
    // verdad (CI en GitHub Actions, runner macOS, 2026-08-24): no existe
    // ningún overload de `functions.invoke` que devuelva `Data` — solo
    // `invoke<T: Decodable>(_:options:decoder:) async throws -> T` (decodifica
    // directamente) y `invoke(_:options:) async throws` (descarta el cuerpo).
    // Sin contexto de tipo, `let data = try await ...invoke(...)` resolvía
    // al segundo (Void), y el `JSONDecoder().decode(_:from: data)` de
    // después fallaba porque `data` nunca fue `Data`. Confirmado leyendo el
    // código fuente real de
    // supabase/supabase-swift/Sources/Functions/FunctionsClient.swift.
    // Se usa ahora el overload genérico directamente — sin
    // JSONDecoder manual ni comprobación de `isEmpty` (si el cuerpo no
    // decodifica al tipo esperado, `invoke` ya lanza el error real).
    private func invokeDuelAI<Body: Encodable, Response: Decodable>(body: Body) async throws -> Response {
        try await SupabaseManager.shared.client.functions
            .invoke("duel-ai", options: .init(body: body))
    }
}

enum AnthropicDuelError: Error, LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "No se pudo conectar con el servicio de IA."
        case .invalidResponse: return "La IA devolvió una respuesta con un formato inesperado."
        }
    }
}
