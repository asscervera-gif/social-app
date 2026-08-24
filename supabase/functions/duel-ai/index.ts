// supabase/functions/duel-ai/index.ts
//
// Edge Function que hace de proxy hacia la API de Anthropic. Sustituye la
// llamada directa desde el cliente iOS (ver advertencia de seguridad en
// AnthropicDuelService.swift): ANTHROPIC_API_KEY vive aquí, como secreto de
// Supabase, y nunca en el binario de la app.
//
// Incluye rate limiting por usuario (ver security_checklist.md, sección 3):
// sin él, cualquier usuario autenticado podría generar llamadas ilimitadas
// a Anthropic a costa de la cuenta del proyecto. Requiere la tabla
// `ai_usage` (ver supabase/migrations/0004_ai_usage.sql).
//
// HALLAZGO DE INTEGRIDAD REAL (documentado en LOOP_STATE.md), corregido
// aquí de fondo: antes, `generate_questions` devolvía `correctIndex` al
// cliente directamente (era parte del propio DuelQuestion usado para
// pintar las opciones) — cualquiera podía ver las respuestas correctas
// antes de elegir. Una mitigación anterior solo acotaba questionCount/
// correctCount a un rango razonable en score_duel, sin cerrar el problema
// de fondo. Ahora: `generate_questions` guarda las preguntas COMPLETAS
// (con correctIndex) en `duel_sessions` (0010_duel_sessions.sql, solo
// legible por esta función vía service_role) y devuelve al cliente
// únicamente { sessionId, questions: [{prompt, options}] } — sin
// correctIndex. `score_duel` recibe { sessionId, answers }, no un
// correctCount que se pueda falsificar, y calcula el acierto real
// comparando contra la sesión guardada en el servidor.
//
// Despliegue:
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase functions deploy duel-ai

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-4-5";

// Límite conservador: un duelo usa 2 llamadas (preguntas + puntuación).
// 20/hora permite ~10 duelos/hora por persona, muy por encima de un uso
// normal, y acota el gasto máximo si una cuenta se ve comprometida.
const MAX_CALLS_PER_HOUR = 20;

interface DuelRequest {
  action: "generate_questions" | "score_duel";
  opponentSections?: { section_key: string; content: Record<string, string> }[];
  sessionId?: string;
  answers?: number[];
  chatId?: string;
  opponentId?: string;
}

interface StoredQuestion {
  prompt: string;
  options: string[];
  correctIndex: number;
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: "Función mal configurada" }), { status: 500 });
  }

  // El JWT del usuario llega en el header Authorization; Supabase ya lo
  // valida antes de invocar el handler, aquí solo lo decodificamos para
  // identificar al usuario y aplicarle el límite.
  const authHeader = req.headers.get("Authorization") ?? "";
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: userData, error: userError } = await admin.auth.getUser(
    authHeader.replace("Bearer ", "")
  );
  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ error: "No autenticado" }), { status: 401 });
  }
  const userId = userData.user.id;

  const withinLimit = await checkAndRecordUsage(admin, userId);
  if (!withinLimit) {
    return new Response(
      JSON.stringify({ error: "Límite de uso de IA alcanzado, inténtalo en un rato" }),
      { status: 429 }
    );
  }

  const body: DuelRequest = await req.json();

  if (body.action === "generate_questions") {
    return await handleGenerateQuestions(admin, userId, body);
  }
  if (body.action === "score_duel") {
    return await handleScoreDuel(admin, userId, body);
  }
  return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
});

async function handleGenerateQuestions(
  admin: ReturnType<typeof createClient>,
  userId: string,
  body: DuelRequest
): Promise<Response> {
  if (!body.opponentSections) {
    return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
  }
  const summary = body.opponentSections
    .map((s) => `- ${s.section_key}: ${Object.values(s.content).join(", ")}`)
    .join("\n");
  const prompt = `Genera exactamente 5 preguntas de opción múltiple, breves (menos de 15 palabras cada una), sobre la persona B para que la persona A adivine qué tan bien la conoce. Cada pregunta tiene 3 opciones cortas y un índice de la opción correcta (0, 1 o 2).

Perfil de la persona B:
${summary}

Responde ÚNICAMENTE con JSON válido, sin texto adicional, con esta forma:
[{"prompt": "...", "options": ["...", "...", "..."], "correctIndex": 0}, ...]`;

  const questions = await callAnthropicForJSON<StoredQuestion[]>(prompt, 800);
  if (!questions) {
    return new Response(JSON.stringify({ error: "La IA devolvió un formato inesperado" }), { status: 502 });
  }

  const { data: session, error: insertError } = await admin
    .from("duel_sessions")
    .insert({ initiator_id: userId, questions })
    .select("id")
    .single();
  if (insertError || !session) {
    return new Response(JSON.stringify({ error: "No se pudo crear la sesión de duelo" }), { status: 500 });
  }

  // Nunca se manda correctIndex al cliente — solo lo necesario para pintar
  // las opciones. Ver comentario de cabecera sobre el hallazgo de integridad.
  const publicQuestions = questions.map((q) => ({ prompt: q.prompt, options: q.options }));
  return new Response(JSON.stringify({ sessionId: session.id, questions: publicQuestions }), {
    headers: { "content-type": "application/json" },
  });
}

async function handleScoreDuel(
  admin: ReturnType<typeof createClient>,
  userId: string,
  body: DuelRequest
): Promise<Response> {
  if (!body.sessionId || !Array.isArray(body.answers) || !body.chatId || !body.opponentId) {
    return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
  }

  const { data: session, error: sessionError } = await admin
    .from("duel_sessions")
    .select("id, initiator_id, questions, used")
    .eq("id", body.sessionId)
    .single();
  if (sessionError || !session) {
    return new Response(JSON.stringify({ error: "Sesión de duelo no encontrada" }), { status: 404 });
  }
  // Solo quien generó las preguntas puede puntuarlas, y solo una vez —
  // cierra tanto la suplantación de sesión ajena como la reutilización
  // para inflar el delta repetidamente con la misma sesión.
  if (session.initiator_id !== userId || session.used) {
    return new Response(JSON.stringify({ error: "Sesión inválida" }), { status: 403 });
  }

  const questions = session.questions as StoredQuestion[];
  const answers = body.answers;
  const correctCount = questions.reduce(
    (acc, q, i) => acc + (q.correctIndex === answers[i] ? 1 : 0),
    0
  );

  await admin.from("duel_sessions").update({ used: true }).eq("id", session.id);

  const prompt = `Un duelo de compatibilidad tuvo ${questions.length} preguntas y ${correctCount} respuestas correctas. Da un delta de compatibilidad entre -15 y +15 (más aciertos, delta más alto) y una explicación de una frase, en español, motivadora y breve.

Responde ÚNICAMENTE con JSON: {"delta": 0, "explanation": "..."}`;

  const result = await callAnthropicForJSON<{ delta: number; explanation: string }>(prompt, 200);
  if (!result) {
    return new Response(JSON.stringify({ error: "La IA devolvió un formato inesperado" }), { status: 502 });
  }

  // HALLAZGO DE INTEGRIDAD REAL corregido aquí (documentado en
  // LOOP_STATE.md): hasta esta pasada, el CLIENTE insertaba la fila en
  // `duels` directamente con el `delta`/`explanation` que esta función
  // le devolvía — nada impedía a un cliente modificado insertar
  // cualquier valor inventado, sin pasar nunca por esta función. La
  // protección añadida antes (0034_protect_duel_scoring.sql) solo cubría
  // UPDATE, pero el hueco real estaba en el INSERT. Ahora es esta función
  // (`service_role`, bypasea RLS) la que crea la fila — el cliente ya no
  // inserta en `duels` en absoluto (ver `duels_insert` revocada en
  // 0035_duels_insert_service_role_only.sql).
  const publicQuestions = questions.map((q) => ({ prompt: q.prompt, options: q.options }));
  const { error: insertError } = await admin.from("duels").insert({
    chat_id: body.chatId,
    initiator_id: userId,
    opponent_id: body.opponentId,
    questions: publicQuestions,
    answers,
    compatibility_delta: result.delta,
    explanation: result.explanation,
    is_public: false,
  });
  if (insertError) {
    return new Response(JSON.stringify({ error: "No se pudo guardar el resultado del duelo" }), { status: 500 });
  }

  return new Response(JSON.stringify(result), {
    headers: { "content-type": "application/json" },
  });
}

async function callAnthropicForJSON<T>(prompt: string, maxTokens: number): Promise<T | null> {
  const anthropicResponse = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: maxTokens,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!anthropicResponse.ok) return null;

  const data = await anthropicResponse.json();
  const text: string = data.content?.[0]?.text ?? "";
  const json = extractJSON(text);
  if (!json) return null;
  try {
    return JSON.parse(json) as T;
  } catch {
    return null;
  }
}

/// Registra la llamada y devuelve false si el usuario superó MAX_CALLS_PER_HOUR
/// en la última hora. Usa la tabla `ai_usage` (una fila por llamada) porque
/// es la forma más simple de auditar abuso después, no solo de bloquearlo.
async function checkAndRecordUsage(admin: ReturnType<typeof createClient>, userId: string): Promise<boolean> {
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();

  const { count, error: countError } = await admin
    .from("ai_usage")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("created_at", oneHourAgo);

  if (countError) {
    // Si no se puede verificar el límite, se falla cerrado en vez de abierto:
    // mejor negar una petición legítima que permitir gasto sin control.
    return false;
  }
  if ((count ?? 0) >= MAX_CALLS_PER_HOUR) {
    return false;
  }

  await admin.from("ai_usage").insert({ user_id: userId });
  return true;
}

function extractJSON(text: string): string | null {
  const start = text.search(/[[{]/);
  if (start === -1) return null;
  const opening = text[start];
  const closing = opening === "[" ? "]" : "}";
  const end = text.lastIndexOf(closing);
  if (end === -1) return null;
  return text.slice(start, end + 1);
}
