// supabase/functions/send-push/index.ts
//
// Hallazgo real, el hueco de infraestructura más grande documentado en
// LOOP_STATE.md ("Pendiente real") y explícitamente citado en
// growth_strategy.md: las notificaciones locales (NotificationsBadgeViewModel/
// LocalNotifier) solo funcionan mientras el proceso de la app sigue vivo.
// Esta función es el envío real — la llama
// notify_push_on_new_notification() (0040_device_tokens_push.sql) vía
// pg_net en cuanto se crea un aviso real, con el mismo texto (título +
// icono) que ya usa la UI en Android (AvisosViewModel.kt.title()/icon()).
//
// Aviso de honestidad, mismo criterio que duel-ai/icebreaker-ai: el CÓDIGO
// es real y sigue el formato documentado de cada API (APNs HTTP/2 con JWT
// ES256, FCM HTTP legacy con clave de servidor) — pero sin credenciales
// reales configuradas, no envía nada de verdad. No se ha podido probar
// contra un dispositivo físico real ni un runtime Deno en este entorno
// (sin Deno disponible aquí, igual que duel-ai). Es la infraestructura
// real completa, no una simulación.
//
// Despliegue real (cuando existan las credenciales):
//   supabase secrets set APNS_TEAM_ID=... APNS_KEY_ID=... APNS_AUTH_KEY_P8="-----BEGIN PRIVATE KEY-----..."
//   supabase secrets set FCM_SERVER_KEY=...
//   supabase functions deploy send-push
//   alter database postgres set app.settings.supabase_url = 'https://TU-PROYECTO.supabase.co';
//   alter database postgres set app.settings.service_role_key = 'TU_SERVICE_ROLE_KEY';
//
// FCM usa la API HTTP legacy (Authorization: key=...), más simple que la
// v1 (que exige OAuth2 de cuenta de servicio, mucho más código para firmar
// JWT RS256 + intercambiar token). Google la sigue soportando a fecha de
// escritura, pero está en proceso de sustitución por v1 — documentado
// aquí como una migración real futura, no fingido como ya resuelto.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID");
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID");
const APNS_AUTH_KEY_P8 = Deno.env.get("APNS_AUTH_KEY_P8");
const FCM_SERVER_KEY = Deno.env.get("FCM_SERVER_KEY");
const APNS_BUNDLE_ID = "com.social.app";
const APNS_HOST = "https://api.push.apple.com";

interface PushRequest {
  notification_id: string;
}

interface NotificationRow {
  id: string;
  recipient_id: string;
  kind: string;
  payload: Record<string, string>;
}

interface DeviceTokenRow {
  platform: "ios" | "android";
  token: string;
}

// Mismo texto que AvisosViewModel.kt.icon()/title() — el aviso en la app
// y el push real deben decir lo mismo, no dos redacciones distintas.
function iconFor(kind: string): string {
  switch (kind) {
    case "social": return "👥";
    case "follow": return "➕";
    case "fight": return "⚡";
    case "like": return "❤";
    case "compat_request": return "%";
    default: return "🔔";
  }
}
function titleFor(kind: string): string {
  switch (kind) {
    case "social": return "Nueva solicitud de social";
    case "follow": return "Nuevo seguidor";
    case "fight": return "Duelo completado";
    case "like": return "Le gustó tu publicación";
    case "compat_request": return "Quiere ver tu compatibilidad";
    default: return "Notificación";
  }
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: "Función mal configurada" }), { status: 500 });
  }

  const body: PushRequest = await req.json();
  if (!body.notification_id) {
    return new Response(JSON.stringify({ error: "Petición inválida" }), { status: 400 });
  }

  // service_role: esta función la invoca el propio trigger de Postgres
  // (pg_net), no un usuario final — no hay JWT de usuario que validar
  // aquí, a diferencia de duel-ai/icebreaker-ai.
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: notification, error: notificationError } = await admin
    .from("notifications")
    .select("id, recipient_id, kind, payload")
    .eq("id", body.notification_id)
    .single<NotificationRow>();
  if (notificationError || !notification) {
    return new Response(JSON.stringify({ error: "Aviso no encontrado" }), { status: 404 });
  }

  const { data: tokens, error: tokensError } = await admin
    .from("device_tokens")
    .select("platform, token")
    .eq("profile_id", notification.recipient_id)
    .returns<DeviceTokenRow[]>();
  if (tokensError || !tokens || tokens.length === 0) {
    // Sin tokens registrados (el usuario nunca abrió la app en un
    // dispositivo con push configurado, o los rechazó) — no es un error,
    // simplemente no hay nada que enviar.
    return new Response(JSON.stringify({ sent: 0 }), { headers: { "content-type": "application/json" } });
  }

  const title = titleFor(notification.kind);
  const bodyText = `${iconFor(notification.kind)} Toca para verlo`;

  let sent = 0;
  for (const deviceToken of tokens) {
    const ok = deviceToken.platform === "ios"
      ? await sendAPNs(deviceToken.token, title, bodyText)
      : await sendFCM(deviceToken.token, title, bodyText);
    if (ok) sent++;
  }

  return new Response(JSON.stringify({ sent, total: tokens.length }), {
    headers: { "content-type": "application/json" },
  });
});

async function sendAPNs(deviceToken: string, title: string, body: string): Promise<boolean> {
  if (!APNS_TEAM_ID || !APNS_KEY_ID || !APNS_AUTH_KEY_P8) return false;
  try {
    const jwt = await buildApnsJwt();
    const response = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: JSON.stringify({
        aps: { alert: { title, body }, sound: "default" },
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}

// JWT ES256 firmado con la clave .p8 real — formato documentado por Apple
// (https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
// Se genera uno nuevo por llamada (Apple permite reutilizar hasta 1h, pero
// esta función es sin estado entre invocaciones — simple y correcto,
// aunque no el más eficiente posible).
async function buildApnsJwt(): Promise<string> {
  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const claims = { iss: APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) };
  const encoder = new TextEncoder();
  const signingInput = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(claims)))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(APNS_AUTH_KEY_P8!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  // Web Crypto devuelve la firma ECDSA en formato IEEE P1363 (r||s), que
  // es exactamente el formato que espera un JWS ES256 — sin conversión
  // DER adicional.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput)
  );
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const clean = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function base64url(bytes: Uint8Array): string {
  let str = "";
  for (const byte of bytes) str += String.fromCharCode(byte);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sendFCM(deviceToken: string, title: string, body: string): Promise<boolean> {
  if (!FCM_SERVER_KEY) return false;
  try {
    const response = await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        "Authorization": `key=${FCM_SERVER_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        to: deviceToken,
        notification: { title, body },
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}
