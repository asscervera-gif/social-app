// supabase/functions/activity-ai/index.ts
//
// Hallazgo real (documentado en LOOP_STATE.md desde hace varias pasadas):
// `ChatViewModel.kt/.swift.checkActivitySuggestion()` siempre ha consultado
// la tabla `activities` de verdad (nunca fingido), pero NADA insertaba en
// esa tabla en ningún sitio — ni trigger, ni cliente, ni ninguna Edge
// Function. El campo "✨ Actividad sugerida" que aparece cuando la
// compatibilidad supera el 50% estaba conectado a un pozo vacío: la tabla
// nunca tuvo una sola fila real. Esta función cierra ese hueco de verdad,
// generándola con IA — mismo patrón exacto que `duel-ai` (proxy hacia
// Anthropic, ANTHROPIC_API_KEY nunca sale del servidor, rate limiting
// compartido vía `ai_usage`).
//
// Despliegue:
//   supabase functions deploy activity-ai
// (ANTHROPIC_API_KEY ya está configurado como secreto desde duel-ai)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-4-5";

// Mismo criterio conservador que duel-ai: una sugerencia por chat se
// genera como mucho una vez (ver comprobación de fila existente más
// abajo), así que este límite es solo para frenar un cliente que
// insistiera en pedirla en bucle.
const MAX_CALLS_PER_HOUR = 20;

interface ActivityRequest {
  chatId: string;
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: "Función mal configurada" }), { status: 500 });
  }

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

  const body: ActivityRequest = await req.json();
  if (!body.chatId) {
    return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
  }

  // El usuario tiene que ser de verdad miembro de este chat — sin esto,
  // cualquier usuario autenticado podría generar (y gastar la cuota de
  // IA en) sugerencias para chats ajenos.
  const { data: chat, error: chatError } = await admin
    .from("chats")
    .select("id, user_a_id, user_b_id, compatibility_score")
    .eq("id", body.chatId)
    .single();
  if (chatError || !chat || (chat.user_a_id !== userId && chat.user_b_id !== userId)) {
    return new Response(JSON.stringify({ error: "Chat no encontrado" }), { status: 404 });
  }

  // Ya existe una sugerencia para este chat: se devuelve la misma en vez
  // de gastar otra llamada a la IA — coherente con que el cliente no
  // vuelve a llamar si `activities` ya tiene una fila para este chat_id.
  const { data: existing } = await admin
    .from("activities")
    .select("suggestion")
    .eq("chat_id", body.chatId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (existing) {
    return new Response(JSON.stringify({ suggestion: existing.suggestion }), {
      headers: { "content-type": "application/json" },
    });
  }

  const otherId = chat.user_a_id === userId ? chat.user_b_id : chat.user_a_id;
  const [mine, theirs] = await Promise.all([
    admin.from("profiles").select("interests").eq("id", userId).single(),
    admin.from("profiles").select("interests").eq("id", otherId).single(),
  ]);
  const myInterests: string[] = mine.data?.interests ?? [];
  const theirInterests: string[] = theirs.data?.interests ?? [];

  const prompt = `Dos personas se conocieron en la app SOCIAL y tienen ${chat.compatibility_score}% de compatibilidad. Intereses de la persona A: ${myInterests.join(", ") || "sin especificar"}. Intereses de la persona B: ${theirInterests.join(", ") || "sin especificar"}. Sugiere UNA actividad concreta y breve (menos de 20 palabras) que puedan hacer juntas basada en intereses en común, en español, con tono cercano.

Responde ÚNICAMENTE con JSON: {"suggestion": "..."}`;

  const result = await callAnthropicForJSON<{ suggestion: string }>(prompt, 150);
  if (!result?.suggestion) {
    return new Response(JSON.stringify({ error: "La IA devolvió un formato inesperado" }), { status: 502 });
  }

  const { error: insertError } = await admin
    .from("activities")
    .insert({ chat_id: body.chatId, suggestion: result.suggestion });
  if (insertError) {
    return new Response(JSON.stringify({ error: "No se pudo guardar la sugerencia" }), { status: 500 });
  }

  return new Response(JSON.stringify({ suggestion: result.suggestion }), {
    headers: { "content-type": "application/json" },
  });
});

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

async function checkAndRecordUsage(admin: ReturnType<typeof createClient>, userId: string): Promise<boolean> {
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();

  const { count, error: countError } = await admin
    .from("ai_usage")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("created_at", oneHourAgo);

  if (countError) {
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
