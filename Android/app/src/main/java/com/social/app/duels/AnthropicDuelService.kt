package com.social.app.duels

import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.DuelQuestion
import io.github.jan.supabase.functions.functions
import io.ktor.client.statement.bodyAsText
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement

/**
 * Genera las preguntas del duelo y su puntuación — equivalente Kotlin de
 * AnthropicDuelService.swift. Llama a la misma Edge Function `duel-ai`
 * (supabase/functions/duel-ai/index.ts), que ya tiene la clave de Anthropic
 * como secreto de servidor y el rate-limit de 20 llamadas/hora/usuario —
 * ambas plataformas comparten exactamente el mismo backend, sin duplicar
 * lógica de seguridad.
 *
 * Firma verificada contra el .jar real de functions-kt 2.5.4 (bytecode
 * inspeccionado directamente, no documentación): `invoke(...)` devuelve
 * `io.ktor.client.statement.HttpResponse`, y `bodyAsText()` es la extensión
 * de Ktor que hay que importar explícitamente — faltaba ese import, ya
 * corregido tras el primer intento real de compilación de este proyecto.
 *
 * Hallazgo de integridad corregido: antes `scoreDuel` calculaba
 * `correctCount` en el propio cliente comparando contra `q.correctIndex`,
 * que el servidor le mandaba en claro junto a las preguntas — cualquiera
 * podía ver la respuesta correcta antes de elegir. Ahora `generate_questions`
 * devuelve un `sessionId` (las preguntas completas, con índice correcto,
 * se quedan solo en `duel_sessions` en el servidor) y `score_duel` manda
 * las respuestas del usuario, no un conteo que el cliente pudiera inventar
 * — el servidor calcula el acierto real contra la sesión guardada.
 */
class AnthropicDuelService {

    @Serializable
    private data class SectionPayload(
        @SerialName("section_key") val sectionKey: String,
        val content: Map<String, String>
    )

    @Serializable
    private data class GenerateRequest(
        val action: String = "generate_questions",
        val opponentSections: List<SectionPayload>
    )

    @Serializable
    data class GenerateResponse(
        val sessionId: String,
        val questions: List<DuelQuestion>
    )

    @Serializable
    private data class ScoreRequest(
        val action: String = "score_duel",
        val sessionId: String,
        val answers: List<Int>,
        val chatId: String,
        val opponentId: String
    )

    @Serializable
    private data class ScoreResponse(val delta: Int, val explanation: String)

    suspend fun generateDuelQuestions(opponentSections: List<Pair<String, Map<String, String>>>): GenerateResponse {
        val body = GenerateRequest(opponentSections = opponentSections.map { SectionPayload(it.first, it.second) })
        val response = SupabaseManager.client.functions.invoke("duel-ai", body = body)
        return Json.decodeFromString(response.bodyAsText())
    }

    /** Hallazgo de integridad real corregido esta pasada: antes el
     * cliente insertaba la fila en `duels` él mismo con el delta que
     * esta llamada devolvía — un cliente modificado podía inventar
     * cualquier valor sin pasar por aquí. Ahora es la propia Edge
     * Function (`service_role`) la que crea la fila real tras verificar
     * la sesión — `chatId`/`opponentId` viajan para que sepa dónde
     * guardarla (ver `duels_insert` revocada en
     * 0035_duels_insert_service_role_only.sql). */
    suspend fun scoreDuel(sessionId: String, answers: List<Int>, chatId: String, opponentId: String): Pair<Int, String> {
        val body = ScoreRequest(sessionId = sessionId, answers = answers, chatId = chatId, opponentId = opponentId)
        val response = SupabaseManager.client.functions.invoke("duel-ai", body = body)
        val result = Json.decodeFromString<ScoreResponse>(response.bodyAsText())
        return result.delta to result.explanation
    }
}
