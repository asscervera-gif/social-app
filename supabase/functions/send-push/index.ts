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

interface ProfileMuteRow {
  muted_push_kinds: string[];
}

// Sonido de notificación personalizado por chat, comparado con
// WhatsApp/Telegram/Messenger/Instagram DM -- ver
// 0154_chat_notification_sound.sql.
interface ChatSoundRow {
  user_a_id: string;
  notification_sound_by_a: string | null;
  notification_sound_by_b: string | null;
}

interface GroupMemberSoundRow {
  notification_sound: string | null;
}

interface DeviceTokenRow {
  platform: "ios" | "android";
  token: string;
}

// Mismo texto que AvisosViewModel.kt.icon()/title() — el aviso en la app
// y el push real deben decir lo mismo, no dos redacciones distintas.
//
// Hallazgo real (0047_message_notify_mute.sql): esta es la TERCERA copia
// de este mapeo kind -> texto (junto a AvisosViewModel.swift/.kt) -- al
// añadir "social_accepted"/"compat_accepted" en la pasada anterior
// (0046_notify_accepted.sql) se actualizaron las dos primeras pero se
// olvidó esta, así que un push real para esos dos avisos habría caído en
// el "🔔"/"Notificación" genérico aunque la app ya mostrara el texto
// correcto -- corregido aquí junto con "message" (nuevo esta pasada).
// Hallazgo real (0058_group_message_notify.sql): "comment"/"comment_like"/
// "reel_comment_like" ya estaban en notifications_kind_check desde hace
// varias rondas (0008/0054), pero NUNCA se añadieron a este switch -- un
// push real para esos tres tipos caía siempre en "🔔" genérico aunque la
// base de datos y AvisosViewModel.kt/.swift funcionaran bien. Corregido
// aquí junto con "group_message" (nuevo, 0057_group_chats.sql).
function iconFor(kind: string): string {
  switch (kind) {
    case "social": return "👥";
    case "follow": return "➕";
    case "fight": return "⚡";
    case "like": return "❤";
    case "compat_request": return "%";
    case "social_accepted": return "✅";
    case "compat_accepted": return "%";
    case "message": return "💬";
    // Reels (0050_reels.sql) -- mismos iconos que like/comment normales.
    case "reel_like": return "❤";
    case "reel_comment": return "💬";
    case "comment": return "💬";
    case "comment_like": return "❤";
    case "reel_comment_like": return "❤";
    case "group_message": return "👥";
    // @menciones reales (0074_mentions.sql), comparado con
    // Instagram/Twitter/TikTok.
    case "mention": return "@";
    // Empezar un Directo real, comparado con Instagram/TikTok ("Fulano
    // está en directo ahora") -- ver 0138_live_start_notification.sql.
    case "live_start": return "🔴";
    // Hallazgo real, mismo patrón exacto ya corregido para live_start
    // (Ronda 88): estos cuatro kinds ya insertan filas reales de
    // notificación (0098/0127/0129/0130) pero nunca se mapearon aquí --
    // el push real caía en el "🔔" genérico aunque BD y la app en sí ya
    // llevaran el texto correcto.
    case "new_post": return "📸";
    case "repost": return "🔁";
    case "story_share": return "📤";
    case "screenshot": return "📸";
    case "story_question_response": return "💬";
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
    case "social_accepted": return "Aceptó tu social";
    case "compat_accepted": return "Compartió su compatibilidad contigo";
    case "message": return "Nuevo mensaje";
    case "reel_like": return "Le gustó tu reel";
    case "comment": return "Comentó tu publicación";
    case "comment_like": return "Le gustó tu comentario";
    case "reel_comment_like": return "Le gustó tu comentario";
    case "group_message": return "Nuevo mensaje de grupo";
    case "reel_comment": return "Comentó tu reel";
    case "mention": return "Te mencionó";
    case "live_start": return "Está en directo ahora";
    case "new_post": return "Ha publicado algo nuevo";
    case "repost": return "Reposteó tu publicación";
    case "story_share": return "Compartió tu publicación en su historia";
    case "screenshot": return "Hizo captura de tu conversación";
    case "story_question_response": return "Respondió tu pregunta";
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

  // Preferencias de notificaciones por categoría (0052_notification_prefs.sql),
  // comparado con Instagram/Twitter/Facebook/WhatsApp: antes se enviaba
  // SIEMPRE, para cualquier `kind`, sin ninguna forma de que el usuario
  // apagara una categoría concreta. `select().maybeSingle()` en vez de
  // `.single()`: si el perfil ya no existe (borrado de cuenta en curso),
  // no debe romper el envío, simplemente no hay preferencia que aplicar.
  const { data: profile } = await admin
    .from("profiles")
    .select("muted_push_kinds")
    .eq("id", notification.recipient_id)
    .maybeSingle<ProfileMuteRow>();
  if (profile?.muted_push_kinds?.includes(notification.kind)) {
    return new Response(JSON.stringify({ sent: 0, muted: true }), { headers: { "content-type": "application/json" } });
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

  // Sonido de notificación personalizado por chat, comparado con
  // WhatsApp/Telegram/Messenger/Instagram DM -- ver
  // 0154_chat_notification_sound.sql. "default" si no hay ninguno
  // elegido (mismo comportamiento real que hasta ahora).
  let sound = "default";
  if (notification.kind === "message" && notification.payload.chat_id) {
    const { data: chatRow } = await admin
      .from("chats")
      .select("user_a_id, notification_sound_by_a, notification_sound_by_b")
      .eq("id", notification.payload.chat_id)
      .maybeSingle<ChatSoundRow>();
    if (chatRow) {
      sound = (notification.recipient_id === chatRow.user_a_id ? chatRow.notification_sound_by_a : chatRow.notification_sound_by_b) ?? "default";
    }
  } else if (notification.kind === "group_message" && notification.payload.group_chat_id) {
    const { data: memberRow } = await admin
      .from("group_chat_members")
      .select("notification_sound")
      .eq("group_chat_id", notification.payload.group_chat_id)
      .eq("user_id", notification.recipient_id)
      .maybeSingle<GroupMemberSoundRow>();
    sound = memberRow?.notification_sound ?? "default";
  }

  let sent = 0;
  for (const deviceToken of tokens) {
    const ok = deviceToken.platform === "ios"
      ? await sendAPNs(deviceToken.token, title, bodyText, sound)
      : await sendFCM(deviceToken.token, title, bodyText, sound);
    if (ok) sent++;
  }

  return new Response(JSON.stringify({ sent, total: tokens.length }), {
    headers: { "content-type": "application/json" },
  });
});

async function sendAPNs(deviceToken: string, title: string, body: string, sound = "default"): Promise<boolean> {
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
        aps: { alert: { title, body }, sound },
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

async function sendFCM(deviceToken: string, title: string, body: string, sound = "default"): Promise<boolean> {
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
        // "sound" en FCM legacy nombra un recurso raw empaquetado en la
        // app real (res/raw/<sound>.mp3), mismo campo que "default" ya
        // usaba antes de esta ronda -- ver aviso de honestidad en
        // 0154_chat_notification_sound.sql sobre los assets reales
        // todavía pendientes para los tonos que no sean "default".
        notification: { title, body, sound },
      }),
    });
    return response.ok;
  } catch {
    return false;
  }
}
