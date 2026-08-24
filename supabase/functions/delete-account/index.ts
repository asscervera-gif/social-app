// supabase/functions/delete-account/index.ts
//
// Hallazgo real documentado en LOOP_STATE.md: la política de privacidad
// prometía "borrado completo de tu perfil... desde Ajustes", pero no existía
// ningún mecanismo de borrado de cuenta en ninguna plataforma ni en el
// backend — un bloqueante legal real (RGPD/CCPA exigen un derecho al olvido
// real antes de poder afirmarlo publicado). Se construye aquí la pieza que
// faltaba.
//
// Por qué una Edge Function y no un delete directo desde el cliente:
// borrar la cuenta de verdad significa borrar la fila de `auth.users`, no
// solo `profiles` — eso requiere la Admin API de Supabase Auth
// (`auth.admin.deleteUser`), que solo funciona con la service_role key,
// nunca expuesta al cliente (mismo principio que `duel-ai` protegiendo
// ANTHROPIC_API_KEY). Al borrar `auth.users`, `profiles.id` tiene
// `references auth.users(id) on delete cascade` (0001_schema.sql), y cada
// tabla dependiente de `profiles` tiene a su vez `on delete cascade` (o
// `on delete set null` para columnas como `notifications.actor_id`) — así
// que un solo borrado en cascada real limpia todo: posts, likes, comments,
// saved_posts, socials, chats, messages, duels, etc.
//
// Despliegue:
//   supabase functions deploy delete-account

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: "Función mal configurada" }), { status: 500 });
  }

  // El JWT del usuario llega en el header Authorization; se decodifica con
  // el cliente admin para identificar de forma fiable a QUIÉN se borra —
  // nunca se acepta un user_id del body, así que nadie puede borrar la
  // cuenta de otra persona pidiéndolo desde un cliente modificado.
  const authHeader = req.headers.get("Authorization") ?? "";
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: userData, error: userError } = await admin.auth.getUser(
    authHeader.replace("Bearer ", "")
  );
  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ error: "No autenticado" }), { status: 401 });
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userData.user.id);
  if (deleteError) {
    return new Response(JSON.stringify({ error: "No se pudo borrar la cuenta", detail: deleteError.message }), {
      status: 500,
    });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    headers: { "content-type": "application/json" },
  });
});
