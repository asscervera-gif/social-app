import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';

const MIGRATIONS_DIR = process.argv[2];
const db = new PGlite();

async function setupStubs() {
  await db.exec(`
    do $$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
      if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
    end $$;
    create schema if not exists auth;
    create table if not exists auth.users (
      id uuid primary key default gen_random_uuid(),
      email text,
      raw_user_meta_data jsonb not null default '{}'
    );
    -- A diferencia de run_migrations.mjs/test_triggers.mjs (auth.uid()
    -- fijo a null, suficiente para probar triggers que no dependen de
    -- quién ejecuta la sentencia), aquí SÍ hace falta que auth.uid()
    -- refleje un usuario real distinto en cada prueba — mismo mecanismo
    -- que usa Supabase de verdad (GUC de sesión con el JWT), simplificado
    -- a una sola variable de texto.
    create or replace function auth.uid() returns uuid
      language sql stable as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;
    create or replace function auth.role() returns text
      language sql stable as $$ select coalesce(nullif(current_setting('app.role', true), ''), 'authenticated') $$;
    create or replace function uuid_generate_v4() returns uuid
      language sql as $$ select gen_random_uuid() $$;
    create schema if not exists private;
    create schema if not exists storage;
    create table if not exists storage.buckets (id text primary key, name text not null, public boolean not null default false);
    create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
    create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
      select case when array_length(regexp_split_to_array(name, '/'), 1) > 1
        then (regexp_split_to_array(name, '/'))[1:array_length(regexp_split_to_array(name, '/'), 1) - 1]
        else array[]::text[] end
    $$;
  `);
}

function stripUnavailableExtension(sql) {
  return sql.replace(/create extension if not exists "uuid-ossp";?/gi, '-- stub');
}

async function applyMigrations() {
  const files = fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
  for (const file of files) {
    const sql = stripUnavailableExtension(fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'));
    await db.exec(sql);
  }
}

async function grantSupabaseDefaults() {
  // Lo que un proyecto Supabase real concede automáticamente al crear el
  // proyecto (fuera de cualquier migración de usuario) — sin esto, ni
  // siquiera se llega a evaluar RLS: Postgres deniega antes por falta de
  // privilegio a nivel de tabla.
  await db.exec(`
    grant usage on schema public to anon, authenticated, service_role;
    grant all on all tables in schema public to anon, authenticated, service_role;
    grant all on all sequences in schema public to anon, authenticated, service_role;
    alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  `);
}

async function asUser(userId) {
  await db.query(`set role authenticated`);
  await db.query(`select set_config('app.uid', $1, false)`, [userId]);
  await db.query(`select set_config('app.role', 'authenticated', false)`);
}

async function asSuperuser() {
  await db.query(`reset role`);
  await db.query(`select set_config('app.uid', '', false)`);
  // El superusuario de esta sesión de prueba hace las veces del backend
  // con `service_role` (el único que debe poder tocar columnas
  // protegidas como is_verified/is_admin) — sin esto, `auth.role()`
  // seguiría devolviendo 'authenticated' incluso aquí, y las
  // protecciones revertirían también las escrituras que SÍ deberían
  // pasar.
  await db.query(`select set_config('app.role', 'service_role', false)`);
}

let allPassed = true;
function check(label, condition) {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${label}`);
  if (!condition) allPassed = false;
  return condition;
}

async function expectFail(label, fn) {
  try {
    await fn();
    check(label, false);
  } catch (e) {
    check(label, true);
  }
}

async function expectOk(label, fn) {
  try {
    await fn();
    check(label, true);
  } catch (e) {
    console.log(`   (motivo del fallo inesperado: ${e.message})`);
    check(label, false);
  }
}

async function main() {
  await setupStubs();
  await applyMigrations();
  await grantSupabaseDefaults();
  console.log('--- migraciones + privilegios de Supabase aplicados, empiezan las pruebas de RLS reales ---\n');

  await asSuperuser();
  const u1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`
    insert into profiles (id, display_name) values ($1, 'Uno'), ($2, 'Dos')
    on conflict (id) do update set display_name = excluded.display_name
  `, [u1, u2]);
  const chat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [u1, u2])).rows[0];

  // --- messages_insert (0013): sin bloqueo, u2 SÍ puede escribir en el chat ---
  await asUser(u2);
  await expectOk('messages_insert: sin bloqueo, u2 SÍ puede enviar un mensaje', async () => {
    await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'hola')`, [chat.id, u2]);
  });

  // --- Ahora u1 bloquea a u2 ---
  await asUser(u1);
  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [u1, u2]);

  // --- messages_insert (0013): CON bloqueo, u2 YA NO puede escribir ---
  await asUser(u2);
  await expectFail('messages_insert: bloqueado, u2 YA NO puede enviar un mensaje (RLS real)', async () => {
    await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'sigo aquí')`, [chat.id, u2]);
  });

  // --- message_reactions_insert (0025): con bloqueo, tampoco puede reaccionar ---
  await asSuperuser();
  const msgRow = (await db.query(`select id from messages where chat_id = $1 limit 1`, [chat.id])).rows[0];
  await asUser(u2);
  await expectFail('message_reactions_insert: bloqueado, u2 tampoco puede reaccionar', async () => {
    await db.query(`insert into message_reactions (message_id, chat_id, user_id, emoji) values ($1, $2, $3, '❤')`, [msgRow.id, chat.id, u2]);
  });

  // --- compatibility_votes_insert (0027): con bloqueo, tampoco puede votar ---
  await expectFail('compatibility_votes_insert: bloqueado, u2 tampoco puede votar compatibilidad', async () => {
    await db.query(`insert into compatibility_votes (chat_id, voter_id, delta) values ($1, $2, 10)`, [chat.id, u2]);
  });

  // --- compat_requests_insert (0011): con bloqueo, u2 no puede pedir ver el % de u1 ---
  await expectFail('compat_requests_insert: bloqueado, u2 no puede solicitar compatibilidad a u1', async () => {
    await db.query(`insert into compat_requests (requester_id, target_id) values ($1, $2)`, [u2, u1]);
  });

  // --- duels_insert (0035): NADIE puede insertar directo, ni siquiera sin bloqueo ---
  await expectFail('duels_insert: revocado por completo, ni el propio cliente puede insertar', async () => {
    await db.query(`insert into duels (chat_id, initiator_id, opponent_id, questions, answers) values ($1, $2, $3, '[]', '[]')`, [chat.id, u2, u1]);
  });

  // --- socials_update (0002): solo el destinatario puede aceptar, no quien lo pide ---
  await asSuperuser();
  const social = (await db.query(`insert into socials (requester_id, addressee_id, status) values ($1, $2, 'pending') returning id`, [u1, u2])).rows[0];
  await asUser(u1);
  // Nota real de Postgres: un UPDATE bloqueado por RLS no lanza excepción
  // — simplemente afecta 0 filas (no hay fila que la política deje ver
  // para actualizar). Hay que comprobar el resultado, no esperar un
  // throw como en el INSERT bloqueado por WITH CHECK de más arriba.
  await db.query(`update socials set status = 'accepted' where id = $1`, [social.id]);
  await asSuperuser();
  const stillPending = (await db.query(`select status from socials where id = $1`, [social.id])).rows[0];
  check('socials_update: quien PIDE el social no puede autoaceptarlo (0 filas afectadas por RLS)', stillPending.status === 'pending');
  await asUser(u2);
  await expectOk('socials_update: el DESTINATARIO real sí puede aceptarlo', async () => {
    await db.query(`update socials set status = 'accepted' where id = $1`, [social.id]);
  });

  // --- posts_select / profile_sections_select (0002): un tercero sin
  // relación NO ve un post/sección "solo socials", pero SÍ los ve quien
  // tiene un social aceptado real (u2, ya aceptado más arriba) ---
  await asSuperuser();
  const u3 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1, 'Tres') on conflict (id) do nothing`, [u3]);
  await asUser(u2);
  const socialOnlyPost = (await db.query(
    `insert into posts (author_id, caption, is_social_only) values ($1, 'solo para socials', true) returning id`, [u2]
  )).rows[0];
  await db.query(`insert into profile_sections (profile_id, section_key, content, is_public) values ($1, 'trabajo', '{"texto":"secreto"}', false)`, [u2]);

  await asUser(u3);
  const postAsStranger = (await db.query(`select id from posts where id = $1`, [socialOnlyPost.id])).rows;
  const sectionAsStranger = (await db.query(`select 1 from profile_sections where profile_id = $1`, [u2])).rows;
  check('posts_select: un tercero sin social NO ve un post "solo socials"', postAsStranger.length === 0);
  check('profile_sections_select: un tercero sin social NO ve una sección privada', sectionAsStranger.length === 0);

  // (u1 ya tiene el social aceptado con u2 desde la prueba de socials_update de más arriba)
  await asUser(u1);
  const postAsSocial = (await db.query(`select id from posts where id = $1`, [socialOnlyPost.id])).rows;
  check('posts_select: el social aceptado real SÍ ve el post "solo socials"', postAsSocial.length === 1);

  // --- likes_insert_own (0012): bloqueado no puede dar like al post de quien lo bloqueó ---
  await asUser(u2);
  await expectFail('likes_insert_own: bloqueado (u2 fue bloqueado por u1) no puede dar like al post de u1', async () => {
    await db.query(`insert into likes (post_id, user_id) values ($1, $2)`, [post.id, u2]);
  });

  // --- Moderación real (0036): is_admin no autoconcedible, denuncias
  // solo visibles/gestionables por un admin real ---
  await asUser(u3);
  await db.query(`insert into reports (reporter_id, reported_id, reason) values ($1, $2, 'spam')`, [u3, u2]);
  // Igual que is_verified (protect_is_verified): el trigger revierte en
  // silencio, no lanza excepción — el UPDATE "tiene éxito" (RLS de
  // profiles_update_own sí deja tocar la propia fila) pero la columna
  // protegida se queda igual. Hay que comprobar el valor, no esperar un throw.
  await db.query(`update profiles set is_admin = true where id = $1`, [u3]);
  await asSuperuser();
  const u3Profile = (await db.query(`select is_admin from profiles where id = $1`, [u3])).rows[0];
  check('protect_is_admin: u3 no puede autoconcederse is_admin (revertido por el trigger)', u3Profile.is_admin === false);
  await asUser(u3);
  const reportsAsNonAdmin = (await db.query(`select 1 from reports`)).rows;
  check('reports_select_admin: un usuario normal no ve ninguna denuncia', reportsAsNonAdmin.length === 0);

  await asSuperuser();
  await db.query(`update profiles set is_admin = true where id = $1`, [u3]);
  await asUser(u3);
  const reportsAsAdmin = (await db.query(`select 1 from reports`)).rows;
  check('reports_select_admin: un admin real SÍ ve las denuncias', reportsAsAdmin.length > 0);
  await db.query(`update reports set status = 'reviewed' where reporter_id = $1`, [u3]);
  await asSuperuser();
  const reportRow = (await db.query(`select status from reports where reporter_id = $1`, [u3])).rows[0];
  check('reports_update_admin: un admin real SÍ puede marcar una denuncia como revisada', reportRow.status === 'reviewed');

  // --- admin_ban_user (0037): solo un admin real puede banear, y el
  // baneo se refleja en my_ban_status (la vista que consulta el cliente
  // al arrancar) ---
  await asUser(u2); // u2 no es admin
  await expectFail('admin_ban_user: un usuario normal (no admin) no puede banear a nadie', async () => {
    await db.query(`select admin_ban_user($1, true, null, 'spam repetido')`, [u3]);
  });

  await asUser(u3); // u3 SÍ es admin (concedido más arriba)
  await expectOk('admin_ban_user: un admin real SÍ puede banear a otro usuario', async () => {
    await db.query(`select admin_ban_user($1, true, null, 'spam repetido')`, [u2]);
  });

  await asUser(u2);
  const banStatus = (await db.query(`select is_currently_banned, ban_reason from my_ban_status`)).rows[0];
  check('my_ban_status: el usuario baneado ve is_currently_banned = true con su motivo real', banStatus.is_currently_banned === true && banStatus.ban_reason === 'spam repetido');

  // Igual que protect_is_admin más arriba: el UPDATE en sí "tiene éxito"
  // (profiles_update_own deja tocar la propia fila), el trigger revierte
  // la columna protegida en silencio sin lanzar excepción — se comprueba
  // el valor resultante, no un throw.
  await db.query(`update profiles set is_banned = false where id = $1`, [u2]);
  await asSuperuser();
  const stillBanned = (await db.query(`select is_banned from profiles where id = $1`, [u2])).rows[0];
  check('protect_ban_columns: is_banned sigue en true tras el intento de auto-desbaneo (revertido en silencio, no lanza)', stillBanned.is_banned === true);

  await asUser(u3);
  await expectOk('admin_ban_user: el mismo admin SÍ puede desbanear después', async () => {
    await db.query(`select admin_ban_user($1, false, null, null)`, [u2]);
  });
  await asUser(u2);
  const unbanStatus = (await db.query(`select is_currently_banned from my_ban_status`)).rows[0];
  check('my_ban_status: tras el desbaneo real, is_currently_banned vuelve a false', unbanStatus.is_currently_banned === false);

  // Baneo temporal ya caducado: is_banned sigue en true en crudo, pero
  // my_ban_status debe reportarlo como YA NO baneado — esto es lo que
  // impide que un usuario quede baneado para siempre por un bug de
  // "olvido de desbanear" tras un baneo temporal.
  await asUser(u3);
  await db.query(`select admin_ban_user($1, true, now() - interval '1 hour', 'baneo ya caducado')`, [u2]);
  await asUser(u2);
  const expiredBan = (await db.query(`select is_currently_banned from my_ban_status`)).rows[0];
  check('my_ban_status: un baneo temporal ya caducado NO cuenta como baneo activo', expiredBan.is_currently_banned === false);

  // --- ban_appeals (0043): un usuario baneado puede apelar la decisión
  // (su propia sesión de Auth sigue siendo válida -- el baneo no revoca
  // el JWT, solo gatea la UI y revierte columnas de perfil), solo puede
  // ver/insertar SU propia apelación, y solo un admin real puede leer y
  // resolver todas -- mismo patrón exacto que reports (0036). u2 sigue
  // baneado desde el bloque de arriba (baneo temporal ya caducado no
  // cuenta como activo para my_ban_status, pero la fila is_banned=true
  // sigue ahí, que es lo único que RLS necesita para dejar insertar).
  await asUser(u2);
  await expectFail('ban_appeals_insert_own: u2 no puede insertar una apelación a nombre de otro perfil', async () => {
    await db.query(`insert into ban_appeals (profile_id, message) values ($1, 'no es mía')`, [u3]);
  });
  const appeal = (await db.query(
    `insert into ban_appeals (profile_id, message) values ($1, 'Creo que fue un error, no envié spam.') returning id`,
    [u2]
  )).rows[0];
  const ownAppeal = (await db.query(`select id from ban_appeals where id = $1`, [appeal.id])).rows;
  check('ban_appeals_select_own: u2 SÍ ve su propia apelación', ownAppeal.length === 1);

  await asUser(u1);
  const appealAsStranger = (await db.query(`select id from ban_appeals where id = $1`, [appeal.id])).rows;
  check('ban_appeals_select_own: un tercero (u1, no admin, no dueño) NO ve la apelación de u2 (RLS real, no solo filtro de cliente)', appealAsStranger.length === 0);

  await asUser(u3); // u3 sigue siendo admin desde el bloque de moderación de más arriba
  const appealAsAdmin = (await db.query(`select id from ban_appeals where id = $1`, [appeal.id])).rows;
  check('ban_appeals_select_admin: un admin real SÍ ve la apelación de otro usuario', appealAsAdmin.length === 1);
  await db.query(`update ban_appeals set status = 'reviewed' where id = $1`, [appeal.id]);
  await asSuperuser();
  const appealRow = (await db.query(`select status from ban_appeals where id = $1`, [appeal.id])).rows[0];
  check('ban_appeals_update_admin: un admin real SÍ puede marcar una apelación como revisada', appealRow.status === 'reviewed');

  // --- event_attendees_insert_own (0030): no se puede unirse a un evento
  // con un social_count ya inflado, cierra el hueco de falsear el
  // ranking desde el propio INSERT ---
  await asSuperuser();
  const event2 = (await db.query(
    `insert into events (name, starts_at, ends_at, venue_lat, venue_lng) values ('Otra fiesta', now() - interval '1 hour', now() + interval '1 hour', 0, 0) returning id`
  )).rows[0];
  await asUser(u3);
  await expectFail('event_attendees_insert_own: no se puede unirse con social_count ya inflado', async () => {
    await db.query(`insert into event_attendees (event_id, profile_id, social_count) values ($1, $2, 999)`, [event2.id, u3]);
  });
  await expectOk('event_attendees_insert_own: unirse con social_count = 0 (el real) SÍ funciona', async () => {
    await db.query(`insert into event_attendees (event_id, profile_id, social_count) values ($1, $2, 0)`, [event2.id, u3]);
  });

  // --- follows_delete (0026): el hallazgo más severo de esa pasada —
  // "dejar de seguir" llevaba desde su construcción sin ninguna política
  // de borrado, así que el DELETE nunca afectaba ninguna fila de verdad.
  // Primera vez que se confirma con un DELETE real, no solo con la
  // migración aplicando limpio. ---
  await asUser(u3);
  await db.query(`insert into follows (follower_id, followee_id) values ($1, $2)`, [u3, u1]);
  await db.query(`delete from follows where follower_id = $1 and followee_id = $2`, [u3, u1]);
  await asSuperuser();
  const followGone = (await db.query(`select 1 from follows where follower_id = $1 and followee_id = $2`, [u3, u1])).rows;
  check('follows_delete: dejar de seguir SÍ borra la fila de verdad', followGone.length === 0);

  // --- device_tokens (0040): registro de token de dispositivo para push
  // real — cada quien gestiona solo el suyo, nunca el de otro. Primera
  // vez que se prueba con RLS real, no solo la migración aplicando
  // limpio (la parte del trigger con pg_net, 0041, no es verificable en
  // este harness — PGlite no trae esa extensión, documentado en la
  // propia migración). ---
  await asUser(u2);
  await expectOk('device_tokens_insert_own: u2 SÍ puede registrar su propio token', async () => {
    await db.query(`insert into device_tokens (profile_id, platform, token) values ($1, 'ios', 'tok-u2-real')`, [u2]);
  });
  await expectFail('device_tokens_insert_own: u2 NO puede registrar un token a nombre de u3', async () => {
    await db.query(`insert into device_tokens (profile_id, platform, token) values ($1, 'ios', 'tok-fraud')`, [u3]);
  });

  await asUser(u3);
  await db.query(`insert into device_tokens (profile_id, platform, token) values ($1, 'android', 'tok-u3-real')`, [u3]);
  const u3SeesOwnToken = (await db.query(`select 1 from device_tokens where profile_id = $1`, [u3])).rows;
  check('device_tokens_select_own: u3 SÍ ve su propio token', u3SeesOwnToken.length === 1);
  const u3SeesU2Token = (await db.query(`select 1 from device_tokens where profile_id = $1`, [u2])).rows;
  check('device_tokens_select_own: u3 NO ve el token de u2 (RLS real, no solo un filtro de cliente)', u3SeesU2Token.length === 0);

  await db.query(`delete from device_tokens where profile_id = $1`, [u3]);
  await asSuperuser();
  const u3TokenGone = (await db.query(`select 1 from device_tokens where profile_id = $1`, [u3])).rows;
  check('device_tokens_delete_own: borrar el propio token SÍ borra la fila de verdad', u3TokenGone.length === 0);

  // --- chats_hide (0044): ocultar una conversación de "Tus chats" solo
  // afecta a la copia de quien la oculta, nunca a la de la otra persona
  // (RLS por fila no lo impediría por sí sola -- hace falta el trigger),
  // y un mensaje nuevo real la restaura sola, sin quedar oculta para
  // siempre. `chat` es user_a_id=u1, user_b_id=u2 (creado más arriba).
  // service_role (representado aquí por el superusuario de la sesión de
  // prueba, ver comentario de asSuperuser()) puede tocar cualquier
  // columna directamente -- un soporte/admin interno real, no solo un
  // caso límite. De paso dispara la primera evaluación real de
  // `auth.uid()` dentro del trigger en esta sesión (ver nota de robustez
  // de pruebas en 0044_chats_hide.sql sobre el orden del AND) para que
  // las comprobaciones de más abajo, bajo el rol `authenticated` real de
  // u2, no dependan de qué prueba se ejecutó primero.
  await asSuperuser();
  await db.query(`update chats set hidden_by_a = true, hidden_by_b = true where id = $1`, [chat.id]);
  const hiddenByService = (await db.query(`select hidden_by_a, hidden_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_hidden_flags: service_role SÍ puede tocar cualquiera de las dos copias directamente', hiddenByService.hidden_by_a === true && hiddenByService.hidden_by_b === true);
  await db.query(`update chats set hidden_by_a = false, hidden_by_b = false where id = $1`, [chat.id]);

  await asUser(u2); // u2 es user_b_id del chat
  await db.query(`update chats set hidden_by_b = true where id = $1`, [chat.id]);
  await asSuperuser();
  const hiddenByB = (await db.query(`select hidden_by_a, hidden_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_hidden_flags: u2 (user_b) SÍ puede ocultar su propia copia', hiddenByB.hidden_by_b === true && hiddenByB.hidden_by_a === false);

  // Igual que protect_ban_columns/protect_is_verified: el UPDATE en sí
  // "tiene éxito" (chats_update ya deja tocar la fila), el trigger
  // revierte en silencio la columna ajena, no lanza excepción.
  await asUser(u2);
  await db.query(`update chats set hidden_by_a = true where id = $1`, [chat.id]);
  await asSuperuser();
  const stillNotHiddenByA = (await db.query(`select hidden_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_hidden_flags: u2 NO puede ocultar la copia de u1 (revertido en silencio, no lanza)', stillNotHiddenByA.hidden_by_a === false);

  // u1 bloqueó a u2 en el bloque de messages_insert de más arriba -- un
  // bloqueo activo impide mensajes en AMBAS direcciones (private.is_blocked
  // es bidireccional), así que hay que desbloquear primero para poder
  // probar el mensaje nuevo real. blocks_delete_own (0003_safety.sql) es
  // el "desbloquear" real, mismo mecanismo que usaría el cliente.
  await asUser(u1);
  await db.query(`delete from blocks where blocker_id = $1 and blocked_id = $2`, [u1, u2]);
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'un mensaje nuevo de verdad')`, [chat.id, u1]);
  await asSuperuser();
  const unhiddenAfterMessage = (await db.query(`select hidden_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('unhide_chat_on_new_message: un mensaje nuevo real deshace el ocultado de u2, no se pierde de la vista', unhiddenAfterMessage.hidden_by_b === false);

  // --- Borrado de cuenta (delete-account): borrar auth.users debe
  // cascadear de verdad hasta profiles y todo lo dependiente — esto es
  // justo lo que la Edge Function hace con service_role, nunca probado
  // contra un motor real hasta esta pasada.
  await asSuperuser();
  await db.query(`delete from auth.users where id = $1`, [u1]);
  const profileGone = (await db.query(`select 1 from profiles where id = $1`, [u1])).rows;
  const chatGone = (await db.query(`select 1 from chats where id = $1`, [chat.id])).rows;
  const socialGone = (await db.query(`select 1 from socials where id = $1`, [social.id])).rows;
  check('delete-account: borrar auth.users cascada de verdad a profiles', profileGone.length === 0);
  check('delete-account: borrar auth.users cascada de verdad a chats', chatGone.length === 0);
  check('delete-account: borrar auth.users cascada de verdad a socials', socialGone.length === 0);

  console.log('\n--- fin de las pruebas de RLS ---');
  if (!allPassed) process.exitCode = 1;
}

main().catch(e => { console.error('ERROR INESPERADO:', e.message); process.exit(1); });
