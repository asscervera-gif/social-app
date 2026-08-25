// supabase/functions/live-token/index.ts
//
// "Directo" real (0056_live_streams.sql): mint de un token de acceso real
// de LiveKit (WebRTC), el motor que el usuario eligió (LiveKit Cloud,
// SDKs Apache 2.0 open-source, frente a self-hosted) para no añadir
// infraestructura propia que mantener. Mismo motivo que delete-account
// para ser una Edge Function y no algo hecho desde el cliente: firmar un
// JWT con LIVEKIT_API_SECRET requiere un secreto de servidor que nunca
// puede llegar al cliente (mismo principio que ANTHROPIC_API_KEY en
// duel-ai/APNS_AUTH_KEY_P8 en send-push).
//
// Sin SDK de servidor de LiveKit (no existe uno oficial para Deno/Edge
// Functions) -- el token es un JWT HS256 firmado a mano con Web Crypto,
// igual que buildApnsJwt() en send-push/index.ts construye un JWT ES256 a
// mano para APNs. Formato de claims documentado por LiveKit
// (https://docs.livekit.io/home/get-started/authentication/), no
// inventado: header {alg:"HS256"}, claims {iss, sub, exp, video:{room,
// roomJoin, canPublish, canSubscribe}}.
//
// Autorización real, no confiada al cliente: quién puede publicar (host)
// frente a solo suscribirse (espectador) se decide aquí consultando la
// base de datos con service_role, nunca a partir de un flag que mande el
// propio cliente -- un cliente modificado no puede pedir permiso de
// publicar en el directo de otra persona.
//
// Pendiente real de DESPLIEGUE, no de código (mismo criterio que push/
// APNs-FCM): LIVEKIT_API_KEY/LIVEKIT_API_SECRET/LIVEKIT_WS_URL reales de
// un proyecto LiveKit Cloud, fijados con `supabase secrets set`. Sin
// ellos, esta función responde 500 "mal configurada" -- compila y corre,
// no conecta a ningún servidor real.
//
// Despliegue:
//   supabase functions deploy live-token
//   supabase secrets set LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=... LIVEKIT_WS_URL=wss://...

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

  let streamId: string | undefined;
  try {
    const body = await req.json();
    streamId = body.streamId;
  } catch {
    // sin body válido, streamId queda undefined -> 400 más abajo.
  }
  if (!streamId) {
    return new Response(JSON.stringify({ error: "Falta streamId" }), { status: 400 });
  }

  const { data: stream, error: streamError } = await admin
    .from("live_streams")
    .select("id, host_id, room_name, status")
    .eq("id", streamId)
    .maybeSingle();
  if (streamError || !stream) {
    return new Response(JSON.stringify({ error: "Directo no encontrado" }), { status: 404 });
  }
  if (stream.status !== "live") {
    return new Response(JSON.stringify({ error: "Este directo ya terminó" }), { status: 400 });
  }

  const isHost = stream.host_id === userId;
  if (!isHost) {
    // El cliente debe haberse unido primero con el inserto normal (RLS,
    // 0056_live_streams.sql) -- esa política ya comprueba el bloqueo real
    // contra el host. Este token nunca se emite para quien no pasó ese
    // control real, sea o no host.
    const { data: viewerRow } = await admin
      .from("live_stream_viewers")
      .select("id")
      .eq("stream_id", streamId)
      .eq("viewer_id", userId)
      .maybeSingle();
    if (!viewerRow) {
      return new Response(JSON.stringify({ error: "Únete al directo antes de pedir un token" }), { status: 403 });
    }
  }

  const token = await buildLiveKitJwt({
    apiKey: LIVEKIT_API_KEY,
    apiSecret: LIVEKIT_API_SECRET,
    identity: userId,
    room: stream.room_name,
    canPublish: isHost,
  });

  return new Response(JSON.stringify({ token, wsUrl: LIVEKIT_WS_URL, roomName: stream.room_name }), {
    headers: { "content-type": "application/json" },
  });
});

async function buildLiveKitJwt(opts: {
  apiKey: string;
  apiSecret: string;
  identity: string;
  room: string;
  canPublish: boolean;
}): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: opts.apiKey,
    sub: opts.identity,
    iat: now,
    // 1h -- suficiente para una sesión de directo, mismo criterio de
    // "simple y correcto, aunque no el más eficiente posible" ya usado en
    // buildApnsJwt() de send-push/index.ts.
    exp: now + 3600,
    video: {
      room: opts.room,
      roomJoin: true,
      canPublish: opts.canPublish,
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
