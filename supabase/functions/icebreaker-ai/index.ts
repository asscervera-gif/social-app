// supabase/functions/icebreaker-ai/index.ts
//
// "Potenciar la IA" (petición explícita del usuario): comparando con
// Hinge ("Your Turn"/prompts con IA) y Bumble ("Opening Move"), ambas
// sugieren un primer mensaje real cuando dos personas hacen match — SOCIAL
// no tenía nada parecido, un chat nuevo (social aceptado, sin mensajes
// todavía) se quedaba con el campo de texto vacío y ninguna ayuda para
// arrancar la conversación. Mismo patrón exacto que `duel-ai`/
// `activity-ai`: proxy hacia Anthropic, `ANTHROPIC_API_KEY` nunca sale del
// servidor, rate limiting compartido vía `ai_usage`, verificación real de
// que el usuario es miembro del chat.
//
// A diferencia de `activity-ai`, esto NO se persiste en ninguna tabla —
// es una sugerencia efímera (igual que el placeholder de un campo de
// texto), se puede pedir de nuevo si no gusta, sin acumular filas.
//
// Despliegue:
//   supabase functions deploy icebreaker-ai
// (ANTHROPIC_API_KEY ya está configurado como secreto desde duel-ai)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-4-5";

// Mismo límite que duel-ai/activity-ai. Aquí es más importante todavía
// (sin persistencia, un usuario podría pedir "otra sugerencia" muchas
// veces) — 20/hora sigue siendo generoso para un uso real y acota el
// gasto máximo.
const MAX_CALLS_PER_HOUR = 20;

interface IcebreakerRequest {
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

  const body: IcebreakerRequest = await req.json();
  if (!body.chatId) {
    return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
  }

  // Mismo refuerzo que activity-ai: verificar membresía real del chat
  // antes de gastar ninguna llamada a la IA.
  const { data: chat, error: chatError } = await admin
    .from("chats")
    .select("id, user_a_id, user_b_id")
    .eq("id", body.chatId)
    .single();
  if (chatError || !chat || (chat.user_a_id !== userId && chat.user_b_id !== userId)) {
    return new Response(JSON.stringify({ error: "Chat no encontrado" }), { status: 404 });
  }

  const otherId = chat.user_a_id === userId ? chat.user_b_id : chat.user_a_id;
  const [mine, theirs] = await Promise.all([
    admin.from("profiles").select("interests").eq("id", userId).single(),
    admin.from("profiles").select("interests").eq("id", otherId).single(),
  ]);
  const myInterests: string[] = mine.data?.interests ?? [];
  const theirInterests: string[] = theirs.data?.interests ?? [];
  const shared = myInterests.filter((i) => theirInterests.includes(i));

  const prompt = `Sugiere UN mensaje de apertura breve (menos de 25 palabras), natural y sin sonar a plantilla, para empezar a hablar con alguien que acabas de conocer en la app SOCIAL. ${
    shared.length > 0
      ? `Ambos comparten estos intereses: ${shared.join(", ")}. Úsalos si suena natural.`
      : `Intereses de la otra persona: ${theirInterests.join(", ") || "sin especificar"}.`
  } En español, tono cercano y directo, sin emojis de más.

Responde ÚNICAMENTE con JSON: {"message": "..."}`;

  const result = await callAnthropicForJSON<{ message: string }>(prompt, 100);
  if (!result?.message) {
    return new Response(JSON.stringify({ error: "La IA devolvió un formato inesperado" }), { status: 502 });
  }

  return new Response(JSON.stringify({ message: result.message }), {
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
