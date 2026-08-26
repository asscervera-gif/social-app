// supabase/functions/call-token/index.ts
//
// Videollamada/llamada de voz 1:1 real (0079_calls.sql): mint de un token
// de acceso real de LiveKit para la sala de UNA llamada concreta -- mismo
// motivo y misma técnica exacta que live-token/index.ts (JWT HS256
// firmado a mano con Web Crypto, sin SDK de servidor de LiveKit para
// Deno). Duplicado a propósito, no compartido: cada función comprueba
// autorización contra una tabla distinta (`calls` aquí, `live_streams`
// en live-token) con reglas de autorización distintas (dos participantes
// simétricos aquí; host/espectador asimétrico allí) -- factorizarlo en un
// módulo común solo para el firmado HS256 en sí no ahorraría la parte que
// de verdad importa (la comprobación real contra la base de datos).
//
// Autorización real, no confiada al cliente: solo se emite un token
// cuando la llamada YA está `accepted` de verdad en la base de datos (RLS
// ya garantiza que solo caller_id/callee_id pudieron ponerla en ese
// estado) y quien lo pide es de verdad uno de los dos participantes.
//
// Pendiente real de DESPLIEGUE, no de código (mismo criterio que
// push/APNs-FCM y que live-token): LIVEKIT_API_KEY/LIVEKIT_API_SECRET/
// LIVEKIT_WS_URL reales de un proyecto LiveKit Cloud, fijados con
// `supabase secrets set` -- ya deberían estar puestos si "En directo" se
// desplegó antes, esta función reutiliza los mismos tres secrets.
//
// Despliegue:
//   supabase functions deploy call-token

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const LIVEKIT_API_KEY = Deno.env.get("LIVEKIT_API_KEY");
const LIVEKIT_API_SECRET = Deno.env.get("LIVEKIT_API_SECRET");
const LIVEKIT_WS_URL = Deno.env.get("LIVEKIT_WS_URL");

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET || !LIVEKIT_WS_URL) {
    return new Response(JSON.stringify({ error: "Función mal configurada (faltan credenciales reales de LiveKit)" }), { status: 500 });
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

  let callId: string | undefined;
  try {
    const body = await req.json();
    callId = body.callId;
  } catch {
    // sin body válido, callId queda undefined -> 400 más abajo.
  }
  if (!callId) {
    return new Response(JSON.stringify({ error: "Falta callId" }), { status: 400 });
  }

  const { data: call, error: callError } = await admin
    .from("calls")
    .select("id, caller_id, callee_id, room_name, status")
    .eq("id", callId)
    .maybeSingle();
  if (callError || !call) {
    return new Response(JSON.stringify({ error: "Llamada no encontrada" }), { status: 404 });
  }
  if (call.caller_id !== userId && call.callee_id !== userId) {
    return new Response(JSON.stringify({ error: "No eres parte de esta llamada" }), { status: 403 });
  }
  if (call.status !== "accepted") {
    return new Response(JSON.stringify({ error: "Esta llamada todavía no se ha aceptado" }), { status: 400 });
  }

  // Simétrico a propósito, a diferencia de live-token (host publica,
  // espectador solo se suscribe): en una llamada 1:1 real las dos partes
  // publican y se suscriben por igual, sea de voz o de vídeo -- el propio
  // cliente decide si activa la cámara según `calls.kind`.
  const token = await buildLiveKitJwt({
    apiKey: LIVEKIT_API_KEY,
    apiSecret: LIVEKIT_API_SECRET,
    identity: userId,
    room: call.room_name,
  });

  return new Response(JSON.stringify({ token, wsUrl: LIVEKIT_WS_URL, roomName: call.room_name }), {
    headers: { "content-type": "application/json" },
  });
});

async function buildLiveKitJwt(opts: {
  apiKey: string;
  apiSecret: string;
  identity: string;
  room: string;
}): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: opts.apiKey,
    sub: opts.identity,
    iat: now,
    // 1h -- suficiente para una llamada real, mismo criterio que
    // live-token/buildApnsJwt (send-push/index.ts).
    exp: now + 3600,
    video: {
      room: opts.room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    },
  };
  const encoder = new TextEncoder();
  const signingInput = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(claims)))}`;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(opts.apiSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput));
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

function base64url(bytes: Uint8Array): string {
  let str = "";
  for (const byte of bytes) str += String.fromCharCode(byte);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
