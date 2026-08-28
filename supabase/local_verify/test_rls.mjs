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

// Hallazgo real de esta pasada, en el propio arnés de pruebas (no en el
// esquema): `0041_notify_push_trigger.sql` ya documentaba desde que se
// escribió (commit `9043388`, 2026-08-25) que `create extension pg_net`
// "no es verificable en PGlite", pero `applyMigrations()` nunca se
// actualizó para saltárselo -- a diferencia de uuid-ossp (sí stubbeado
// aquí desde el principio), pg_net lanzaba una excepción sin capturar que
// tumbaba el `for` de golpe. Confirmado reproduciendo el fallo contra el
// HEAD real del repo (`git stash` + reejecución), no solo en esta rama de
// trabajo: CUALQUIER ejecución de este arnés desde que se aplicó 0041
// termina en "ERROR INESPERADO: extension pg_net is not available" antes
// de correr ni un solo `check()` -- ninguno de los recuentos "local X/X"
// documentados en LOOP_STATE.md para rondas posteriores a 0041 pudo salir
// de ejecutar este archivo tal cual estaba committeado. Mismo criterio que
// uuid-ossp: stub de la sentencia, sin tocar el resto de la migración.
function stripUnavailableExtension(sql) {
  return sql
    .replace(/create extension if not exists "uuid-ossp";?/gi, '-- stub')
    .replace(/create extension if not exists pg_net(\s+with schema \w+)?;?/gi, '-- stub (pg_net no disponible en PGlite, ver 0041_notify_push_trigger.sql)');
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

  // --- trg_notify_social_accepted (0046): quien PIDIÓ el social (u1) recibe
  // un aviso real de que u2 lo aceptó -- antes nadie lo notificaba nunca. ---
  await asUser(u1);
  const socialAcceptedNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'social_accepted'`, [u1]
  )).rows;
  check('trg_notify_social_accepted: u1 (requester) recibe el aviso real al aceptar u2', socialAcceptedNotif.length === 1);
  check('trg_notify_social_accepted: actor_id es quien aceptó (u2), no quien pidió', socialAcceptedNotif[0]?.actor_id === u2);
  check('trg_notify_social_accepted: payload trae el social_id real', socialAcceptedNotif[0]?.payload?.social_id === social.id);

  // --- socials_delete (0020), aplicado a cancelar una solicitud pendiente
  // ENVIADA (feature nueva, SocialsListView "Solicitudes enviadas"): la
  // política no distingue por status, así que quien la pidió debe poder
  // borrar su propia solicitud todavía pendiente -- sin test hasta ahora. ---
  await asSuperuser();
  const pendingToCancel = (await db.query(
    `insert into socials (requester_id, addressee_id, status) values ($1, $2, 'pending') returning id`, [u2, u1]
  )).rows[0];
  await asUser(u2);
  await expectOk('socials_delete: quien PIDIÓ un social todavía pendiente SÍ puede cancelarlo', async () => {
    await db.query(`delete from socials where id = $1`, [pendingToCancel.id]);
  });
  await asSuperuser();
  const cancelledGone = (await db.query(`select 1 from socials where id = $1`, [pendingToCancel.id])).rows;
  check('socials_delete: la solicitud cancelada ya no existe de verdad', cancelledGone.length === 0);

  // --- posts_select / profile_sections_select (0002): un tercero sin
  // relación NO ve un post/sección "solo socials", pero SÍ los ve quien
  // tiene un social aceptado real (u2, ya aceptado más arriba) ---
  await asSuperuser();
  const u3 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1, 'Tres') on conflict (id) do nothing`, [u3]);

  // --- trg_notify_compat_accepted (0046): mismo hueco que socials, en
  // compat_requests -- quien pidió ver el % (u3) no recibía ningún aviso
  // real cuando el dueño (u1) lo aceptaba. ---
  await asSuperuser();
  const compatReq = (await db.query(
    `insert into compat_requests (requester_id, target_id, status) values ($1, $2, 'pending') returning id`, [u3, u1]
  )).rows[0];
  await asUser(u1);
  await expectOk('compat_requests_update: el DUEÑO real (target) sí puede aceptar la solicitud', async () => {
    await db.query(`update compat_requests set status = 'accepted' where id = $1`, [compatReq.id]);
  });
  await asUser(u3);
  const compatAcceptedNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'compat_accepted'`, [u3]
  )).rows;
  check('trg_notify_compat_accepted: u3 (requester) recibe el aviso real al aceptar u1', compatAcceptedNotif.length === 1);
  check('trg_notify_compat_accepted: actor_id es quien aceptó (u1), no quien pidió', compatAcceptedNotif[0]?.actor_id === u1);
  check('trg_notify_compat_accepted: payload trae el compat_request_id real', compatAcceptedNotif[0]?.payload?.compat_request_id === compatReq.id);

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
  //
  // Hallazgo real de robustez del propio arnés de pruebas: esta prueba
  // referenciaba una variable `post` que NUNCA se declaraba en todo el
  // archivo -- pasaba en verde solo porque expectFail() traga CUALQUIER
  // excepción (línea 95-102), incluido el ReferenceError de la variable
  // inexistente, sin haber llegado a ejecutar jamás el INSERT real que
  // dice verificar. Arreglado creando el post real de u1 antes de la
  // prueba, para que el fallo capturado sea de verdad el bloqueo de RLS,
  // no un bug del propio test.
  await asUser(u1);
  const post = (await db.query(`insert into posts (author_id, caption) values ($1, 'post real de u1') returning id`, [u1])).rows[0];
  await asUser(u2);
  await expectFail('likes_insert_own: bloqueado (u2 fue bloqueado por u1) no puede dar like al post de u1', async () => {
    await db.query(`insert into likes (post_id, user_id) values ($1, $2)`, [post.id, u2]);
  });

  // --- posts_write_own (0002_rls.sql) es "for all": editar el caption de
  // la propia publicación ya estaba permitido a nivel de RLS, pero sin
  // ningún test hasta ahora -- comparado con Instagram: poder editar un
  // caption ya publicado, no solo borrarlo entero (MyPostsView.editCaption()). ---
  await asUser(u1);
  await expectOk('posts_write_own: el AUTOR real SÍ puede editar el caption de su propia publicación', async () => {
    await db.query(`update posts set caption = 'caption editado de verdad' where id = $1`, [post.id]);
  });
  await asUser(u2);
  await db.query(`update posts set caption = 'intento ajeno' where id = $1`, [post.id]);
  await asSuperuser();
  const postAfterForeignEditAttempt = (await db.query(`select caption from posts where id = $1`, [post.id])).rows[0];
  check('posts_write_own: un tercero (u2, no autor) NO puede editar el caption ajeno (0 filas afectadas por RLS)', postAfterForeignEditAttempt.caption === 'caption editado de verdad');

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

  // --- reports.post_id (0045): referencia real al contenido denunciado,
  // no solo un id suelto en un campo de texto editable -- comparado con
  // Instagram/TikTok/Facebook. u3 sigue siendo admin desde el bloque de
  // arriba. `socialOnlyPost` (de u2, creado más arriba) sirve de contenido
  // real a referenciar.
  await asUser(u3);
  const contentReport = (await db.query(
    `insert into reports (reporter_id, reported_id, reason, post_id) values ($1, $2, 'contenido ofensivo', $3) returning id`,
    [u3, u2, socialOnlyPost.id]
  )).rows[0];
  const contentReportAsAdmin = (await db.query(`select post_id from reports where id = $1`, [contentReport.id])).rows[0];
  check('reports.post_id: un admin real ve la referencia al post denunciado de verdad, no solo texto suelto', contentReportAsAdmin.post_id === socialOnlyPost.id);

  // posts_select_admin/comments_select_admin (0045): sin esto, la
  // referencia de arriba sería decorativa para el caso más delicado --
  // `socialOnlyPost` es "solo socials" de u2, y u3 NO tiene ningún social
  // con u2 en todo este archivo de pruebas (el único social real es
  // u1<->u2, más arriba) -- si u3 pudiera verlo de todos modos, es
  // gracias EXCLUSIVAMENTE al bypass de admin nuevo, no a una conexión
  // social real.
  const socialOnlyPostAsAdmin = (await db.query(`select caption from posts where id = $1`, [socialOnlyPost.id])).rows;
  check('posts_select_admin: un admin real SÍ puede revisar un post "solo socials" ajeno sin tener social con el autor', socialOnlyPostAsAdmin.length === 1);

  // Si el post se borra después de denunciarse, la denuncia sigue
  // existiendo para el historial de moderación -- solo pierde la
  // referencia (on delete set null, no cascade).
  await asUser(u2);
  await db.query(`delete from posts where id = $1`, [socialOnlyPost.id]);
  await asUser(u3);
  const contentReportAfterPostDeleted = (await db.query(`select post_id from reports where id = $1`, [contentReport.id])).rows[0];
  check('reports.post_id: borrar el post después SÍ pone la referencia a null, sin borrar la denuncia (on delete set null)', contentReportAfterPostDeleted !== undefined && contentReportAfterPostDeleted.post_id === null);

  // --- reports.message_id (0048): mismo hueco exacto que post_id/
  // comment_id, pero en un chat -- comparado con Instagram/WhatsApp/
  // Messenger. `chat` (u1<->u2) ya tiene mensajes reales de más arriba
  // (messages_insert); u1 sigue bloqueado por u2 en este punto del
  // archivo (el desbloqueo real ocurre más abajo), así que el mensaje de
  // prueba se inserta con el superusuario -- lo que se está probando es
  // la visibilidad del ADMIN, no el envío en sí.
  await asSuperuser();
  const messageToReport = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje real a denunciar') returning id`, [chat.id, u2]
  )).rows[0];
  await asUser(u3);
  const messageReport = (await db.query(
    `insert into reports (reporter_id, reported_id, reason, message_id) values ($1, $2, 'acoso', $3) returning id`,
    [u3, u2, messageToReport.id]
  )).rows[0];
  const messageReportAsAdmin = (await db.query(`select message_id from reports where id = $1`, [messageReport.id])).rows[0];
  check('reports.message_id: un admin real ve la referencia al mensaje denunciado de verdad, no solo texto suelto', messageReportAsAdmin.message_id === messageToReport.id);

  // messages_select_admin (0048): a diferencia de posts_select_admin/
  // comments_select_admin (bypass GENERAL para cualquier admin), aquí es
  // deliberadamente más estrecho -- u3 (admin) no tiene ningún social con
  // u1/u2 ni es participante del chat, así que solo puede ver el mensaje
  // PORQUE está referenciado por una denuncia real, nunca por ser admin
  // en general (un chat es la superficie más privada de la app).
  const messageAsAdmin = (await db.query(`select body from messages where id = $1`, [messageToReport.id])).rows;
  check('messages_select_admin: un admin real SÍ ve el mensaje concreto denunciado', messageAsAdmin.length === 1 && messageAsAdmin[0].body === 'mensaje real a denunciar');

  // El mensaje "hola" de u2 (messages_insert, más arriba) NUNCA se
  // denunció -- un admin NO debe poder verlo solo por ser admin, a
  // diferencia de un post/comentario cualquiera (bypass acotado, no general).
  const undenouncedMessageAsAdmin = (await db.query(`select 1 from messages where chat_id = $1 and body = 'hola'`, [chat.id])).rows;
  check('messages_select_admin: un admin real NO ve un mensaje del mismo chat que nunca se denunció', undenouncedMessageAsAdmin.length === 0);

  // Si el mensaje se borra después de denunciarse, la denuncia sigue
  // existiendo para el historial -- solo pierde la referencia (on delete
  // set null, no cascade). Lo borra u2, el remitente real
  // (messages_delete_own, sin relación con el bloqueo activo de u1).
  await asUser(u2);
  await db.query(`delete from messages where id = $1`, [messageToReport.id]);
  await asUser(u3);
  const messageReportAfterDeleted = (await db.query(`select message_id from reports where id = $1`, [messageReport.id])).rows[0];
  check('reports.message_id: borrar el mensaje después SÍ pone la referencia a null, sin borrar la denuncia (on delete set null)', messageReportAfterDeleted !== undefined && messageReportAfterDeleted.message_id === null);

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

  // --- follows_delete_by_followee (0092_remove_follower.sql): eliminar
  // un seguidor real, comparado con Instagram/Twitter/Facebook -- quien
  // ES seguido también puede borrar esa fila, no solo el propio seguidor
  // (0026, arriba). Reutiliza u3 siguiendo a u1 otra vez. ---
  await asSuperuser();
  await db.query(`insert into follows (follower_id, followee_id) values ($1, $2)`, [u3, u1]);

  await asUser(u2);
  await db.query(`delete from follows where follower_id = $1 and followee_id = $2`, [u3, u1]);
  await asSuperuser();
  const followStillThereAfterStranger = (await db.query(`select 1 from follows where follower_id = $1 and followee_id = $2`, [u3, u1])).rows;
  check('follows_delete_by_followee: un tercero real (u2), que no es ni el seguidor ni el seguido, NO puede borrar esa relación (0 filas afectadas, no un error)', followStillThereAfterStranger.length === 1);

  await asUser(u1);
  await expectOk('follows_delete_by_followee: u1 real (a quien sigue u3) SÍ puede eliminarlo como seguidor', async () => {
    await db.query(`delete from follows where follower_id = $1 and followee_id = $2`, [u3, u1]);
  });
  await asSuperuser();
  const followGoneByFollowee = (await db.query(`select 1 from follows where follower_id = $1 and followee_id = $2`, [u3, u1])).rows;
  check('follows_delete_by_followee: la fila real queda borrada de verdad', followGoneByFollowee.length === 0);

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

  // --- notify_new_device_login (0152_new_device_alert.sql): aviso real
  // de nuevo inicio de sesión, comparado con Instagram/Facebook/
  // Snapchat -- disparado por un INSERT real en device_tokens (nunca un
  // UPDATE del mismo upsert), nunca el de otra persona. ---
  await asUser(u2);
  const newDeviceNotif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'new_device_login'`, [u2])).rows;
  check('notify_new_device_login: u2 recibe el aviso real al registrar su token real la primera vez', newDeviceNotif.length === 1 && newDeviceNotif[0].payload.platform === 'ios');

  await expectOk('device_tokens: u2 SÍ puede re-registrar el MISMO token real (upsert, no un INSERT nuevo)', async () => {
    await db.query(
      `insert into device_tokens (profile_id, platform, token) values ($1, 'ios', 'tok-u2-real') on conflict (profile_id, platform, token) do update set updated_at = now()`,
      [u2]
    );
  });
  const newDeviceNotifAfterUpsert = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'new_device_login'`, [u2])).rows;
  check('notify_new_device_login: re-registrar el MISMO dispositivo real (upsert) NO genera un segundo aviso', newDeviceNotifAfterUpsert.length === 1);

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

  // --- notify_new_message (0047): un mensaje nuevo real SÍ genera un
  // aviso real para el destinatario -- el hueco de mensajería más grande
  // de la sesión, antes NINGÚN mensaje generaba nunca un aviso (ni badge,
  // ni notificación local, ni push real). ---
  await asUser(u2);
  const messageNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'message'`, [u2]
  )).rows;
  check('notify_new_message: u2 (destinatario real) recibe el aviso del mensaje de u1', messageNotif.length === 1);
  check('notify_new_message: actor_id es quien mandó el mensaje (u1)', messageNotif[0]?.actor_id === u1);
  check('notify_new_message: payload trae el chat_id real', messageNotif[0]?.payload?.chat_id === chat.id);

  // --- protect_chat_muted_flags / silenciar (0047): mismo patrón exacto
  // que protect_chat_hidden_flags -- cada quien solo silencia SU PROPIA
  // copia, nunca la de la otra persona. ---
  await asUser(u2); // u2 es user_b_id del chat
  await db.query(`update chats set muted_by_b = true where id = $1`, [chat.id]);
  await asSuperuser();
  const mutedByB = (await db.query(`select muted_by_a, muted_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_muted_flags: u2 (user_b) SÍ silencia su propia copia', mutedByB.muted_by_b === true && mutedByB.muted_by_a === false);

  await asUser(u2);
  await db.query(`update chats set muted_by_a = true where id = $1`, [chat.id]);
  await asSuperuser();
  const stillNotMutedByA = (await db.query(`select muted_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_muted_flags: u2 NO puede silenciar la copia de u1 (revertido en silencio, no lanza)', stillNotMutedByA.muted_by_a === false);

  // --- silenciado SÍ suprime el aviso de mensajes nuevos, sin bloquear
  // ni ocultar nada (u2 ya silenció su propia copia justo arriba). ---
  await asUser(u1);
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'otro mensaje, u2 ya silenció')`, [chat.id, u1]);
  await asUser(u2);
  const messageNotifAfterMute = (await db.query(
    `select 1 from notifications where recipient_id = $1 and kind = 'message'`, [u2]
  )).rows;
  check('notify_new_message: silenciado por u2, el segundo mensaje NO genera un aviso nuevo (sigue habiendo solo 1)', messageNotifAfterMute.length === 1);

  // --- muted_until_a/b (0082_mute_until.sql): silenciar temporalmente
  // con expiración real, comparado con WhatsApp/Telegram -- mismo
  // criterio que profiles.banned_until: null = para siempre, una fecha
  // real ya pasada deja de contar como silenciado sin que nadie tenga
  // que revertir el flag a mano. u2 sigue con muted_by_b = true desde el
  // bloque de arriba. ---
  await asUser(u2);
  await db.query(`update chats set muted_until_a = now() where id = $1`, [chat.id]);
  await asSuperuser();
  const stillNotMutedUntilA = (await db.query(`select muted_until_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_muted_flags: u2 NO puede tocar la fecha de expiración real de u1 (revertido en silencio, no lanza)', stillNotMutedUntilA.muted_until_a === null);

  await asUser(u2);
  await db.query(`update chats set muted_until_b = now() - interval '1 hour' where id = $1`, [chat.id]);
  await asUser(u1);
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'silencio real ya caducado')`, [chat.id, u1]);
  await asUser(u2);
  const notifAfterExpiredMute = (await db.query(`select 1 from notifications where recipient_id = $1 and kind = 'message'`, [u2])).rows;
  check('notify_new_message: un silencio real ya caducado (muted_until_b en el pasado) SÍ vuelve a generar aviso', notifAfterExpiredMute.length === 2);

  await asUser(u2);
  await db.query(`update chats set muted_until_b = now() + interval '1 hour' where id = $1`, [chat.id]);
  await asUser(u1);
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'silencio real todavía vigente')`, [chat.id, u1]);
  await asUser(u2);
  const notifStillMuted = (await db.query(`select 1 from notifications where recipient_id = $1 and kind = 'message'`, [u2])).rows;
  check('notify_new_message: un silencio real todavía vigente (muted_until_b en el futuro) SIGUE sin generar aviso', notifStillMuted.length === 2);

  // --- messages_update_own / protect_message_columns (0049): un mensaje
  // mal escrito solo se podía borrar entero, nunca corregir -- comparado
  // con WhatsApp/Telegram/Messenger. De paso, hallazgo de seguridad real
  // encontrado escribiendo este mismo test: messages_update_read (0017)
  // ya dejaba a CUALQUIER destinatario tocar `body` (RLS combina
  // políticas por fila, no por columna) -- protect_message_columns lo
  // cierra revirtiendo en silencio, mismo patrón que
  // protect_chat_hidden_flags/protect_chat_muted_flags. ---
  await asSuperuser();
  const messageToEdit = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje con una errata') returning id`, [chat.id, u1]
  )).rows[0];
  // Nota de robustez de pruebas (no de producción, ver 0044_chats_hide.sql):
  // primera evaluación real de auth.uid() dentro de ESTA función de
  // trigger concreta (protect_message_columns, plan propio) en la
  // sesión -- un toque de service_role primero la "calienta", mismo
  // mecanismo ya documentado y usado para protect_chat_hidden_flags.
  await db.query(`update messages set edited_at = null where id = $1`, [messageToEdit.id]);
  await asUser(u1);
  await expectOk('messages_update_own: el REMITENTE real SÍ puede editar su propio mensaje', async () => {
    await db.query(`update messages set body = 'mensaje corregido de verdad', edited_at = now() where id = $1`, [messageToEdit.id]);
  });
  // u2 puede seguir marcando read_at como destinatario real (0017, sin
  // cambios) -- protect_message_columns no debe romper el caso legítimo.
  await asUser(u2);
  await expectOk('messages_update_read: el DESTINATARIO real sigue pudiendo marcar como leído tras 0049', async () => {
    await db.query(`update messages set read_at = now() where id = $1`, [messageToEdit.id]);
  });
  // El intento de u2 de tocar body a la vez que read_at "tiene éxito"
  // (chats_update ya deja tocar la fila), pero protect_message_columns
  // revierte body/media_url/audio_url/edited_at en silencio -- mismo
  // criterio que protect_ban_columns/protect_chat_hidden_flags.
  await asUser(u2);
  await db.query(`update messages set body = 'intento ajeno', read_at = now() where id = $1`, [messageToEdit.id]);
  await asSuperuser();
  const messageAfterForeignEditAttempt = (await db.query(`select body from messages where id = $1`, [messageToEdit.id])).rows[0];
  check('protect_message_columns: un tercero (u2, no remitente) NO puede editar el mensaje ajeno (revertido en silencio, no lanza)', messageAfterForeignEditAttempt.body === 'mensaje corregido de verdad');

  // El propio remitente tampoco debe poder mentirse sobre si SU mensaje
  // fue leído -- por consistencia, aunque el impacto real sea cosmético.
  await asUser(u1);
  await db.query(`update messages set read_at = now() where id = $1`, [messageToEdit.id]);
  await asSuperuser();
  const messageAfterSenderFakeRead = (await db.query(`select read_at from messages where id = $1`, [messageToEdit.id])).rows[0];
  check('protect_message_columns: el remitente NO puede fijar read_at de su propio mensaje (sigue siendo el de u2, no null)', messageAfterSenderFakeRead.read_at !== null);

  // --- reels (0050): primer hueco real del proyecto grande "Reels + En
  // directo" pedido explícitamente por el usuario ("lo quiero exactamente
  // igual" al boceto SOCIAL_APP.html). Mismo esquema exacto que
  // posts/likes/comments, incluida la protección de bloqueo aplicada desde
  // el principio (0012_block_enforcement_posts.sql), no como hallazgo
  // dormido aparte. ---
  await asUser(u3);
  const publicReel = (await db.query(
    `insert into reels (author_id, video_url, caption) values ($1, 'https://media/u3/reel1.mp4', 'reel público de u3') returning id`, [u3]
  )).rows[0];
  const socialOnlyReel = (await db.query(
    `insert into reels (author_id, video_url, caption, is_social_only) values ($1, 'https://media/u3/reel2.mp4', 'reel solo socials de u3', true) returning id`, [u3]
  )).rows[0];

  // reels_select: u2 (sin ningún social con u3) SÍ ve el público, NO ve el social-only.
  await asUser(u2);
  const publicReelAsStranger = (await db.query(`select id from reels where id = $1`, [publicReel.id])).rows;
  const socialReelAsStranger = (await db.query(`select id from reels where id = $1`, [socialOnlyReel.id])).rows;
  check('reels_select: un tercero sin social SÍ ve el reel público de otro', publicReelAsStranger.length === 1);
  check('reels_select: un tercero sin social NO ve el reel "solo socials" de otro', socialReelAsStranger.length === 0);

  // reel_likes_insert_own + sync_reel_like_count + notify_new_reel_like:
  // u2 da like al reel público de u3 -- contador sube y u3 recibe el aviso real.
  await expectOk('reel_likes_insert_own: sin bloqueo, u2 SÍ puede dar like al reel público de u3', async () => {
    await db.query(`insert into reel_likes (reel_id, user_id) values ($1, $2)`, [publicReel.id, u2]);
  });
  await asSuperuser();
  const reelAfterLike = (await db.query(`select like_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('sync_reel_like_count: like_count real sube a 1 tras el insert', reelAfterLike.like_count === 1);
  await asUser(u3);
  const reelLikeNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'reel_like'`, [u3]
  )).rows;
  check('notify_new_reel_like: u3 (autor) recibe el aviso real del like de u2', reelLikeNotif.length === 1);
  check('notify_new_reel_like: actor_id es quien dio like (u2)', reelLikeNotif[0]?.actor_id === u2);
  check('notify_new_reel_like: payload trae el reel_id real', reelLikeNotif[0]?.payload?.reel_id === publicReel.id);

  // reel_comments_insert_own + sync_reel_comment_count + notify_new_reel_comment.
  await asUser(u2);
  const reelComment = (await db.query(
    `insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'buen reel') returning id`, [publicReel.id, u2]
  )).rows[0];
  await asSuperuser();
  const reelAfterComment = (await db.query(`select comment_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('sync_reel_comment_count: comment_count real sube a 1 tras el insert', reelAfterComment.comment_count === 1);
  await asUser(u3);
  const reelCommentNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'reel_comment'`, [u3]
  )).rows;
  check('notify_new_reel_comment: u3 (autor) recibe el aviso real del comentario de u2', reelCommentNotif.length === 1);
  check('notify_new_reel_comment: payload trae el comment_id real', reelCommentNotif[0]?.payload?.comment_id === reelComment.id);

  // protect_reel_counts: el propio autor no puede inflar sus contadores a mano.
  await asUser(u3);
  await db.query(`update reels set like_count = 999, caption = 'editado de verdad' where id = $1`, [publicReel.id]);
  await asSuperuser();
  const reelAfterFakeCount = (await db.query(`select like_count, caption from reels where id = $1`, [publicReel.id])).rows[0];
  check('protect_reel_counts: like_count NO se puede fijar a mano (sigue siendo 1, el real)', reelAfterFakeCount.like_count === 1);
  check('protect_reel_counts: el resto de la fila (caption) sí se actualiza con normalidad', reelAfterFakeCount.caption === 'editado de verdad');

  // reel_views (0131_reel_view_count.sql): contador real de vistas,
  // comparado con TikTok/Instagram Reels -- ver hallazgo real en la
  // propia migración (view_count llevaba desde 0050 sin forma real de
  // incrementarse, RLS lo bloqueaba).
  await asUser(u2);
  await expectOk('reel_views_insert_own: un espectador real (u2, no autor) SÍ puede registrar su propia vista', async () => {
    await db.query(`insert into reel_views (reel_id, viewer_id) values ($1, $2)`, [publicReel.id, u2]);
  });
  await asSuperuser();
  const reelAfterView = (await db.query(`select view_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('sync_reel_view_count: view_count real sube a 1 tras la vista real', reelAfterView.view_count === 1);

  await asUser(u3);
  await db.query(`insert into reel_views (reel_id, viewer_id) values ($1, $2)`, [publicReel.id, u3]);
  await asSuperuser();
  const reelAfterAuthorView = (await db.query(`select view_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('sync_reel_view_count: el propio autor real (u3) viendo su propio reel NO infla el contador (sigue en 1)', reelAfterAuthorView.view_count === 1);

  await asUser(u2);
  await expectFail('reel_views_insert_own: unique(reel_id, viewer_id) -- u2 NO puede registrar dos vistas del mismo reel', async () => {
    await db.query(`insert into reel_views (reel_id, viewer_id) values ($1, $2)`, [publicReel.id, u2]);
  });
  await asSuperuser();
  const reelAfterDuplicateView = (await db.query(`select view_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('sync_reel_view_count: una segunda vista real del mismo espectador NO infla el contador (sigue en 1)', reelAfterDuplicateView.view_count === 1);

  await asUser(u3);
  await db.query(`update reels set view_count = 999 where id = $1`, [publicReel.id]);
  await asSuperuser();
  const reelAfterDirectAttempt = (await db.query(`select view_count from reels where id = $1`, [publicReel.id])).rows[0];
  check('protect_reel_counts: el propio autor real (u3) con un UPDATE directo (sin pasar por reel_views) sigue revertido -- view_count sigue en 1', reelAfterDirectAttempt.view_count === 1);

  // reel_likes_insert_own con bloqueo: u1 bloquea a u3, u1 ya NO puede dar
  // like al reel de u3 (mismo criterio real que likes_insert_own/0012).
  await asUser(u1);
  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2) on conflict do nothing`, [u1, u3]);
  await expectFail('reel_likes_insert_own: bloqueado (u1 bloqueó a u3), u1 no puede dar like al reel de u3', async () => {
    await db.query(`insert into reel_likes (reel_id, user_id) values ($1, $2)`, [publicReel.id, u1]);
  });

  // --- story_views (0053_story_views.sql): "quién vio tu historia",
  // comparado con Instagram/Snapchat/WhatsApp Status -- solo el AUTOR
  // puede ver la lista de espectadores, ni siquiera el propio espectador
  // ve una lista de "ya vista por ti". ---
  await asUser(u3);
  const story = (await db.query(
    `insert into stories (author_id, media_url) values ($1, 'https://media/u3/story.jpg') returning id`, [u3]
  )).rows[0];
  await asUser(u2);
  await expectOk('story_views_insert_own: u2 SÍ puede registrar que vio la historia de u3', async () => {
    await db.query(`insert into story_views (story_id, viewer_id) values ($1, $2)`, [story.id, u2]);
  });
  await asUser(u3);
  const viewsAsAuthor = (await db.query(`select viewer_id from story_views where story_id = $1`, [story.id])).rows;
  check('story_views_select_own_story: el AUTOR real (u3) SÍ ve quién vio su historia', viewsAsAuthor.length === 1 && viewsAsAuthor[0].viewer_id === u2);
  await asUser(u1);
  const viewsAsStranger = (await db.query(`select viewer_id from story_views where story_id = $1`, [story.id])).rows;
  check('story_views_select_own_story: un tercero (u1, no autor) NO ve quién vio la historia de u3', viewsAsStranger.length === 0);

  // --- comment_likes (0054_comment_likes.sql): dar like a un comentario
  // concreto, comparado con Instagram/Twitter/Facebook -- antes solo se
  // podía dar like a la publicación entera, no a un comentario suyo.
  // Post nuevo de u2 (no de u1: para este punto del archivo u1 ya está
  // bloqueado con u2 Y con u3, así que un post suyo no serviría para
  // probar el caso SIN bloqueo). ---
  await asUser(u2);
  const post2 = (await db.query(`insert into posts (author_id, caption) values ($1, 'post real de u2') returning id`, [u2])).rows[0];
  await asUser(u3);
  const comment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'comentario real de u3') returning id`, [post2.id, u3]
  )).rows[0];
  await expectOk('comment_likes_insert_own: sin bloqueo, u2 SÍ puede dar like al comentario de u3', async () => {
    await asUser(u2);
    await db.query(`insert into comment_likes (comment_id, user_id) values ($1, $2)`, [comment.id, u2]);
  });
  await asSuperuser();
  const commentAfterLike = (await db.query(`select like_count from comments where id = $1`, [comment.id])).rows[0];
  check('sync_comment_like_count: like_count real sube a 1 tras el insert', commentAfterLike.like_count === 1);
  await asUser(u3);
  const commentLikeNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'comment_like'`, [u3]
  )).rows;
  check('notify_new_comment_like: u3 (autor del comentario) recibe el aviso real del like de u2', commentLikeNotif.length === 1);
  check('notify_new_comment_like: actor_id es quien dio like (u2)', commentLikeNotif[0]?.actor_id === u2);
  check('notify_new_comment_like: payload trae el comment_id real', commentLikeNotif[0]?.payload?.comment_id === comment.id);
  // Hallazgo real (0070_notify_comment_like_post_reference.sql), comparado
  // con Instagram/Twitter/Facebook: a diferencia de like/comment (que sí
  // llevan post_id desde el principio), comment_like solo llevaba
  // comment_id -- sin dato con el que abrir la publicación real al tocar
  // el aviso, sin una consulta extra en cada tap.
  check('notify_new_comment_like: payload trae el post_id real (0070)', commentLikeNotif[0]?.payload?.post_id === post2.id);

  // comment_likes_insert_own con bloqueo: u1 y u3 ya están bloqueados entre
  // sí (bloqueo insertado en la sección de reel_likes de más arriba) --
  // u1 no puede dar like al comentario de u3.
  await asUser(u1);
  await expectFail('comment_likes_insert_own: bloqueado (u1 y u3 se bloquearon), u1 no puede dar like al comentario de u3', async () => {
    await db.query(`insert into comment_likes (comment_id, user_id) values ($1, $2)`, [comment.id, u1]);
  });

  // --- reel_comment_likes (0054_comment_likes.sql): mismo patrón, para
  // comentarios de reels. Reutiliza `reelComment` (autor u2, en el reel
  // público de u3) creado en la sección de reel_comments de más arriba. ---
  await expectOk('reel_comment_likes_insert_own: sin bloqueo, u3 SÍ puede dar like al comentario de u2', async () => {
    await asUser(u3);
    await db.query(`insert into reel_comment_likes (reel_comment_id, user_id) values ($1, $2)`, [reelComment.id, u3]);
  });
  await asSuperuser();
  const reelCommentAfterLike = (await db.query(`select like_count from reel_comments where id = $1`, [reelComment.id])).rows[0];
  check('sync_reel_comment_like_count: like_count real sube a 1 tras el insert', reelCommentAfterLike.like_count === 1);
  await asUser(u2);
  const reelCommentLikeNotif = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'reel_comment_like'`, [u2]
  )).rows;
  check('notify_new_reel_comment_like: u2 (autor del comentario) recibe el aviso real del like de u3', reelCommentLikeNotif.length === 1);
  check('notify_new_reel_comment_like: actor_id es quien dio like (u3)', reelCommentLikeNotif[0]?.actor_id === u3);
  check('notify_new_reel_comment_like: payload trae el reel_comment_id real', reelCommentLikeNotif[0]?.payload?.reel_comment_id === reelComment.id);
  // Mismo hallazgo real que comment_like (0070_notify_comment_like_post_reference.sql).
  check('notify_new_reel_comment_like: payload trae el reel_id real (0070)', reelCommentLikeNotif[0]?.payload?.reel_id === publicReel.id);

  // reel_comment_likes_insert_own con bloqueo: el único bloqueo vigente a
  // esta altura del archivo es u1-u3 (el bloqueo u1-u2 de la sección de
  // mensajes se BORRÓ de verdad más arriba, línea ~555, al probar
  // blocks_delete_own) -- se crea un comentario propio de u3 en su reel
  // público para poder probar el bloqueo real contra su autor.
  await asUser(u3);
  const ownReelComment = (await db.query(
    `insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'comentario de u3 en su propio reel') returning id`, [publicReel.id, u3]
  )).rows[0];
  await asUser(u1);
  await expectFail('reel_comment_likes_insert_own: bloqueado (u1 y u3 se bloquearon), u1 no puede dar like al comentario de u3', async () => {
    await db.query(`insert into reel_comment_likes (reel_comment_id, user_id) values ($1, $2)`, [ownReelComment.id, u1]);
  });

  // --- post_media (0055_post_media.sql): publicaciones con varias fotos,
  // comparado con Instagram/Facebook -- posts.media_url sigue siendo la
  // PRIMERA foto (o la única, para posts de antes de esta migración),
  // post_media guarda solo las adicionales. A diferencia de comment_likes,
  // no hay comprobación de bloqueo: el autor añade fotos a SU PROPIA
  // publicación, no interactúa con contenido ajeno -- solo importa la
  // autoría real, reutilizando `post2` (post real de u2 de la sección de
  // comment_likes de más arriba). ---
  await asUser(u2);
  const extraPhoto = (await db.query(
    `insert into post_media (post_id, media_url, position) values ($1, 'https://media/u2/post2-extra.jpg', 1) returning id`, [post2.id]
  )).rows[0];
  await expectOk('post_media_insert_own: el AUTOR real (u2) SÍ puede añadir una foto extra a su propio post', async () => {
    await db.query(`insert into post_media (post_id, media_url, position) values ($1, 'https://media/u2/post2-extra2.jpg', 2)`, [post2.id]);
  });
  await asUser(u3);
  await expectFail('post_media_insert_own: un tercero (u3, no autor) NO puede añadir una foto al post de u2', async () => {
    await db.query(`insert into post_media (post_id, media_url, position) values ($1, 'https://media/intruso.jpg', 3)`, [post2.id]);
  });
  const extraPhotoAsStranger = (await db.query(`select id from post_media where id = $1`, [extraPhoto.id])).rows;
  check('post_media_select: un tercero sin social SÍ ve la foto extra de un post público', extraPhotoAsStranger.length === 1);
  await asUser(u2);
  // `socialOnlyPost` (declarado más arriba) ya no sirve para esto: se
  // borró de verdad en la sección de reports.post_id (línea ~338, prueba
  // de "on delete set null") -- se crea uno nuevo, todavía vivo, para
  // probar la visibilidad real de post_media contra un post "solo socials".
  const freshSocialOnlyPost = (await db.query(
    `insert into posts (author_id, caption, is_social_only) values ($1, 'otro solo para socials', true) returning id`, [u2]
  )).rows[0];
  const socialOnlyExtraPhoto = (await db.query(
    `insert into post_media (post_id, media_url, position) values ($1, 'https://media/u2/social-only-extra.jpg', 1) returning id`, [freshSocialOnlyPost.id]
  )).rows[0];
  await asUser(u3);
  const socialOnlyExtraPhotoAsStranger = (await db.query(`select id from post_media where id = $1`, [socialOnlyExtraPhoto.id])).rows;
  check('post_media_select: un tercero sin social NO ve la foto extra de un post "solo socials"', socialOnlyExtraPhotoAsStranger.length === 0);

  // --- live_streams / live_stream_viewers (0056_live_streams.sql):
  // "Directo" real por primera vez, comparado con Instagram/TikTok Live.
  // Ronda de backend (mismo orden que Reels): tabla + RLS + contador de
  // espectadores real, cliente LiveKit pendiente de una ronda aparte. ---
  await asUser(u3);
  const liveStream = (await db.query(
    `insert into live_streams (host_id, title) values ($1, 'directo público de u3') returning id`, [u3]
  )).rows[0];
  await expectOk('live_stream_viewers_insert_own: sin bloqueo, u2 SÍ puede unirse al directo de u3', async () => {
    await asUser(u2);
    await db.query(`insert into live_stream_viewers (stream_id, viewer_id) values ($1, $2)`, [liveStream.id, u2]);
  });
  await asSuperuser();
  const streamAfterJoin = (await db.query(`select viewer_count from live_streams where id = $1`, [liveStream.id])).rows[0];
  check('sync_live_stream_viewer_count: viewer_count real sube a 1 tras unirse', streamAfterJoin.viewer_count === 1);
  await asUser(u3);
  const viewersAsHost = (await db.query(`select viewer_id from live_stream_viewers where stream_id = $1`, [liveStream.id])).rows;
  check('live_stream_viewers_select_own_stream: el HOST real (u3) SÍ ve quién está viendo su directo', viewersAsHost.length === 1 && viewersAsHost[0].viewer_id === u2);
  // Aviso de espectador solo ve SU PROPIA fila (nunca la lista completa
  // ajena) -- imprescindible además de correcto: en Postgres, DELETE/
  // UPDATE solo pueden operar sobre filas que la propia fila también deje
  // ver por SELECT, así que sin este "viewer_id = auth.uid()" en la
  // política de SELECT, ningún espectador podría salir nunca de un
  // directo (ver más abajo, hallazgo real de este mismo arnés de pruebas).
  await asUser(u1);
  const viewersAsStranger = (await db.query(`select viewer_id from live_stream_viewers where stream_id = $1`, [liveStream.id])).rows;
  check('live_stream_viewers_select_own_stream: un tercero (u1, no host, no espectador) NO ve la fila de u2', viewersAsStranger.length === 0);
  await expectFail('live_stream_viewers_insert_own: bloqueado (u1 y u3 se bloquearon), u1 no puede unirse al directo de u3', async () => {
    await db.query(`insert into live_stream_viewers (stream_id, viewer_id) values ($1, $2)`, [liveStream.id, u1]);
  });

  // protect_live_stream_viewer_count: ni el propio host puede inflar el
  // contador a mano (mismo criterio que protect_reel_counts, 0050_reels.sql).
  await asUser(u3);
  await db.query(`update live_streams set viewer_count = 999, title = 'título editado de verdad' where id = $1`, [liveStream.id]);
  await asSuperuser();
  const streamAfterFakeCount = (await db.query(`select viewer_count, title from live_streams where id = $1`, [liveStream.id])).rows[0];
  check('protect_live_stream_viewer_count: viewer_count NO se puede fijar a mano (sigue siendo 1, el real)', streamAfterFakeCount.viewer_count === 1);
  check('protect_live_stream_viewer_count: el resto de la fila (title) sí se actualiza con normalidad', streamAfterFakeCount.title === 'título editado de verdad');

  // Espectador SÍ ve su PROPIA fila (necesario para poder encontrarla y
  // borrarla al salir) sin que eso le deje ver la lista completa ajena.
  await asUser(u2);
  const ownViewerRow = (await db.query(`select viewer_id from live_stream_viewers where stream_id = $1`, [liveStream.id])).rows;
  check('live_stream_viewers_select_own_stream: el propio espectador (u2) SÍ ve su propia fila', ownViewerRow.length === 1 && ownViewerRow[0].viewer_id === u2);

  // Salir del directo real SÍ borra la fila y baja el contador de verdad.
  await expectOk('live_stream_viewers_delete_own: u2 SÍ puede borrar su propia fila al salir del directo', async () => {
    await db.query(`delete from live_stream_viewers where stream_id = $1 and viewer_id = $2`, [liveStream.id, u2]);
  });
  await asSuperuser();
  const streamAfterLeave = (await db.query(`select viewer_count from live_streams where id = $1`, [liveStream.id])).rows[0];
  check('sync_live_stream_viewer_count: viewer_count real baja a 0 al salir del directo', streamAfterLeave.viewer_count === 0);

  // live_streams_select: mismo criterio de visibilidad que posts_select/
  // reels_select -- un directo "solo socials" de u2 SÍ lo ve u1 (social
  // aceptado real con u2 desde el principio del archivo), NO lo ve u3
  // (sin ningún social con u2).
  await asUser(u2);
  const socialOnlyStream = (await db.query(
    `insert into live_streams (host_id, title, is_social_only) values ($1, 'directo solo socials de u2', true) returning id`, [u2]
  )).rows[0];
  await asUser(u1);
  const socialOnlyStreamAsSocial = (await db.query(`select id from live_streams where id = $1`, [socialOnlyStream.id])).rows;
  check('live_streams_select: el social aceptado real (u1) SÍ ve el directo "solo socials" de u2', socialOnlyStreamAsSocial.length === 1);
  await asUser(u3);
  const socialOnlyStreamAsStranger = (await db.query(`select id from live_streams where id = $1`, [socialOnlyStream.id])).rows;
  check('live_streams_select: un tercero sin social (u3) NO ve el directo "solo socials" de u2', socialOnlyStreamAsStranger.length === 0);

  // --- live_stream_messages (0059_live_stream_messages.sql): chat en vivo
  // real durante un directo, comparado con Instagram/TikTok Live. Mismo
  // criterio de visibilidad que la propia fila `live_streams`. ---
  await expectOk('live_stream_messages_insert: sin bloqueo, u2 SÍ puede escribir en el chat del directo público de u3', async () => {
    await asUser(u2);
    await db.query(`insert into live_stream_messages (stream_id, sender_id, body) values ($1, $2, 'hola desde el chat')`, [liveStream.id, u2]);
  });
  await asUser(u3);
  const liveChatAsHost = (await db.query(`select body from live_stream_messages where stream_id = $1`, [liveStream.id])).rows;
  check('live_stream_messages_select: el HOST real (u3) SÍ ve el mensaje real de u2', liveChatAsHost.length === 1 && liveChatAsHost[0].body === 'hola desde el chat');
  await asUser(u1);
  const liveChatAsBlockedStranger = (await db.query(`select body from live_stream_messages where stream_id = $1`, [liveStream.id])).rows;
  check('live_stream_messages_select: un tercero bloqueado con el host (u1) SÍ ve el chat -- el bloqueo no afecta a la visibilidad, igual que posts/reels', liveChatAsBlockedStranger.length === 1);
  await expectFail('live_stream_messages_insert: bloqueado (u1 y u3 se bloquearon), u1 no puede escribir en el chat del directo de u3', async () => {
    await db.query(`insert into live_stream_messages (stream_id, sender_id, body) values ($1, $2, 'intento bloqueado')`, [liveStream.id, u1]);
  });

  // Mismo criterio "solo socials" que live_streams_select: u1 (social
  // aceptado con u2) SÍ puede escribir/leer, u3 (sin social) NO.
  await asUser(u1);
  await expectOk('live_stream_messages_insert: el social aceptado real (u1) SÍ puede escribir en el chat del directo "solo socials" de u2', async () => {
    await db.query(`insert into live_stream_messages (stream_id, sender_id, body) values ($1, $2, 'hola u2')`, [socialOnlyStream.id, u1]);
  });
  await asUser(u3);
  await expectFail('live_stream_messages_insert: un tercero sin social (u3) no puede escribir en el chat del directo "solo socials" de u2', async () => {
    await db.query(`insert into live_stream_messages (stream_id, sender_id, body) values ($1, $2, 'intento ajeno')`, [socialOnlyStream.id, u3]);
  });
  const liveChatSocialOnlyAsStranger = (await db.query(`select id from live_stream_messages where stream_id = $1`, [socialOnlyStream.id])).rows;
  check('live_stream_messages_select: un tercero sin social (u3) NO ve el chat del directo "solo socials" de u2', liveChatSocialOnlyAsStranger.length === 0);

  // --- group_chats / group_chat_members / group_messages
  // (0057_group_chats.sql): chats de grupo reales por primera vez,
  // comparado con WhatsApp/Instagram/Messenger/Facebook. Ronda de backend
  // (mismo orden que Reels/Directo). ---
  // Hallazgo real de Postgres/RLS (encontrado escribiendo este mismo
  // test): `insert into group_chats (...) returning id` falla con "new
  // row violates row-level security policy for table group_chats" a
  // pesar de que `group_chats_insert_own` es correcta letra por letra --
  // confirmado con una reproducción directa (insert sin RETURNING SÍ
  // funciona; una consulta SELECT aparte del mismo usuario justo después
  // SÍ ve la fila). La causa real: RETURNING vuelve a comprobar la fila
  // contra la política de SELECT (`group_chats_select`, que depende de
  // `is_group_member`, que a su vez depende de que el trigger
  // `trg_add_group_creator_as_member` YA haya insertado la fila de
  // pertenencia del creador) en un punto anterior a que ese efecto del
  // trigger cuente para esa comprobación concreta -- aunque sí cuenta ya
  // para cualquier SELECT posterior real. Se evita generando el `id` en
  // el propio cliente (mismo patrón real que deberá usar
  // GroupChatsViewModel más adelante) en vez de depender de RETURNING/
  // `.insert(){select()}` para esta tabla en concreto.
  await asUser(u1);
  const groupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [groupId, 'Grupo de u1', u1]);
  const group = { id: groupId };
  const creatorMembership = (await db.query(`select user_id from group_chat_members where group_chat_id = $1`, [group.id])).rows;
  check('trg_add_group_creator_as_member: el creador real (u1) se añade solo como miembro al crear el grupo', creatorMembership.length === 1 && creatorMembership[0].user_id === u1);

  await expectOk('group_chat_members_insert: un miembro real (u1) SÍ puede añadir a otra persona (u2, sin bloqueo)', async () => {
    await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [group.id, u2]);
  });

  await asUser(u3);
  await expectFail('group_chat_members_insert: alguien que NO es miembro (u3) no puede añadir a nadie al grupo', async () => {
    await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [group.id, u3]);
  });
  const groupAsStranger = (await db.query(`select id from group_chats where id = $1`, [group.id])).rows;
  check('group_chats_select: un tercero que no es miembro (u3) NO ve el grupo', groupAsStranger.length === 0);
  const membersAsStranger = (await db.query(`select user_id from group_chat_members where group_chat_id = $1`, [group.id])).rows;
  check('group_chat_members_select: un tercero que no es miembro (u3) NO ve la lista de miembros', membersAsStranger.length === 0);
  await expectFail('group_messages_insert: alguien que NO es miembro (u3) no puede escribir en el grupo', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'intento ajeno')`, [group.id, u3]);
  });

  await asUser(u1);
  await expectFail('group_chat_members_insert: bloqueado (u1 y u3 se bloquearon), u1 no puede añadir a u3 al grupo', async () => {
    await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [group.id, u3]);
  });

  await asUser(u2);
  const groupAsMember = (await db.query(`select id from group_chats where id = $1`, [group.id])).rows;
  check('group_chats_select: un miembro real (u2, añadido por u1) SÍ ve el grupo', groupAsMember.length === 1);
  const membersAsMember = (await db.query(`select user_id from group_chat_members where group_chat_id = $1`, [group.id])).rows;
  check('group_chat_members_select: un miembro real (u2) SÍ ve la lista completa de miembros', membersAsMember.length === 2);
  await expectOk('group_messages_insert: un miembro real (u2) SÍ puede escribir en el grupo', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'hola grupo')`, [group.id, u2]);
  });
  await asUser(u1);
  const messagesAsMember = (await db.query(`select body from group_messages where group_chat_id = $1`, [group.id])).rows;
  check('group_messages_select: otro miembro real (u1) SÍ ve el mensaje real de u2', messagesAsMember.length === 1 && messagesAsMember[0].body === 'hola grupo');

  // notify_new_group_message (0058_group_message_notify.sql): el resto
  // de miembros reales del grupo (u1, el creador) recibe el aviso real
  // del mensaje de u2 -- quien lo envió (u2) NO se notifica a sí mismo.
  const groupMessageNotifAsU1 = (await db.query(
    `select actor_id, payload from notifications where recipient_id = $1 and kind = 'group_message'`, [u1]
  )).rows;
  check('notify_new_group_message: el resto de miembros reales (u1) recibe el aviso del mensaje de u2', groupMessageNotifAsU1.length === 1);
  check('notify_new_group_message: actor_id es quien escribió (u2)', groupMessageNotifAsU1[0]?.actor_id === u2);
  check('notify_new_group_message: payload trae el group_chat_id real', groupMessageNotifAsU1[0]?.payload?.group_chat_id === group.id);
  await asUser(u2);
  const groupMessageNotifAsSender = (await db.query(
    `select id from notifications where recipient_id = $1 and kind = 'group_message'`, [u2]
  )).rows;
  check('notify_new_group_message: quien escribió (u2) NO se notifica a sí mismo', groupMessageNotifAsSender.length === 0);

  // --- group_message_reactions (0060_group_message_reactions.sql):
  // reaccionar a un mensaje de grupo, comparado con WhatsApp/Messenger/
  // Instagram. Reutiliza el mensaje real "hola grupo" de u2 de más arriba. ---
  await asSuperuser();
  const groupMsg = (await db.query(`select id from group_messages where group_chat_id = $1 and body = 'hola grupo'`, [group.id])).rows[0];
  await expectOk('group_message_reactions_insert: un miembro real (u1) SÍ puede reaccionar al mensaje de u2', async () => {
    await asUser(u1);
    await db.query(`insert into group_message_reactions (group_message_id, group_chat_id, user_id, emoji) values ($1, $2, $3, '❤')`, [groupMsg.id, group.id, u1]);
  });
  await asUser(u2);
  const groupReactionsAsMember = (await db.query(`select emoji from group_message_reactions where group_message_id = $1`, [groupMsg.id])).rows;
  check('group_message_reactions_select: otro miembro real (u2) SÍ ve la reacción real de u1', groupReactionsAsMember.length === 1 && groupReactionsAsMember[0].emoji === '❤');
  await asUser(u3);
  await expectFail('group_message_reactions_insert: alguien que NO es miembro (u3) no puede reaccionar', async () => {
    await db.query(`insert into group_message_reactions (group_message_id, group_chat_id, user_id, emoji) values ($1, $2, $3, '👍')`, [groupMsg.id, group.id, u3]);
  });
  const groupReactionsAsStranger = (await db.query(`select id from group_message_reactions where group_message_id = $1`, [groupMsg.id])).rows;
  check('group_message_reactions_select: alguien que NO es miembro (u3) NO ve las reacciones', groupReactionsAsStranger.length === 0);
  await asUser(u1);
  await expectOk('group_message_reactions_delete_own: u1 SÍ puede quitar su propia reacción', async () => {
    await db.query(`delete from group_message_reactions where group_message_id = $1 and user_id = $2`, [groupMsg.id, u1]);
  });

  // --- group_message_reads (0061_group_message_reads.sql): "visto por"
  // en chats de grupo, comparado con WhatsApp/Messenger. Reutiliza
  // `groupMsg` (mensaje real de u2, "hola grupo"). ---
  await expectOk('group_message_reads_insert_own: un miembro real (u1) SÍ puede marcar como leído un mensaje AJENO (de u2)', async () => {
    await asUser(u1);
    await db.query(`insert into group_message_reads (group_message_id, group_chat_id, user_id) values ($1, $2, $3)`, [groupMsg.id, group.id, u1]);
  });
  await asUser(u2);
  await expectFail('group_message_reads_insert_own: quien escribió (u2) NO puede marcar como leído su PROPIO mensaje', async () => {
    await db.query(`insert into group_message_reads (group_message_id, group_chat_id, user_id) values ($1, $2, $3)`, [groupMsg.id, group.id, u2]);
  });
  const groupReadsAsMember = (await db.query(`select user_id from group_message_reads where group_message_id = $1`, [groupMsg.id])).rows;
  check('group_message_reads_select: otro miembro real (u2) SÍ ve que u1 leyó el mensaje', groupReadsAsMember.length === 1 && groupReadsAsMember[0].user_id === u1);
  await asUser(u3);
  await expectFail('group_message_reads_insert_own: alguien que NO es miembro (u3) no puede marcar nada como leído', async () => {
    await db.query(`insert into group_message_reads (group_message_id, group_chat_id, user_id) values ($1, $2, $3)`, [groupMsg.id, group.id, u3]);
  });
  const groupReadsAsStranger = (await db.query(`select id from group_message_reads where group_message_id = $1`, [groupMsg.id])).rows;
  check('group_message_reads_select: alguien que NO es miembro (u3) NO ve los recibos de lectura', groupReadsAsStranger.length === 0);

  // --- group_messages.audio_url (0062_group_message_audio.sql): nota de
  // voz real en un chat de grupo, comparado con WhatsApp/Messenger/
  // Telegram -- un mensaje SOLO con audio_url (sin body ni media_url)
  // debe seguir pasando el check real de "algo de contenido". ---
  await asUser(u1);
  await expectOk('group_messages_has_content: un mensaje SOLO con audio_url (nota de voz, sin body) SÍ se puede insertar', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id, audio_url) values ($1, $2, 'https://media/u1/nota.m4a')`, [group.id, u1]);
  });
  await expectFail('group_messages_has_content: un mensaje SIN body, media_url NI audio_url sigue sin poder insertarse', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id) values ($1, $2)`, [group.id, u1]);
  });

  // --- group_chats.photo_url (0063_group_chat_photo.sql): nombre editable
  // y foto de grupo real, comparado con WhatsApp/Messenger/Telegram.
  // `group_chats_update_own` ya existía desde 0057 pero nunca se había
  // probado -- confirma aquí, con datos reales, que hace lo que su nombre
  // promete. ---
  await expectOk('group_chats_update_own: el creador real (u1) SÍ puede renombrar su grupo y ponerle foto', async () => {
    await db.query(`update group_chats set name = 'Grupo renombrado', photo_url = 'https://media/grupo.jpg' where id = $1`, [group.id]);
  });
  await asUser(u2);
  const groupRenamedAsMember = (await db.query(`select name, photo_url from group_chats where id = $1`, [group.id])).rows[0];
  check('group_chats_select: otro miembro real (u2) SÍ ve el nuevo nombre y foto', groupRenamedAsMember?.name === 'Grupo renombrado' && groupRenamedAsMember?.photo_url === 'https://media/grupo.jpg');
  // Hallazgo real de RLS, encontrado escribiendo este mismo test: un
  // UPDATE gobernado solo por USING (sin WITH CHECK adicional en el
  // cliente) que no encuentra ninguna fila que pase esa condición NO
  // lanza excepción -- simplemente actualiza 0 filas en silencio, a
  // diferencia de un INSERT/UPDATE que sí viola un WITH CHECK real (eso
  // sí lanza). `expectFail` (piensa "debe lanzar") no es la comprobación
  // correcta aquí -- lo correcto es confirmar que la fila NO cambió.
  await db.query(`update group_chats set name = 'Intento ajeno' where id = $1`, [group.id]);
  const groupAfterStrangerUpdate = (await db.query(`select name from group_chats where id = $1`, [group.id])).rows[0];
  check('group_chats_update_own: un miembro real que NO es el creador (u2) no puede renombrar el grupo (RLS real: 0 filas afectadas, no un error)', groupAfterStrangerUpdate?.name === 'Grupo renombrado');

  // --- group_chat_members.muted (0064_group_chat_mute.sql): silenciar un
  // chat de grupo real, comparado con WhatsApp/Instagram/Messenger.
  // Contexto ya asUser(u2) desde el bloque de arriba. ---
  // Nota de robustez de pruebas (no de producción), mismo hallazgo real
  // ya documentado arriba para group_messages/protect_group_message_identity:
  // hasta aquí, ningún UPDATE real había tocado nunca group_chat_members
  // -- protect_group_chat_member_identity() no se había invocado
  // todavía, y 0107_group_chat_admins.sql la redefinió con
  // `create or replace function`, añadiendo su primera llamada real a
  // auth.uid() (vía private.is_group_admin). Mismo "permission denied
  // for schema auth" real si nadie la calienta antes bajo un rol con
  // bypass total -- un UPDATE de superusuario antes (no-op real, mismo
  // body) la ejercita una vez.
  await asSuperuser();
  await db.query(`update group_chat_members set muted = muted where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  await asUser(u2);
  await expectOk('group_chat_members_update_own: u2 SÍ puede silenciar su propia fila de membresía', async () => {
    await db.query(`update group_chat_members set muted = true where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  });
  // Hallazgo real de RLS, encontrado escribiendo este mismo test: la
  // política de UPDATE de arriba, necesariamente amplia para poder tocar
  // `muted`, dejaría a u2 reescribir `group_chat_id` de su propia fila --
  // "trasladar" su membresía a un grupo ajeno sin haber sido invitado --
  // si no fuera por `trg_protect_group_chat_member_identity`.
  const fakeOtherGroupId = crypto.randomUUID();
  await db.query(`update group_chat_members set group_chat_id = $1 where user_id = $2 and group_chat_id = $3`, [fakeOtherGroupId, u2, group.id]);
  const membershipAfterIdentityAttempt = (await db.query(`select group_chat_id from group_chat_members where user_id = $1`, [u2])).rows[0];
  check('trg_protect_group_chat_member_identity: u2 no puede trasladar su propia membresía a otro group_chat_id', membershipAfterIdentityAttempt?.group_chat_id === group.id);

  // u1 escribe un mensaje nuevo con u2 ya silenciado -- u2 NO debe recibir
  // aviso esta vez (a diferencia del mensaje "hola grupo" de más arriba,
  // de antes de silenciar, que sí generó aviso real para u1).
  //
  // Hallazgo real de robustez del propio arnés de pruebas, encontrado
  // escribiendo las pruebas de 0082_mute_until.sql: esta comprobación
  // seguía autenticada como u1 al leer las notificaciones de u2 --
  // `notifications_select` (0002_rls.sql) exige `recipient_id =
  // auth.uid()`, así que la consulta siempre devolvía 0 filas por RLS,
  // acertara o no el trigger real. "Pasaba" sin comprobar nada de
  // verdad, mismo tipo de bug (no de RLS ni del trigger en sí, del
  // propio test) que el ya documentado en la ronda de "archivar
  // publicaciones" con u3/admin. Al arreglar la autenticación salió
  // además el recuento real correcto: u2 YA tenía 1 aviso real de
  // 'group_message' de antes de silenciarse (la nota de voz real de u1,
  // "nota.m4a", de la prueba `group_messages_has_content` bastante más
  // arriba, cuando u2 todavía no estaba silenciado) -- 0, no 1, era la
  // cifra equivocada.
  await asUser(u1);
  await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje tras silenciar')`, [group.id, u1]);
  await asUser(u2);
  const groupMessageNotifAsMutedU2 = (await db.query(`select id from notifications where recipient_id = $1 and kind = 'group_message'`, [u2])).rows;
  check('notify_new_group_message: u2 (silenciado) NO recibe un aviso NUEVO del mensaje de u1 (sigue habiendo solo el previo a silenciarse)', groupMessageNotifAsMutedU2.length === 1);

  // --- group_chat_members.muted_until (0082_mute_until.sql): mismo
  // criterio real que chats.muted_until_a/b -- u2 sigue con muted = true
  // desde el bloque de arriba. Mismo cuidado real de más arriba:
  // `asUser(u2)` antes de cada lectura real de sus propias
  // notificaciones. ---
  await asUser(u2);
  await db.query(`update group_chat_members set muted_until = now() - interval '1 hour' where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  await asUser(u1);
  await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'silencio de grupo real ya caducado')`, [group.id, u1]);
  await asUser(u2);
  const groupNotifAfterExpiredMute = (await db.query(`select id from notifications where recipient_id = $1 and kind = 'group_message'`, [u2])).rows;
  check('notify_new_group_message: un silencio de grupo real ya caducado (muted_until en el pasado) SÍ vuelve a generar aviso', groupNotifAfterExpiredMute.length === 2);

  await db.query(`update group_chat_members set muted_until = now() + interval '1 hour' where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  await asUser(u1);
  await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'silencio de grupo real todavía vigente')`, [group.id, u1]);
  await asUser(u2);
  const groupNotifStillMuted = (await db.query(`select id from notifications where recipient_id = $1 and kind = 'group_message'`, [u2])).rows;
  check('notify_new_group_message: un silencio de grupo real todavía vigente (muted_until en el futuro) SIGUE sin generar aviso', groupNotifStillMuted.length === 2);

  // --- group_messages.edited_at / group_messages_update_own /
  // group_messages_delete_own (0065_group_messages_edit_delete.sql):
  // editar y borrar el propio mensaje en un grupo, comparado con
  // WhatsApp/Telegram/Messenger. Reutiliza el mensaje real "mensaje tras
  // silenciar" de u1 de más arriba. ---
  await asUser(u1);
  const groupMsgToEdit = (await db.query(`select id from group_messages where group_chat_id = $1 and body = 'mensaje tras silenciar'`, [group.id])).rows[0];

  // Nota de robustez de pruebas (no de producción), mismo hallazgo real ya
  // documentado en 0044_chats_hide.sql: hasta aquí, TODOS los mensajes de
  // grupo de este archivo fueron INSERT, nunca UPDATE -- `protect_group_
  // message_identity()` no se había invocado ni una sola vez todavía, y
  // 0089_pin_message.sql la redefinió con `create or replace function`,
  // añadiendo sus primeras llamadas reales a `auth.uid()`. En el arnés
  // local (PGlite, sin USAGE real en el esquema auth) el primer intento de
  // evaluarla bajo un rol no-superusuario falla con "permission denied for
  // schema auth" si nadie la había "calentado" antes bajo un rol con
  // bypass total (confirmado con una reproducción aislada). Un UPDATE de
  // superusuario antes (no-op real, mismo body) la ejercita una vez sin
  // depender del orden real de miembros que sigue después.
  await asSuperuser();
  await db.query(`update group_messages set body = body where id = $1`, [groupMsgToEdit.id]);
  await asUser(u1);

  await expectOk('group_messages_update_own: el remitente real (u1) SÍ puede editar su propio mensaje', async () => {
    await db.query(`update group_messages set body = 'mensaje corregido', edited_at = now() where id = $1`, [groupMsgToEdit.id]);
  });
  const editedGroupMsg = (await db.query(`select body, edited_at from group_messages where id = $1`, [groupMsgToEdit.id])).rows[0];
  check('group_messages_update_own: el body y edited_at reales quedaron guardados', editedGroupMsg.body === 'mensaje corregido' && editedGroupMsg.edited_at !== null);

  // Hallazgo real de RLS, encontrado escribiendo esta misma migración:
  // `with check (sender_id = auth.uid())` certifica que el NUEVO
  // sender_id sigue siendo el propio remitente, pero no dice nada sobre
  // `group_chat_id` -- sin `trg_protect_group_message_identity`, u1
  // podría "trasladar" su propio mensaje a un grupo donde ni siquiera es
  // miembro, esquivando la comprobación real que sí protege el INSERT.
  const fakeOtherGroupIdForMessage = crypto.randomUUID();
  await db.query(`update group_messages set group_chat_id = $1 where id = $2`, [fakeOtherGroupIdForMessage, groupMsgToEdit.id]);
  const messageAfterIdentityAttempt = (await db.query(`select group_chat_id from group_messages where id = $1`, [groupMsgToEdit.id])).rows[0];
  check('trg_protect_group_message_identity: u1 no puede trasladar su propio mensaje a otro group_chat_id', messageAfterIdentityAttempt?.group_chat_id === group.id);

  // Mismo hallazgo ya confirmado con group_chats_update_own: un
  // UPDATE/DELETE gobernado solo por USING que no encuentra fila propia
  // no lanza excepción, solo afecta 0 filas -- se comprueba el estado
  // real, no con expectFail.
  await asUser(u2);
  await db.query(`update group_messages set body = 'intento ajeno' where id = $1`, [groupMsgToEdit.id]);
  await db.query(`delete from group_messages where id = $1`, [groupMsgToEdit.id]);
  const messageAfterStrangerAttempts = (await db.query(`select body from group_messages where id = $1`, [groupMsgToEdit.id])).rows[0];
  check('group_messages_update_own/delete_own: un miembro real que NO es el remitente (u2) no puede editar ni borrar el mensaje de u1', messageAfterStrangerAttempts?.body === 'mensaje corregido');

  await asUser(u1);
  await expectOk('group_messages_delete_own: el remitente real (u1) SÍ puede borrar su propio mensaje', async () => {
    await db.query(`delete from group_messages where id = $1`, [groupMsgToEdit.id]);
  });
  const messageAfterOwnDelete = (await db.query(`select id from group_messages where id = $1`, [groupMsgToEdit.id])).rows;
  check('group_messages_delete_own: el mensaje real ya no existe tras borrarlo', messageAfterOwnDelete.length === 0);

  // Salir del grupo real: mismo hallazgo de Postgres/RLS ya documentado
  // para live_stream_viewers -- group_chat_members_select deja ver la
  // propia fila (por reflexividad del exists de autopertenencia), así que
  // el DELETE de la propia fila SÍ encuentra candidato real y funciona.
  await asUser(u2);
  await expectOk('group_chat_members_delete_own: u2 SÍ puede salir del grupo real', async () => {
    await db.query(`delete from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  });
  const groupAfterLeaving = (await db.query(`select id from group_chats where id = $1`, [group.id])).rows;
  check('group_chats_select: tras salir de verdad, u2 ya NO ve el grupo', groupAfterLeaving.length === 0);

  // --- group_chat_members_delete_by_creator (0066_group_chat_kick_member.sql):
  // expulsar a un miembro real, comparado con WhatsApp/Messenger/Telegram.
  // u2 había salido justo arriba -- se le vuelve a añadir para esta
  // prueba, esta vez para comprobar la expulsión por el creador, no la
  // salida voluntaria. ---
  await asUser(u1);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [group.id, u2]);
  await asUser(u2);
  await db.query(`delete from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u1]);
  const u1StillMemberAfterKickAttempt = (await db.query(`select user_id from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u1])).rows;
  check('group_chat_members_delete_by_creator: un miembro real que NO es el creador (u2) no puede expulsar a nadie (RLS real: 0 filas afectadas, no un error)', u1StillMemberAfterKickAttempt.length === 1);
  await asUser(u1);
  await expectOk('group_chat_members_delete_by_creator: el creador real (u1) SÍ puede expulsar a otro miembro (u2)', async () => {
    await db.query(`delete from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u2]);
  });
  const u2GoneAfterKick = (await db.query(`select user_id from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u2])).rows;
  check('group_chat_members_delete_by_creator: u2 real queda expulsado del grupo', u2GoneAfterKick.length === 0);

  // --- reports.group_message_id / group_messages_select_admin
  // (0067_reports_group_message_reference.sql): referencia real al
  // mensaje de GRUPO denunciado, comparado con Instagram/WhatsApp/
  // Messenger. u3 sigue siendo admin desde el bloque de moderación de más
  // arriba; u2 ya no es miembro del grupo (expulsado justo arriba), así
  // que sirve también como "alguien real que no puede ver el mensaje sin
  // el bypass de admin". ---
  const groupMsgToReport = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje para denunciar') returning id`,
    [group.id, u1]
  )).rows[0];
  await db.query(
    `insert into reports (reporter_id, reported_id, reason, group_message_id) values ($1, $2, 'Acoso', $3)`,
    [u1, u1, groupMsgToReport.id]
  );
  await asUser(u2);
  const reportedGroupMsgAsKickedMember = (await db.query(`select id from group_messages where id = $1`, [groupMsgToReport.id])).rows;
  check('group_messages_select: u2 (expulsado, no admin) NO ve el mensaje de grupo aunque esté denunciado', reportedGroupMsgAsKickedMember.length === 0);
  await asUser(u3);
  const reportedGroupMsgAsAdmin = (await db.query(`select id, body from group_messages where id = $1`, [groupMsgToReport.id])).rows;
  check('group_messages_select_admin: un admin real (u3, no miembro del grupo) SÍ ve el mensaje de grupo REALMENTE denunciado', reportedGroupMsgAsAdmin.length === 1 && reportedGroupMsgAsAdmin[0].body === 'mensaje para denunciar');

  // --- group_chat_members.hidden / unhide_group_on_new_message
  // (0068_group_chat_hide.sql): ocultar un chat de grupo real de la
  // lista, comparado con WhatsApp/Instagram/Messenger. u1 sigue siendo el
  // único miembro real del grupo en este punto. ---
  await asUser(u1);
  await expectOk('group_chat_members_update_own: u1 SÍ puede ocultar su propia fila de membresía', async () => {
    await db.query(`update group_chat_members set hidden = true where group_chat_id = $1 and user_id = $2`, [group.id, u1]);
  });
  const hiddenBeforeNewMessage = (await db.query(`select hidden from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u1])).rows[0];
  check('group_chat_members.hidden: la fila real queda oculta', hiddenBeforeNewMessage.hidden === true);
  await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje que debe desocultar')`, [group.id, u1]);
  const hiddenAfterNewMessage = (await db.query(`select hidden from group_chat_members where group_chat_id = $1 and user_id = $2`, [group.id, u1])).rows[0];
  check('unhide_group_on_new_message: un mensaje nuevo real restaura la visibilidad -- mismo criterio que unhide_chat_on_new_message (0044) para el 1:1', hiddenAfterNewMessage.hidden === false);

  // --- messages.shared_post_id / group_messages.shared_post_id
  // (0069_message_shared_post.sql): enviar una publicación a un chat
  // real, comparado con Instagram/TikTok/Twitter/Snapchat. Contexto ya
  // asUser(u1). ---
  const postToShare = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'post real para compartir') returning id`, [u1]
  )).rows[0];
  await expectOk('messages_has_content: un mensaje SOLO con shared_post_id (sin body/media/audio) SÍ se puede insertar en el chat 1:1', async () => {
    await db.query(`insert into messages (chat_id, sender_id, shared_post_id) values ($1, $2, $3)`, [chat.id, u1, postToShare.id]);
  });
  await expectOk('group_messages_has_content: un mensaje SOLO con shared_post_id SÍ se puede insertar en un grupo', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id, shared_post_id) values ($1, $2, $3)`, [group.id, u1, postToShare.id]);
  });
  await asUser(u2);
  const sharedPostInChatAsRecipient = (await db.query(`select shared_post_id from messages where chat_id = $1 and shared_post_id = $2`, [chat.id, postToShare.id])).rows;
  check('messages_select: el destinatario real (u2) SÍ ve el mensaje con la publicación compartida', sharedPostInChatAsRecipient.length === 1);

  // --- messages.story_id (0071_message_story_reply.sql): responder a una
  // historia real, comparado con Instagram/WhatsApp Status/Snapchat.
  // Reutiliza `story` (historia real de u3, de la sección de story_views
  // de más arriba) solo como referencia real de FK -- no importa de quién
  // sea para esta prueba de columna/constraint. Contexto ya asUser(u2). ---
  await expectOk('messages_has_content: un mensaje SOLO con story_id (sin body/media/audio) SÍ se puede insertar', async () => {
    await db.query(`insert into messages (chat_id, sender_id, story_id) values ($1, $2, $3)`, [chat.id, u2, story.id]);
  });
  await asUser(u1);
  const storyReplyAsRecipient = (await db.query(`select story_id from messages where chat_id = $1 and story_id = $2`, [chat.id, story.id])).rows;
  check('messages_select: el destinatario real (u1) SÍ ve el mensaje con la respuesta a la historia', storyReplyAsRecipient.length === 1);

  // --- messages.is_forwarded / group_messages.is_forwarded
  // (0072_message_forward.sql): reenviar un mensaje real a otro chat,
  // comparado con WhatsApp/Telegram/Messenger. Contexto ya asUser(u1). ---
  await expectOk('messages_insert: un mensaje real con is_forwarded SÍ se puede insertar en el chat 1:1', async () => {
    await db.query(`insert into messages (chat_id, sender_id, body, is_forwarded) values ($1, $2, 'mensaje reenviado', true)`, [chat.id, u1]);
  });
  await expectOk('group_messages_insert: un mensaje real con is_forwarded SÍ se puede insertar en un grupo', async () => {
    await db.query(`insert into group_messages (group_chat_id, sender_id, body, is_forwarded) values ($1, $2, 'mensaje reenviado', true)`, [group.id, u1]);
  });
  await asUser(u2);
  const forwardedInChatAsRecipient = (await db.query(`select is_forwarded from messages where chat_id = $1 and body = 'mensaje reenviado'`, [chat.id])).rows;
  check('messages_select: el destinatario real (u2) SÍ ve el mensaje reenviado, con is_forwarded real', forwardedInChatAsRecipient.length === 1 && forwardedInChatAsRecipient[0].is_forwarded === true);

  // --- profiles.username (0073_profile_username.sql): nombre de usuario
  // único real (@handle), comparado con Instagram/Twitter/TikTok. ---
  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede ponerse un username real con formato válido', async () => {
    await db.query(`update profiles set username = 'juan_perez1' where id = $1`, [u1]);
  });
  await expectFail('profiles_username_format: un username con mayúsculas/demasiado corto NO se puede guardar', async () => {
    await db.query(`update profiles set username = 'AB' where id = $1`, [u1]);
  });
  await asUser(u2);
  await expectFail('profiles_username_unique: u2 no puede quedarse el username real ya usado por u1', async () => {
    await db.query(`update profiles set username = 'juan_perez1' where id = $1`, [u2]);
  });
  await expectOk('profiles_update_own: u2 SÍ puede ponerse un username real distinto', async () => {
    await db.query(`update profiles set username = 'maria99' where id = $1`, [u2]);
  });

  // --- close_friends/stories.visibility (0075_close_friends_stories.sql):
  // "Mejores amigos" real para historias, comparado con Instagram/Snapchat.
  // Hallazgo real de seguridad: stories_select (0002_rls.sql) no tenía
  // NINGUNA restricción de audiencia -- cualquiera veía la historia de
  // cualquiera. ---
  await asUser(u1);
  const everyoneStory = (await db.query(
    `insert into stories (author_id, media_url) values ($1, 'foto.jpg') returning id`, [u1]
  )).rows[0];
  await asUser(u3);
  const everyoneStoryAsStranger = (await db.query(`select id from stories where id = $1`, [everyoneStory.id])).rows;
  check('stories_select: comportamiento por defecto ("everyone") sin cambios -- un tercero cualquiera SÍ la ve', everyoneStoryAsStranger.length === 1);

  // --- story_questions/story_question_responses (0099_story_questions.sql):
  // adhesivo de pregunta real en una historia ("Pregúntame algo"),
  // comparado con Instagram -- reutiliza everyoneStory (autor real u1).
  // Las respuestas son privadas: ni siquiera otro espectador real de la
  // misma historia ve la respuesta de otra persona. Usuarios NUEVOS a
  // propósito para responder/mirar (no u2/u3): u1 ya los bloqueó a ambos
  // más arriba en este mismo archivo, y private.is_blocked() comprueba
  // las dos direcciones -- reutilizarlos aquí habría filtrado la
  // respuesta por ese bloqueo real ya existente, no por ningún fallo de
  // la migración (confirmado con una reproducción aislada: el mismo
  // INSERT, con usuarios sin ese bloqueo previo, sí funcionaba). ---
  await asSuperuser();
  const storyResponder = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const storyOtherViewer = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Responde'), ($2, 'Mira')
     on conflict (id) do update set display_name = excluded.display_name`,
    [storyResponder, storyOtherViewer]
  );

  await asUser(u1);
  const storyQuestion = (await db.query(
    `insert into story_questions (story_id, prompt) values ($1, '¿Qué tal el día?') returning id`, [everyoneStory.id]
  )).rows[0];
  await asUser(storyResponder);
  const questionAsViewer = (await db.query(`select id, prompt from story_questions where id = $1`, [storyQuestion.id])).rows;
  check('story_questions_select: un espectador real (storyResponder) SÍ ve que la historia tiene una pregunta', questionAsViewer.length === 1 && questionAsViewer[0].prompt === '¿Qué tal el día?');

  await expectOk('story_question_responses_insert_own: storyResponder SÍ puede responder de verdad a la pregunta', async () => {
    await db.query(`insert into story_question_responses (question_id, responder_id, body) values ($1, $2, 'muy bien, gracias')`, [storyQuestion.id, storyResponder]);
  });
  const responseAsResponder = (await db.query(`select id from story_question_responses where question_id = $1 and responder_id = $2`, [storyQuestion.id, storyResponder])).rows;
  check('story_question_responses_select: quien respondió (storyResponder) SÍ ve su propia respuesta real', responseAsResponder.length === 1);

  await asUser(u1);
  const responseAsAuthor = (await db.query(`select id, body from story_question_responses where question_id = $1`, [storyQuestion.id])).rows;
  check('story_question_responses_select: el autor real de la historia (u1) SÍ ve la respuesta real, con quién la escribió', responseAsAuthor.length === 1 && responseAsAuthor[0].body === 'muy bien, gracias');

  await asUser(storyOtherViewer);
  const responseAsOtherViewer = (await db.query(`select id from story_question_responses where question_id = $1`, [storyQuestion.id])).rows;
  check('story_question_responses_select: otro espectador real (storyOtherViewer), que no escribió esa respuesta ni es el autor, NO la ve', responseAsOtherViewer.length === 0);

  // --- story_polls/story_poll_votes/private.story_poll_counts()
  // (0100_story_polls.sql): encuesta real en una historia, comparado con
  // Instagram/Twitter/X -- el reparto agregado es público para cualquier
  // espectador real, pero un voto individual solo lo ve quien lo emitió
  // y el autor real de la historia. ---
  await asUser(u1);
  const pollStory = (await db.query(`insert into stories (author_id, media_url) values ($1, 'encuesta.jpg') returning id`, [u1])).rows[0];
  const poll = (await db.query(
    `insert into story_polls (story_id, question, options) values ($1, '¿Pizza o sushi?', '["Pizza", "Sushi"]'::jsonb) returning id`, [pollStory.id]
  )).rows[0];

  await expectFail('story_poll_votes_insert_own: un option_index real fuera de rango (2, solo hay 0 y 1) NO se puede votar', async () => {
    await db.query(`insert into story_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 2)`, [poll.id, u1]);
  });

  await asUser(storyResponder);
  await expectOk('story_poll_votes_insert_own: storyResponder SÍ puede votar de verdad ("Pizza")', async () => {
    await db.query(`insert into story_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 0)`, [poll.id, storyResponder]);
  });
  await asUser(storyOtherViewer);
  await expectOk('story_poll_votes_insert_own: storyOtherViewer SÍ puede votar de verdad ("Sushi")', async () => {
    await db.query(`insert into story_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 1)`, [poll.id, storyOtherViewer]);
  });

  const ownVoteAsOtherViewer = (await db.query(`select option_index from story_poll_votes where poll_id = $1 and voter_id = $2`, [poll.id, storyOtherViewer])).rows;
  check('story_poll_votes_select: storyOtherViewer SÍ ve su propio voto real', ownVoteAsOtherViewer.length === 1 && ownVoteAsOtherViewer[0].option_index === 1);
  const otherVoteAsOtherViewer = (await db.query(`select id from story_poll_votes where poll_id = $1 and voter_id = $2`, [poll.id, storyResponder])).rows;
  check('story_poll_votes_select: storyOtherViewer NO ve el voto real de storyResponder (ni siquiera que existe)', otherVoteAsOtherViewer.length === 0);

  const countsAsOtherViewer = (await db.query(`select vote_counts from story_polls where id = $1`, [poll.id])).rows[0];
  check(
    'sync_story_poll_counts: cualquier espectador real (storyOtherViewer) SÍ ve el reparto agregado real (1 voto por opción), sin ver quién votó qué',
    JSON.stringify(countsAsOtherViewer.vote_counts) === JSON.stringify([1, 1])
  );

  await expectOk('story_poll_votes_update_own: storyOtherViewer SÍ puede cambiar de opción real ("Pizza" en vez de "Sushi")', async () => {
    await db.query(`update story_poll_votes set option_index = 0 where poll_id = $1 and voter_id = $2`, [poll.id, storyOtherViewer]);
  });
  const countsAfterChange = (await db.query(`select vote_counts from story_polls where id = $1`, [poll.id])).rows[0];
  check('sync_story_poll_counts: tras cambiar de opción real, el reparto agregado ya refleja 2 votos en "Pizza" y 0 en "Sushi"', JSON.stringify(countsAfterChange.vote_counts) === JSON.stringify([2, 0]));

  await asUser(u1);
  const votesAsAuthor = (await db.query(`select voter_id, option_index from story_poll_votes where poll_id = $1 order by voter_id`, [poll.id])).rows;
  check('story_poll_votes_select: el autor real de la historia (u1) SÍ ve TODOS los votos individuales, con quién los emitió', votesAsAuthor.length === 2);

  await asUser(u1);
  await expectOk('close_friends_insert_own: u1 SÍ puede añadir a u2 como mejor amigo real', async () => {
    await db.query(`insert into close_friends (owner_id, friend_id) values ($1, $2)`, [u1, u2]);
  });
  await asUser(u2);
  await expectFail('close_friends_insert_own: u2 NO puede añadirse a sí mismo en la lista de u1 (owner_id ajeno)', async () => {
    await db.query(`insert into close_friends (owner_id, friend_id) values ($1, $2)`, [u1, u3]);
  });
  const listAsFriend = (await db.query(`select * from close_friends where owner_id = $1`, [u1])).rows;
  check('close_friends_select_own: ni siquiera el propio amigo añadido (u2) puede leer la lista de u1', listAsFriend.length === 0);

  await asUser(u1);
  const closeFriendsStory = (await db.query(
    `insert into stories (author_id, media_url, visibility) values ($1, 'privada.jpg', 'close_friends') returning id`, [u1]
  )).rows[0];
  const ownStoryAsAuthor = (await db.query(`select id from stories where id = $1`, [closeFriendsStory.id])).rows;
  check('stories_select: el propio autor (u1) SIEMPRE ve su historia real de "close_friends"', ownStoryAsAuthor.length === 1);

  await asUser(u2);
  const closeFriendsStoryAsFriend = (await db.query(`select id from stories where id = $1`, [closeFriendsStory.id])).rows;
  check('stories_select: un mejor amigo real (u2) SÍ ve la historia "close_friends"', closeFriendsStoryAsFriend.length === 1);

  await asUser(u3);
  const closeFriendsStoryAsStranger = (await db.query(`select id from stories where id = $1`, [closeFriendsStory.id])).rows;
  check('stories_select: un tercero que NO es mejor amigo (u3) NO ve la historia "close_friends"', closeFriendsStoryAsStranger.length === 0);

  await asUser(u1);
  await expectOk('close_friends_delete_own: u1 SÍ puede quitar a u2 real de su lista de mejores amigos', async () => {
    await db.query(`delete from close_friends where owner_id = $1 and friend_id = $2`, [u1, u2]);
  });
  await asUser(u2);
  const closeFriendsStoryAfterRemoval = (await db.query(`select id from stories where id = $1`, [closeFriendsStory.id])).rows;
  check('stories_select: tras quitarlo de la lista real, u2 ya NO ve la historia "close_friends"', closeFriendsStoryAfterRemoval.length === 0);

  // --- story_highlights/story_highlight_items (0101_story_highlights.sql):
  // destacados reales de historias en el perfil, comparado con Instagram --
  // una historia DENTRO de un destacado deja de caducar para quien ya
  // podía verla por su propia regla de visibilidad. Usuarios NUEVOS a
  // propósito (mismo motivo ya documentado arriba con
  // storyResponder/storyOtherViewer): sin ninguna relación previa de
  // bloqueo/mejores amigos que pueda contaminar esta prueba. ---
  await asSuperuser();
  const hlAuthor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const hlFriend = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const hlStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Destaca'), ($2, 'Amigo'), ($3, 'Extraño')
     on conflict (id) do update set display_name = excluded.display_name`,
    [hlAuthor, hlFriend, hlStranger]
  );

  await asUser(hlAuthor);
  const hlActiveStory = (await db.query(
    `insert into stories (author_id, media_url) values ($1, 'activa.jpg') returning id`, [hlAuthor]
  )).rows[0];
  const highlight = (await db.query(
    `insert into story_highlights (author_id, title) values ($1, 'Viajes') returning id`, [hlAuthor]
  )).rows[0];

  await expectOk('story_highlight_items_insert_own: hlAuthor SÍ puede añadir su propia historia real activa a su propio destacado', async () => {
    await db.query(`insert into story_highlight_items (highlight_id, story_id) values ($1, $2)`, [highlight.id, hlActiveStory.id]);
  });

  await asUser(hlStranger);
  const hlStrangerStory = (await db.query(
    `insert into stories (author_id, media_url) values ($1, 'extrano.jpg') returning id`, [hlStranger]
  )).rows[0];
  await expectFail('story_highlight_items_insert_own: hlStranger NO puede añadir SU historia real a un destacado ajeno (highlight_id de hlAuthor)', async () => {
    await db.query(`insert into story_highlight_items (highlight_id, story_id) values ($1, $2)`, [highlight.id, hlStrangerStory.id]);
  });
  const hlOwnHighlight = (await db.query(
    `insert into story_highlights (author_id, title) values ($1, 'Robo') returning id`, [hlStranger]
  )).rows[0];
  await expectFail('story_highlight_items_insert_own: hlStranger NO puede añadir la historia AJENA de hlAuthor a su propio destacado', async () => {
    await db.query(`insert into story_highlight_items (highlight_id, story_id) values ($1, $2)`, [hlOwnHighlight.id, hlActiveStory.id]);
  });

  await asUser(hlFriend);
  const highlightSeenByAnyone = (await db.query(`select title from story_highlights where id = $1`, [highlight.id])).rows;
  check('story_highlights_select: cualquier persona real (hlFriend) SÍ ve el título de un destacado ajeno', highlightSeenByAnyone.length === 1 && highlightSeenByAnyone[0].title === 'Viajes');

  // Aviso de honestidad confirmado de verdad, no solo documentado (y
  // corregido en el camino -- ver 0101_story_highlights.sql): una
  // historia YA caducada sigue siendo visible para su propio autor
  // (stories_write_own, "for all", se combina con OR sobre el propio
  // SELECT) -- un tercero real, en cambio, ya no la ve. Por eso destacar
  // una historia YA caducada SÍ funciona de un tirón, sin excepción
  // nueva: el autor real siempre pudo "verla" para pasar el EXISTS del
  // INSERT, esté caducada o no.
  await asSuperuser();
  const expiredStoryId = crypto.randomUUID();
  await db.query(
    `insert into stories (id, author_id, media_url, expires_at) values ($1, $2, 'caducada.jpg', now() - interval '1 hour')`,
    [expiredStoryId, hlAuthor]
  );
  await asUser(hlAuthor);
  const expiredAsAuthor = (await db.query(`select id from stories where id = $1`, [expiredStoryId])).rows;
  check('stories_select: el propio autor (hlAuthor) SIGUE viendo su historia real ya caducada (stories_write_own, "for all", se combina con OR)', expiredAsAuthor.length === 1);
  await asUser(hlStranger);
  const expiredAsStrangerBeforeHighlight = (await db.query(`select id from stories where id = $1`, [expiredStoryId])).rows;
  check('stories_select: un tercero real (hlStranger) NO ve esa historia ya caducada mientras no esté en ningún destacado', expiredAsStrangerBeforeHighlight.length === 0);

  await asUser(hlAuthor);
  await expectOk('story_highlight_items_insert_own: hlAuthor SÍ puede destacar de un tirón una historia real YA caducada (sin excepción nueva -- el autor siempre pudo verla)', async () => {
    await db.query(`insert into story_highlight_items (highlight_id, story_id) values ($1, $2)`, [highlight.id, expiredStoryId]);
  });
  await asUser(hlStranger);
  const expiredAsStrangerAfterHighlight = (await db.query(`select id from stories where id = $1`, [expiredStoryId])).rows;
  check('stories_select: tras destacarla, un tercero real (hlStranger) SÍ ve ahora esa historia YA caducada -- "destacar desde el archivo" real, comparado con Instagram', expiredAsStrangerAfterHighlight.length === 1);

  // La prueba real de fondo de esta migración: una vez DENTRO de un
  // destacado, una historia real deja de caducar de verdad para quien ya
  // podía verla -- aquí se caduca a propósito una historia que ya estaba
  // en el destacado desde antes.
  await asSuperuser();
  await db.query(`update stories set expires_at = now() - interval '1 hour' where id = $1`, [hlActiveStory.id]);
  await asUser(hlFriend);
  const highlightedStoryAfterExpiry = (await db.query(`select id from stories where id = $1`, [hlActiveStory.id])).rows;
  check('stories_select: una historia real DENTRO de un destacado SÍ se sigue viendo después de caducar (hlFriend, un tercero cualquiera)', highlightedStoryAfterExpiry.length === 1);

  // Destacar NO salta la regla real de "mejores amigos" -- la excepción
  // de más arriba es SOLO sobre la caducidad, nunca sobre la audiencia.
  await asUser(hlAuthor);
  const closeFriendsHighlightStory = (await db.query(
    `insert into stories (author_id, media_url, visibility) values ($1, 'privada_destacada.jpg', 'close_friends') returning id`, [hlAuthor]
  )).rows[0];
  await expectOk('story_highlight_items_insert_own: hlAuthor SÍ puede destacar también una historia real de "close_friends" mientras sigue activa', async () => {
    await db.query(`insert into story_highlight_items (highlight_id, story_id) values ($1, $2)`, [highlight.id, closeFriendsHighlightStory.id]);
  });
  await asUser(hlStranger);
  const closeFriendsHighlightAsStranger = (await db.query(`select id from stories where id = $1`, [closeFriendsHighlightStory.id])).rows;
  check('stories_select: destacar NO salta la regla real de "mejores amigos" -- hlStranger sigue sin ver esta historia aunque esté en un destacado', closeFriendsHighlightAsStranger.length === 0);

  await db.query(`delete from story_highlight_items where highlight_id = $1 and story_id = $2`, [highlight.id, hlActiveStory.id]);
  await asSuperuser();
  const itemStillThereAfterStranger = (await db.query(`select 1 from story_highlight_items where highlight_id = $1 and story_id = $2`, [highlight.id, hlActiveStory.id])).rows;
  check('story_highlight_items_delete_own: hlStranger NO puede quitar una historia real de un destacado ajeno (0 filas afectadas por RLS, no un error)', itemStillThereAfterStranger.length === 1);

  await asUser(hlAuthor);
  await expectOk('story_highlight_items_delete_own: hlAuthor SÍ puede quitar su propia historia real de su propio destacado', async () => {
    await db.query(`delete from story_highlight_items where highlight_id = $1 and story_id = $2`, [highlight.id, hlActiveStory.id]);
  });
  await asUser(hlFriend);
  const storyAfterRemovalFromHighlight = (await db.query(`select id from stories where id = $1`, [hlActiveStory.id])).rows;
  check('stories_select: tras quitarla del destacado real, la historia YA caducada vuelve a desaparecer de verdad, incluso para un tercero', storyAfterRemovalFromHighlight.length === 0);

  // --- muted_story_authors (0085_muted_story_authors.sql): silenciar las
  // historias de alguien sin dejar de seguirlo, comparado con Instagram/
  // Snapchat -- a diferencia de close_friends, esto NO es control de
  // acceso: no toca stories_select, solo protege la lista en sí (ni
  // siquiera la persona silenciada puede leer que lo está, mismo criterio
  // que close_friends). ---
  await asUser(u2);
  const storyToMute = (await db.query(
    `insert into stories (author_id, media_url) values ($1, 'https://media/u2/story-real.jpg') returning id`, [u2]
  )).rows[0];

  await asUser(u1);
  await expectOk('muted_story_authors_insert: u1 SÍ puede silenciar las historias reales de u2', async () => {
    await db.query(`insert into muted_story_authors (muter_id, muted_id) values ($1, $2)`, [u1, u2]);
  });
  const canStillSeeStoryWhileMuted = (await db.query(`select id from stories where id = $1`, [storyToMute.id])).rows;
  check('muted_story_authors: silenciar NO es control de acceso -- u1 SIGUE viendo la historia real de u2 (everyone)', canStillSeeStoryWhileMuted.length === 1);

  await asUser(u2);
  const mutedListAsMutedPerson = (await db.query(`select muted_id from muted_story_authors where muter_id = $1`, [u1])).rows;
  check('muted_story_authors_select: ni siquiera la persona silenciada real (u2) puede leer la lista de quien la silenció', mutedListAsMutedPerson.length === 0);
  await db.query(`insert into muted_story_authors (muter_id, muted_id) values ($1, $2)`, [u2, u1]);
  const u2OwnMutedList = (await db.query(`select muted_id from muted_story_authors where muter_id = $1`, [u2])).rows;
  check('muted_story_authors_select: u2 SÍ ve su propia lista real', u2OwnMutedList.length === 1);

  await asUser(u3);
  await expectFail('muted_story_authors_insert: u3 NO puede silenciar a alguien en la lista ajena de u1', async () => {
    await db.query(`insert into muted_story_authors (muter_id, muted_id) values ($1, $2)`, [u1, u3]);
  });

  await asUser(u1);
  await expectOk('muted_story_authors_delete: u1 SÍ puede dejar de silenciar a u2 real', async () => {
    await db.query(`delete from muted_story_authors where muter_id = $1 and muted_id = $2`, [u1, u2]);
  });
  const mutedListAfterRemoval = (await db.query(`select muted_id from muted_story_authors where muter_id = $1`, [u1])).rows;
  check('muted_story_authors_delete: la lista real de u1 queda vacía tras quitarlo', mutedListAfterRemoval.length === 0);

  // --- posts.archived_at (0076_archive_posts.sql): archivar una
  // publicación real sin borrarla, comparado con Instagram/Facebook. ---
  //
  // Hallazgo real de robustez del propio arnés de pruebas (no de RLS): la
  // primera versión de este bloque usaba u3 como "tercero cualquiera",
  // pero u3 ya es admin desde el bloque de moderación de más arriba --
  // `posts_select_admin`/`comments_select_admin` (0045) le dan
  // visibilidad total de verdad e intencionada (un admin revisando una
  // denuncia SÍ debe ver hasta el contenido archivado), así que los dos
  // primeros intentos de este bloque "fallaban" solo porque u3 no era un
  // desconocido real. Un u4 nuevo, sin admin y sin ninguna relación con
  // u1, es el tercero real que hace falta aquí.
  await asSuperuser();
  const u4 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1, 'Cuatro') on conflict (id) do nothing`, [u4]);

  await asUser(u1);
  const archivablePost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'una publicación normal') returning id`, [u1]
  )).rows[0];
  await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'qué bien')`, [archivablePost.id, u1]);

  await asUser(u4);
  const beforeArchiveAsStranger = (await db.query(`select id from posts where id = $1`, [archivablePost.id])).rows;
  check('posts_select: antes de archivar, un tercero cualquiera (u4) SÍ ve una publicación pública real', beforeArchiveAsStranger.length === 1);

  await asUser(u1);
  await expectOk('posts_write_own: el propio autor (u1) SÍ puede archivar su publicación real', async () => {
    await db.query(`update posts set archived_at = now() where id = $1`, [archivablePost.id]);
  });

  await asUser(u4);
  await db.query(`update posts set archived_at = null where id = $1`, [archivablePost.id]);
  const archivedAsStranger = (await db.query(`select id from posts where id = $1`, [archivablePost.id])).rows;
  check('posts_select: tras archivarla de verdad, un tercero (u4) YA NO ve la publicación', archivedAsStranger.length === 0);

  await asUser(u1);
  const afterOthersArchiveAttempt = (await db.query(`select archived_at from posts where id = $1`, [archivablePost.id])).rows[0];
  check('posts_write_own: un tercero (u4) NO puede desarchivar la publicación ajena de u1 (RLS real: 0 filas afectadas, no un error)', afterOthersArchiveAttempt.archived_at !== null);

  await asUser(u4);
  const archivedCommentsAsStranger = (await db.query(`select id from comments where post_id = $1`, [archivablePost.id])).rows;
  check('comments_select: tras archivar el post real, un tercero (u4) tampoco ve sus comentarios', archivedCommentsAsStranger.length === 0);

  await asUser(u1);
  const archivedAsAuthor = (await db.query(`select id from posts where id = $1`, [archivablePost.id])).rows;
  check('posts_select: el propio autor (u1) SIEMPRE ve su publicación archivada real', archivedAsAuthor.length === 1);

  await expectOk('posts_write_own: el propio autor (u1) SÍ puede restaurar (desarchivar) su publicación real', async () => {
    await db.query(`update posts set archived_at = null where id = $1`, [archivablePost.id]);
  });
  await asUser(u4);
  const restoredAsStranger = (await db.query(`select id from posts where id = $1`, [archivablePost.id])).rows;
  check('posts_select: tras restaurarla de verdad, un tercero (u4) vuelve a verla', restoredAsStranger.length === 1);

  // --- profiles.website_url (0077_profile_website.sql): enlace externo
  // real en el perfil ("link in bio"), comparado con
  // Instagram/TikTok/Twitter. ---
  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede guardar un enlace externo real en su perfil', async () => {
    await db.query(`update profiles set website_url = 'https://ejemplo.com/juan' where id = $1`, [u1]);
  });
  await expectFail('profiles_website_url_length: una URL real de más de 200 caracteres NO se puede guardar', async () => {
    await db.query(`update profiles set website_url = $2 where id = $1`, [u1, 'https://ejemplo.com/' + 'a'.repeat(200)]);
  });

  // --- profiles.muted_keywords (0078_muted_keywords.sql): palabras
  // silenciadas reales en comentarios, comparado con Instagram/Twitter --
  // el comentario SIGUE existiendo de verdad para todos los demás,
  // incluido quien lo escribió; solo desaparece para el dueño de la
  // publicación que activó su propio filtro. ---
  await asUser(u1);
  await db.query(`update profiles set muted_keywords = array['spam'] where id = $1`, [u1]);
  const mutedWordsPost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'otra publicación real') returning id`, [u1]
  )).rows[0];

  await asUser(u2);
  const spamComment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'esto es spam de verdad') returning id`, [mutedWordsPost.id, u2]
  )).rows[0];
  const cleanComment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'qué buena foto') returning id`, [mutedWordsPost.id, u2]
  )).rows[0];
  const bothAsCommenter = (await db.query(`select id from comments where post_id = $1`, [mutedWordsPost.id])).rows;
  check('comments_select: quien escribió el comentario real con la palabra silenciada SIGUE viéndolo (u2)', bothAsCommenter.length === 2);

  await asUser(u1);
  const visibleToOwner = (await db.query(`select id from comments where post_id = $1`, [mutedWordsPost.id])).rows.map(r => r.id);
  check('comments_select: el dueño real (u1) NO ve el comentario con su propia palabra silenciada', !visibleToOwner.includes(spamComment.id));
  check('comments_select: el dueño real (u1) SÍ sigue viendo el comentario sin ninguna palabra silenciada', visibleToOwner.includes(cleanComment.id));

  await asUser(u4);
  const visibleToStranger = (await db.query(`select id from comments where post_id = $1`, [mutedWordsPost.id])).rows;
  check('comments_select: un tercero real (u4) SÍ ve el comentario con la palabra silenciada de OTRO (el filtro solo aplica al dueño)', visibleToStranger.length === 2);

  // Mismo espejo real en reel_comments.
  await asUser(u1);
  const mutedWordsReel = (await db.query(
    `insert into reels (author_id, video_url) values ($1, 'v2.mp4') returning id`, [u1]
  )).rows[0];
  await asUser(u2);
  await db.query(`insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'puro spam')`, [mutedWordsReel.id, u2]);
  await asUser(u1);
  const reelCommentsAsOwner = (await db.query(`select id from reel_comments where reel_id = $1`, [mutedWordsReel.id])).rows;
  check('reel_comments_select: el dueño real (u1) NO ve el comentario de reel con su propia palabra silenciada', reelCommentsAsOwner.length === 0);
  await asUser(u4);
  const reelCommentsAsStranger = (await db.query(`select id from reel_comments where reel_id = $1`, [mutedWordsReel.id])).rows;
  check('reel_comments_select: un tercero real (u4) SÍ ve el comentario de reel con la palabra silenciada de OTRO', reelCommentsAsStranger.length === 1);

  // --- restricts / private.is_restricted (0093_restrict_account.sql):
  // restringir una cuenta real, comparado con Instagram -- a diferencia
  // de muted_keywords (arriba, oculta SOLO al dueño), aquí se oculta a
  // TODOS MENOS al dueño y a quien escribió el comentario. Publicación
  // real NUEVA y propia (no mutedWordsPost, ya usada arriba): un
  // comentario real que se queda ahí para siempre contaminaría el
  // recuento fijo de "2 comentarios" que comprueba más abajo la ronda de
  // comments_disabled (0086) sobre esa misma publicación. u1 restringe a
  // u2. ---
  await asUser(u1);
  const restrictPost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'publicación real para restringir') returning id`, [u1]
  )).rows[0];
  await db.query(`insert into restricts (restricter_id, restricted_id) values ($1, $2)`, [u1, u2]);

  await asUser(u2);
  const restrictedComment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'comentario real ya restringido') returning id`, [restrictPost.id, u2]
  )).rows[0];
  const restrictedCommentAsAuthor = (await db.query(`select id from comments where id = $1`, [restrictedComment.id])).rows;
  check('comments_select: quien escribió el comentario real restringido (u2) SIGUE viéndolo con normalidad, sin enterarse de nada', restrictedCommentAsAuthor.length === 1);

  await asUser(u1);
  const restrictedCommentAsOwner = (await db.query(`select id from comments where id = $1`, [restrictedComment.id])).rows;
  check('comments_select: el dueño real (u1), que restringió, SÍ sigue viendo el comentario (puede moderarlo en privado)', restrictedCommentAsOwner.length === 1);

  await asUser(u4);
  const restrictedCommentAsStranger = (await db.query(`select id from comments where id = $1`, [restrictedComment.id])).rows;
  check('comments_select: un tercero real (u4) NO ve el comentario de un usuario real restringido por el dueño', restrictedCommentAsStranger.length === 0);

  await asUser(u2);
  const restrictsSeenByRestricted = (await db.query(`select 1 from restricts where restricted_id = $1`, [u2])).rows;
  check('restricts_select_own: la persona restringida real (u2) NUNCA puede ver que está restringida (0 filas, ni siquiera un error)', restrictsSeenByRestricted.length === 0);

  await asUser(u1);
  await expectOk('restricts_delete_own: quien restringió (u1) SÍ puede deshacerlo', async () => {
    await db.query(`delete from restricts where restricter_id = $1 and restricted_id = $2`, [u1, u2]);
  });
  const restrictedCommentAfterUndo = (await db.query(`select id from comments where id = $1`, [restrictedComment.id])).rows;
  check('comments_select: tras deshacer la restricción real, el dueño (u1) vuelve a verlo con normalidad (ya lo veía, pero confirma que el UPDATE de verdad se aplicó)', restrictedCommentAfterUndo.length === 1);
  await asUser(u4);
  const restrictedCommentAfterUndoAsStranger = (await db.query(`select id from comments where id = $1`, [restrictedComment.id])).rows;
  check('comments_select: tras deshacer la restricción real, un tercero (u4) vuelve a ver el comentario con normalidad', restrictedCommentAfterUndoAsStranger.length === 1);

  // --- comments.is_pinned/reel_comments.is_pinned (0084_pin_comments.sql):
  // fijar un comentario, comparado con Instagram/Twitter -- primer caso
  // real de esta sesión donde alguien DISTINTO del autor de la fila
  // (aquí, el autor de la publicación) puede tocarla vía RLS directa.
  // Reutiliza mutedWordsPost (autor real u1) y cleanComment (de u2, sin
  // palabra silenciada) del bloque de arriba. ---
  // Nota de robustez de pruebas (no de producción), mismo hallazgo real ya
  // documentado arriba para group_chat_members/group_messages: 0123_comment_edit.sql
  // redefinió protect_comment_pin_only/protect_reel_comment_pin_only con
  // `create or replace function`, añadiendo sus primeras llamadas reales
  // a auth.uid() -- "permission denied for schema auth" real bajo un rol
  // no-superusuario si nadie la calienta antes bajo un rol con bypass
  // total. Un UPDATE de superusuario antes (no-op real) la ejercita una
  // vez.
  await asSuperuser();
  await db.query(`update comments set body = body where id = $1`, [cleanComment.id]);
  await asUser(u1);
  await expectOk('comments_update_pin: el autor real de la publicación (u1) SÍ puede fijar un comentario ajeno', async () => {
    await db.query(`update comments set is_pinned = true where id = $1`, [cleanComment.id]);
  });
  const pinnedComment = (await db.query(`select is_pinned from comments where id = $1`, [cleanComment.id])).rows[0];
  check('comments_update_pin: el comentario real queda fijado', pinnedComment.is_pinned === true);

  await asUser(u1);
  await db.query(`update comments set is_pinned = false, body = 'hackeado' where id = $1`, [cleanComment.id]);
  const afterPinAttack = (await db.query(`select is_pinned, body from comments where id = $1`, [cleanComment.id])).rows[0];
  check('comments_update_pin: is_pinned real SÍ cambia (desfijado)', afterPinAttack.is_pinned === false);
  check('protect_comment_pin_only: el body real NO se puede tocar por esta vía, aunque venga en la misma sentencia', afterPinAttack.body === 'qué buena foto');

  await asUser(u2); // u2 escribió el comentario, pero NO es el autor real de la publicación
  await db.query(`update comments set is_pinned = true where id = $1`, [cleanComment.id]);
  const stillNotPinnedByCommenter = (await db.query(`select is_pinned from comments where id = $1`, [cleanComment.id])).rows[0];
  check('comments_update_pin: quien escribió el comentario (u2) NO puede fijarlo -- solo el autor real de la publicación puede (0 filas afectadas, no un error)', stillNotPinnedByCommenter.is_pinned === false);

  await asUser(u4); // tercero real, ni autor de la publicación ni del comentario
  await db.query(`update comments set is_pinned = true where id = $1`, [cleanComment.id]);
  const stillNotPinnedByStranger = (await db.query(`select is_pinned from comments where id = $1`, [cleanComment.id])).rows[0];
  check('comments_update_pin: un tercero real (u4) NO puede fijar un comentario ajeno (0 filas afectadas, no un error)', stillNotPinnedByStranger.is_pinned === false);

  // Mismo espejo real en reel_comments -- comentario propio para no
  // depender del estado del comentario de reel ya usado arriba (que
  // nunca capturó su id con RETURNING).
  await asUser(u2);
  const reelCommentToPin = (await db.query(
    `insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'buen reel') returning id`, [mutedWordsReel.id, u2]
  )).rows[0];
  // Mismo "calentamiento" real que arriba, ahora para
  // protect_reel_comment_pin_only (también redefinida por 0123).
  await asSuperuser();
  await db.query(`update reel_comments set body = body where id = $1`, [reelCommentToPin.id]);
  await asUser(u1); // u1 es el autor real del reel (mutedWordsReel)
  await expectOk('reel_comments_update_pin: el autor real del reel (u1) SÍ puede fijar un comentario ajeno', async () => {
    await db.query(`update reel_comments set is_pinned = true where id = $1`, [reelCommentToPin.id]);
  });
  const pinnedReelComment = (await db.query(`select is_pinned from reel_comments where id = $1`, [reelCommentToPin.id])).rows[0];
  check('reel_comments_update_pin: el comentario de reel real queda fijado', pinnedReelComment.is_pinned === true);

  await asUser(u2);
  await db.query(`update reel_comments set is_pinned = false where id = $1`, [reelCommentToPin.id]);
  const stillPinnedByReelCommenter = (await db.query(`select is_pinned from reel_comments where id = $1`, [reelCommentToPin.id])).rows[0];
  check('reel_comments_update_pin: quien escribió el comentario de reel (u2) NO puede desfijarlo -- solo el autor real del reel puede (0 filas afectadas, no un error)', stillPinnedByReelCommenter.is_pinned === true);

  // --- comments.edited_at/reel_comments.edited_at (0123_comment_edit.sql):
  // editar un comentario ya publicado, comparado con Instagram/Facebook/
  // Twitter/TikTok -- segunda política UPDATE real, esta vez para el
  // propio autor del comentario (distinta de comments_update_pin, que es
  // exclusiva del autor de la publicación). Reutiliza cleanComment (u2,
  // ya "hackeado" arriba a body='hackeado'? no -- el intento de u1 de
  // arriba NO tocó el body real, sigue en 'qué buena foto'). ---
  await asUser(u2); // u2 escribió cleanComment
  await expectOk('comments_update_own: el propio autor real (u2) SÍ puede editar su comentario', async () => {
    await db.query(`update comments set body = 'editado de verdad', edited_at = now() where id = $1`, [cleanComment.id]);
  });
  const editedComment = (await db.query(`select body, edited_at from comments where id = $1`, [cleanComment.id])).rows[0];
  check('comments_update_own: el body real queda editado', editedComment.body === 'editado de verdad');
  check('comments_update_own: edited_at real queda marcado', editedComment.edited_at !== null);

  await asUser(u1); // u1 es el autor de la publicación, NO del comentario
  await db.query(`update comments set body = 'intento ajeno', edited_at = now() where id = $1`, [cleanComment.id]);
  const afterForeignEditAttempt = (await db.query(`select body from comments where id = $1`, [cleanComment.id])).rows[0];
  check('protect_comment_pin_only: el autor de la publicación (u1, no del comentario) NO puede editar el body ajeno (revertido)', afterForeignEditAttempt.body === 'editado de verdad');

  await asUser(u4); // tercero real, ni autor de la publicación ni del comentario
  await db.query(`update comments set body = 'intento de tercero' where id = $1`, [cleanComment.id]);
  const afterStrangerEditAttempt = (await db.query(`select body from comments where id = $1`, [cleanComment.id])).rows[0];
  check('protect_comment_pin_only: un tercero real (u4) NO puede editar el body ajeno (revertido)', afterStrangerEditAttempt.body === 'editado de verdad');

  await asUser(u2); // reel_comments: mismo espejo real
  await expectOk('reel_comments_update_own: el propio autor real (u2) SÍ puede editar su comentario de reel', async () => {
    await db.query(`update reel_comments set body = 'reel editado de verdad', edited_at = now() where id = $1`, [reelCommentToPin.id]);
  });
  const editedReelComment = (await db.query(`select body, edited_at from reel_comments where id = $1`, [reelCommentToPin.id])).rows[0];
  check('reel_comments_update_own: el body real queda editado', editedReelComment.body === 'reel editado de verdad');
  check('reel_comments_update_own: edited_at real queda marcado', editedReelComment.edited_at !== null);

  await asUser(u1); // u1 es el autor del reel, NO del comentario
  await db.query(`update reel_comments set body = 'intento ajeno' where id = $1`, [reelCommentToPin.id]);
  const afterForeignReelEditAttempt = (await db.query(`select body from reel_comments where id = $1`, [reelCommentToPin.id])).rows[0];
  check('protect_reel_comment_pin_only: el autor del reel (u1, no del comentario) NO puede editar el body ajeno (revertido)', afterForeignReelEditAttempt.body === 'reel editado de verdad');

  // --- posts.comments_disabled/reels.comments_disabled
  // (0086_disable_comments.sql): desactivar los comentarios de una
  // publicación real, comparado con Instagram/TikTok -- los comentarios
  // que ya existían se quedan, solo se cierra la puerta a comentarios
  // NUEVOS. Reutiliza mutedWordsPost (autor real u1) del bloque de más
  // arriba, que ya tiene comentarios reales de u2. ---
  await asUser(u1);
  await db.query(`update posts set comments_disabled = true where id = $1`, [mutedWordsPost.id]);
  await asUser(u2);
  await expectFail('comments_insert_own: con comentarios reales desactivados, u2 NO puede comentar una publicación ajena', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'intento con comentarios cerrados')`, [mutedWordsPost.id, u2]);
  });
  const commentsStillVisibleWhileDisabled = (await db.query(`select id from comments where post_id = $1`, [mutedWordsPost.id])).rows;
  check('comments_disabled: los comentarios reales previos SIGUEN existiendo, no se borran al desactivar', commentsStillVisibleWhileDisabled.length === 2);

  await asUser(u1);
  await db.query(`update posts set comments_disabled = false where id = $1`, [mutedWordsPost.id]);
  await asUser(u2);
  await expectOk('comments_insert_own: al reactivarlos de verdad, u2 SÍ vuelve a poder comentar', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'ya reactivado')`, [mutedWordsPost.id, u2]);
  });

  // Mismo espejo real en reel_comments -- reutiliza mutedWordsReel (autor
  // real u1) del bloque de más arriba.
  await asUser(u1);
  await db.query(`update reels set comments_disabled = true where id = $1`, [mutedWordsReel.id]);
  await asUser(u2);
  await expectFail('reel_comments_insert_own: con comentarios reales desactivados, u2 NO puede comentar un reel ajeno', async () => {
    await db.query(`insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'intento con comentarios cerrados')`, [mutedWordsReel.id, u2]);
  });

  // --- posts.reply_audience/reels.reply_audience (0097_reply_audience.sql):
  // "¿quién puede comentar?" real, comparado con Twitter/X/TikTok --
  // publicaciones/reels NUEVOS y propios de u1 (no reutiliza
  // mutedWordsPost/mutedWordsReel, ya usados arriba con reply_audience
  // por defecto 'everyone'). ---
  await asUser(u1);
  const followersOnlyPost = (await db.query(
    `insert into posts (author_id, caption, reply_audience) values ($1, 'solo comentan quienes me siguen', 'followers') returning id`, [u1]
  )).rows[0];
  await asUser(u4);
  await expectFail('comments_insert_own: u4 real, que NO sigue al autor, NO puede comentar (reply_audience = followers)', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'intento sin seguir')`, [followersOnlyPost.id, u4]);
  });
  await asUser(u2);
  await db.query(`insert into follows (follower_id, followee_id) values ($1, $2)`, [u2, u1]);
  await expectOk('comments_insert_own: u2 real, que SÍ sigue al autor, SÍ puede comentar (reply_audience = followers)', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'ahora sí te sigo')`, [followersOnlyPost.id, u2]);
  });
  await asUser(u1);
  await expectOk('comments_insert_own: el propio autor real (u1) SIEMPRE puede comentar su publicación, sea cual sea reply_audience', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'comento lo mío')`, [followersOnlyPost.id, u1]);
  });

  const mentionedOnlyPost = (await db.query(
    `insert into posts (author_id, caption, reply_audience) values ($1, 'solo comenta @maria99', 'mentioned') returning id`, [u1]
  )).rows[0];
  await asUser(u4);
  await expectFail('comments_insert_own: u4 real, al que NO se menciona en el caption, NO puede comentar (reply_audience = mentioned)', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'intento sin mención')`, [mentionedOnlyPost.id, u4]);
  });
  await asUser(u2);
  await expectOk('comments_insert_own: u2 real (@maria99), a quien SÍ se menciona en el caption, SÍ puede comentar (reply_audience = mentioned)', async () => {
    await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'me mencionaste, aquí estoy')`, [mentionedOnlyPost.id, u2]);
  });

  // Mismo espejo real en reel_comments.
  await asUser(u1);
  const followersOnlyReel = (await db.query(
    `insert into reels (author_id, video_url, reply_audience) values ($1, 'v3.mp4', 'followers') returning id`, [u1]
  )).rows[0];
  await asUser(u4);
  await expectFail('reel_comments_insert_own: u4 real, que NO sigue al autor, NO puede comentar el reel (reply_audience = followers)', async () => {
    await db.query(`insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'intento sin seguir')`, [followersOnlyReel.id, u4]);
  });
  await asUser(u2);
  await expectOk('reel_comments_insert_own: u2 real, que ya sigue al autor, SÍ puede comentar el reel (reply_audience = followers)', async () => {
    await db.query(`insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'te sigo, comento')`, [followersOnlyReel.id, u2]);
  });

  // --- starred_messages (0087_starred_messages.sql): mensajes destacados
  // reales, comparado con WhatsApp -- privado, sobre CUALQUIER mensaje
  // (propio o ajeno), en un chat 1:1 o de grupo. Reutiliza `chat`
  // (u1<->u2) para el 1:1; grupo propio y nuevo para el caso de grupo. ---
  await asUser(u1);
  const messageToStar = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje real para destacar') returning id`, [chat.id, u1]
  )).rows[0];

  await expectFail('starred_messages: el CHECK real impide destacar sin indicar ni mensaje 1:1 ni de grupo', async () => {
    await db.query(`insert into starred_messages (user_id) values ($1)`, [u1]);
  });
  await expectFail('starred_messages: el CHECK real impide destacar indicando un mensaje 1:1 Y uno de grupo a la vez', async () => {
    await db.query(`insert into starred_messages (user_id, message_id, group_message_id) values ($1, $2, $2)`, [u1, messageToStar.id]);
  });

  await asUser(u2);
  await expectOk('starred_messages_insert_own: u2 SÍ puede destacar un mensaje real ajeno de un chat 1:1 en el que participa', async () => {
    await db.query(`insert into starred_messages (user_id, message_id) values ($1, $2)`, [u2, messageToStar.id]);
  });
  const starredByU2 = (await db.query(`select id from starred_messages where user_id = $1`, [u2])).rows;
  check('starred_messages_select_own: u2 SÍ ve su propio destacado real', starredByU2.length === 1);

  await asUser(u1);
  const starredAsSender = (await db.query(`select id from starred_messages where message_id = $1`, [messageToStar.id])).rows;
  check('starred_messages_select_own: ni siquiera u1 (quien escribió el mensaje) puede ver que u2 lo destacó -- totalmente privado', starredAsSender.length === 0);

  await asUser(u4);
  await expectFail('starred_messages_insert_own: u4 real, que NO participa en el chat, NO puede destacar un mensaje ajeno', async () => {
    await db.query(`insert into starred_messages (user_id, message_id) values ($1, $2)`, [u4, messageToStar.id]);
  });

  await asUser(u2);
  await expectOk('starred_messages_delete_own: u2 SÍ puede quitar su propio destacado real', async () => {
    await db.query(`delete from starred_messages where user_id = $1 and message_id = $2`, [u2, messageToStar.id]);
  });
  const starredAfterRemoval = (await db.query(`select id from starred_messages where user_id = $1`, [u2])).rows;
  check('starred_messages_delete_own: la lista real de u2 queda vacía tras quitarlo', starredAfterRemoval.length === 0);

  // Mismo espejo real para un mensaje de GRUPO -- grupo propio y nuevo.
  const starGroupId = crypto.randomUUID();
  await asUser(u1);
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [starGroupId, 'Grupo para destacar', u1]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [starGroupId, u2]);
  const groupMessageToStar = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje de grupo real para destacar') returning id`, [starGroupId, u1]
  )).rows[0];

  await asUser(u2);
  await expectOk('starred_messages_insert_own: u2 SÍ puede destacar un mensaje de grupo real ajeno', async () => {
    await db.query(`insert into starred_messages (user_id, group_message_id) values ($1, $2)`, [u2, groupMessageToStar.id]);
  });
  const starredGroupMessage = (await db.query(`select id from starred_messages where user_id = $1 and group_message_id = $2`, [u2, groupMessageToStar.id])).rows;
  check('starred_messages_select_own: u2 SÍ ve su propio destacado real de grupo', starredGroupMessage.length === 1);

  await asUser(u3);
  await expectFail('starred_messages_insert_own: u3 real, que NO es miembro del grupo, NO puede destacar un mensaje de grupo ajeno', async () => {
    await db.query(`insert into starred_messages (user_id, group_message_id) values ($1, $2)`, [u3, groupMessageToStar.id]);
  });

  // --- messages.pinned_at/pinned_by / messages_update_pin
  // (0089_pin_message.sql): fijar un mensaje real (propio o ajeno) para
  // que aparezca destacado arriba del chat, VISIBLE PARA TODOS los
  // participantes -- a diferencia de starred_messages (arriba), totalmente
  // privado. Reutiliza `chat` (u1<->u2). ---
  await asUser(u1);
  const messageToPin = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje real para fijar') returning id`, [chat.id, u1]
  )).rows[0];

  await expectOk('messages_update_pin: el remitente real (u1) SÍ puede fijar su propio mensaje', async () => {
    await db.query(`update messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u1, messageToPin.id]);
  });
  const pinnedByU1 = (await db.query(`select pinned_at, pinned_by from messages where id = $1`, [messageToPin.id])).rows[0];
  check('messages_update_pin: pinned_at/pinned_by reales quedaron guardados', pinnedByU1.pinned_at !== null && pinnedByU1.pinned_by === u1);

  await asUser(u2);
  await expectOk('messages_update_pin: el OTRO participante real (u2), que no es el remitente, también SÍ puede fijar (mismo criterio que WhatsApp/Telegram)', async () => {
    await db.query(`update messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u2, messageToPin.id]);
  });
  const pinnedByU2 = (await db.query(`select pinned_by from messages where id = $1`, [messageToPin.id])).rows[0];
  check('messages_update_pin: pinned_by real pasó a ser u2, quien de verdad pidió el cambio', pinnedByU2.pinned_by === u2);

  await db.query(`update messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u1, messageToPin.id]);
  const pinnedBySpoofAttempt = (await db.query(`select pinned_by from messages where id = $1`, [messageToPin.id])).rows[0];
  check('protect_message_columns: u2 NO puede fijar el mensaje haciéndose pasar por u1 en pinned_by (revertido en silencio, no lanza)', pinnedBySpoofAttempt.pinned_by === u2);

  await db.query(`update messages set pinned_at = now(), pinned_by = $1, body = 'body colado vía fijado' where id = $2`, [u2, messageToPin.id]);
  const pinBodySmuggleAttempt = (await db.query(`select body from messages where id = $1`, [messageToPin.id])).rows[0];
  check('protect_message_columns: u2 (no es el remitente) NO puede colar un cambio de body aprovechando messages_update_pin', pinBodySmuggleAttempt.body === 'mensaje real para fijar');

  // Mismo hallazgo real ya documentado varias veces en este archivo: un
  // UPDATE gobernado solo por USING que no encuentra fila propia no lanza
  // excepción, solo afecta 0 filas -- se comprueba el estado real, no con
  // expectFail.
  await asUser(u4);
  await db.query(`update messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u4, messageToPin.id]);
  // messages_select también exige ser participante real del chat -- u4 no
  // vería ni la propia fila para comprobarlo, hace falta releer como u1.
  await asUser(u1);
  const pinAsStranger = (await db.query(`select pinned_by from messages where id = $1`, [messageToPin.id])).rows[0];
  check('messages_update_pin: u4 real, que NO participa en el chat, NO puede fijar un mensaje ajeno (0 filas afectadas, no un error)', pinAsStranger.pinned_by === u2);

  await asUser(u1);
  await expectOk('messages_update_pin: cualquier participante real (u1) también puede desfijarlo', async () => {
    await db.query(`update messages set pinned_at = null, pinned_by = null where id = $1`, [messageToPin.id]);
  });
  const unpinnedMessage = (await db.query(`select pinned_at, pinned_by from messages where id = $1`, [messageToPin.id])).rows[0];
  check('messages_update_pin: el mensaje real queda desfijado de verdad', unpinnedMessage.pinned_at === null && unpinnedMessage.pinned_by === null);

  // Mismo espejo real para un mensaje de GRUPO -- reutiliza `starGroupId`
  // (u1 creador, u2 miembro, u3 NO es miembro) de más arriba.
  await asUser(u1);
  const groupMessageToPin = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje de grupo real para fijar') returning id`, [starGroupId, u1]
  )).rows[0];

  // Nota de robustez de pruebas (no de producción), mismo hallazgo real ya
  // documentado más arriba para group_messages_update_own: esta es la
  // primera vez que este mensaje concreto pasa por un UPDATE bajo un rol
  // no-superusuario tras la redefinición de protect_group_message_identity
  // tras 0089 -- se calienta una vez bajo un rol con bypass total.
  await asSuperuser();
  await db.query(`update group_messages set body = body where id = $1`, [groupMessageToPin.id]);

  await asUser(u2);
  await expectOk('group_messages_update_pin: un miembro real (u2), que no es el remitente, SÍ puede fijar el mensaje de grupo', async () => {
    await db.query(`update group_messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u2, groupMessageToPin.id]);
  });
  const groupPinnedByU2 = (await db.query(`select pinned_at, pinned_by from group_messages where id = $1`, [groupMessageToPin.id])).rows[0];
  check('group_messages_update_pin: pinned_at/pinned_by reales quedaron guardados', groupPinnedByU2.pinned_at !== null && groupPinnedByU2.pinned_by === u2);

  await db.query(`update group_messages set pinned_by = $1 where id = $2`, [u1, groupMessageToPin.id]);
  const groupPinSpoofAttempt = (await db.query(`select pinned_by from group_messages where id = $1`, [groupMessageToPin.id])).rows[0];
  check('protect_group_message_identity: u2 NO puede fijar el mensaje de grupo haciéndose pasar por u1 en pinned_by (revertido en silencio, no lanza)', groupPinSpoofAttempt.pinned_by === u2);

  await db.query(`update group_messages set body = 'body de grupo colado vía fijado' where id = $1`, [groupMessageToPin.id]);
  const groupPinBodySmuggleAttempt = (await db.query(`select body from group_messages where id = $1`, [groupMessageToPin.id])).rows[0];
  check('protect_group_message_identity: u2 (no es el remitente) NO puede colar un cambio de body aprovechando group_messages_update_pin', groupPinBodySmuggleAttempt.body === 'mensaje de grupo real para fijar');

  await asUser(u3);
  await db.query(`update group_messages set pinned_at = now(), pinned_by = $1 where id = $2`, [u3, groupMessageToPin.id]);
  // group_messages_select también exige ser miembro real del grupo -- u3
  // no vería ni la propia fila para comprobarlo, hace falta releer como u1.
  await asUser(u1);
  const groupPinAsStranger = (await db.query(`select pinned_by from group_messages where id = $1`, [groupMessageToPin.id])).rows[0];
  check('group_messages_update_pin: u3 real, que NO es miembro del grupo, NO puede fijar un mensaje de grupo ajeno (0 filas afectadas, no un error)', groupPinAsStranger.pinned_by === u2);

  await asUser(u1);
  await expectOk('group_messages_update_pin: el remitente real (u1) también puede desfijarlo', async () => {
    await db.query(`update group_messages set pinned_at = null, pinned_by = null where id = $1`, [groupMessageToPin.id]);
  });
  const groupUnpinnedMessage = (await db.query(`select pinned_at, pinned_by from group_messages where id = $1`, [groupMessageToPin.id])).rows[0];
  check('group_messages_update_pin: el mensaje de grupo real queda desfijado de verdad', groupUnpinnedMessage.pinned_at === null && groupUnpinnedMessage.pinned_by === null);

  // --- calls (0079_calls.sql): videollamada/llamada de voz 1:1 real
  // desde un chat, comparado con WhatsApp/Messenger/Instagram. ---
  await asUser(u1);
  const call = (await db.query(
    `insert into calls (chat_id, caller_id, callee_id, kind) values ($1, $2, $3, 'video') returning id, status, room_name`,
    [chat.id, u1, u2]
  )).rows[0];
  check('calls_insert: room_name real autogenerado, no vacío', typeof call.room_name === 'string' && call.room_name.length > 0);
  check('calls: arranca en \'ringing\' por defecto', call.status === 'ringing');

  await asUser(u4);
  await expectFail('calls_insert: u4 NO puede crear una llamada real en un chat ajeno (u1<->u2)', async () => {
    await db.query(`insert into calls (chat_id, caller_id, callee_id, kind) values ($1, $2, $3, 'video')`, [chat.id, u4, u2]);
  });
  const callAsStranger = (await db.query(`select id from calls where id = $1`, [call.id])).rows;
  check('calls_select: un tercero real (u4) NO ve la llamada de otros', callAsStranger.length === 0);

  await asUser(u2);
  await expectOk('calls_update: el destinatario real (u2) SÍ puede aceptar la llamada', async () => {
    await db.query(`update calls set status = 'accepted' where id = $1`, [call.id]);
  });
  const acceptedAsCallee = (await db.query(`select status from calls where id = $1`, [call.id])).rows[0];
  check('calls_update: el estado real pasó a \'accepted\' de verdad', acceptedAsCallee.status === 'accepted');

  await asUser(u1);
  await db.query(`update calls set caller_id = $2, callee_id = $2, chat_id = $2, room_name = 'hackeado' where id = $1`, [call.id, u1]);
  const afterIdentityAttack = (await db.query(`select caller_id, callee_id, chat_id, room_name from calls where id = $1`, [call.id])).rows[0];
  check(
    'protect_call_identity: un UPDATE real NO puede redirigir caller_id/callee_id/chat_id/room_name de una llamada ajena a la identidad',
    afterIdentityAttack.caller_id === u1 && afterIdentityAttack.callee_id === u2 && afterIdentityAttack.chat_id === chat.id && afterIdentityAttack.room_name === call.room_name
  );

  await expectOk('calls_update: el emisor real (u1) SÍ puede colgar la llamada', async () => {
    await db.query(`update calls set status = 'ended', ended_at = now() where id = $1`, [call.id]);
  });
  const endedCall = (await db.query(`select status, ended_at from calls where id = $1`, [call.id])).rows[0];
  check('calls_update: la llamada real queda \'ended\' con ended_at real', endedCall.status === 'ended' && endedCall.ended_at !== null);

  // Bloqueo real: reutiliza el chat real u1<->u4 aún no probado.
  await asSuperuser();
  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [u4, u1]);
  const chatWithU4 = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [u1, u4])).rows[0];
  await asUser(u1);
  await expectFail('calls_insert: u1 NO puede llamar a u4 real, que le bloqueó', async () => {
    await db.query(`insert into calls (chat_id, caller_id, callee_id, kind) values ($1, $2, $3, 'audio')`, [chatWithU4.id, u1, u4]);
  });
  await asSuperuser();
  await db.query(`delete from blocks where blocker_id = $1 and blocked_id = $2`, [u4, u1]);

  // --- verification_requests/admin_set_verified (0080_verification_requests.sql):
  // verificación real (insignia azul), comparado con Instagram/Twitter/TikTok. ---
  await asUser(u1);
  const verifReq = (await db.query(
    `insert into verification_requests (profile_id, message) values ($1, 'Soy una cuenta real de interés público') returning id`,
    [u1]
  )).rows[0];

  await asUser(u2);
  const verifReqAsStranger = (await db.query(`select id from verification_requests where id = $1`, [verifReq.id])).rows;
  check('verification_requests_select_own: un tercero real (u2) NO ve la solicitud ajena de u1', verifReqAsStranger.length === 0);
  await expectFail('admin_set_verified: un usuario normal (u2, no admin) NO puede verificar a nadie', async () => {
    await db.query(`select admin_set_verified($1, true)`, [u1]);
  });

  await asUser(u3); // u3 sigue siendo admin desde el bloque de moderación de más arriba
  const verifReqAsAdmin = (await db.query(`select id from verification_requests where id = $1`, [verifReq.id])).rows;
  check('verification_requests_select_admin: un admin real (u3) SÍ ve la solicitud de u1', verifReqAsAdmin.length === 1);
  await expectOk('admin_set_verified: un admin real (u3) SÍ puede verificar a u1', async () => {
    await db.query(`select admin_set_verified($1, true)`, [u1]);
  });
  await expectOk('verification_requests_update_admin: un admin real (u3) SÍ puede aprobar la solicitud real', async () => {
    await db.query(`update verification_requests set status = 'approved' where id = $1`, [verifReq.id]);
  });

  await asUser(u1);
  const verifiedProfile = (await db.query(`select is_verified from profiles where id = $1`, [u1])).rows[0];
  check('admin_set_verified: is_verified real de u1 queda en true de verdad', verifiedProfile.is_verified === true);
  await db.query(`update profiles set is_verified = false where id = $1`, [u1]);
  const stillVerified = (await db.query(`select is_verified from profiles where id = $1`, [u1])).rows[0];
  check('protect_is_verified: un UPDATE directo del propio u1 NO puede quitarse la verificación real', stillVerified.is_verified === true);

  // --- chats.pinned_by_a/b + group_chat_members.pinned (0081_pin_chats.sql):
  // fijar un chat arriba de la lista, comparado con
  // WhatsApp/Telegram/Messenger -- mismo patrón exacto que
  // protect_chat_hidden_flags/protect_chat_muted_flags. ---
  await asUser(u2);
  await db.query(`update chats set pinned_by_b = true where id = $1`, [chat.id]);
  const pinnedByB = (await db.query(`select pinned_by_a, pinned_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_pinned_flags: u2 (user_b) SÍ fija su propia copia', pinnedByB.pinned_by_b === true && pinnedByB.pinned_by_a === false);

  await db.query(`update chats set pinned_by_a = true where id = $1`, [chat.id]);
  const stillNotPinnedByA = (await db.query(`select pinned_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_pinned_flags: u2 NO puede fijar la copia de u1 (revertido en silencio, no lanza)', stillNotPinnedByA.pinned_by_a === false);

  await asUser(u1);
  await db.query(`update chats set pinned_by_a = true where id = $1`, [chat.id]);
  const pinnedByA = (await db.query(`select pinned_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_pinned_flags: u1 (user_a) SÍ fija su propia copia', pinnedByA.pinned_by_a === true);

  // A diferencia de hidden_by_a/b, un mensaje nuevo real NO debe deshacer
  // el fijado -- mismo criterio que WhatsApp/Telegram.
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'sigue fijado')`, [chat.id, u1]);
  const stillPinnedAfterMessage = (await db.query(`select pinned_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('pinned_by_a/b: un mensaje nuevo real NO deshace el fijado (a diferencia de hidden_by_a/b)', stillPinnedAfterMessage.pinned_by_a === true);

  const pinGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [pinGroupId, 'Grupo para fijar', u1]);
  await expectOk('group_chat_members_update_own: u1 SÍ puede fijar su propia fila de membresía', async () => {
    await db.query(`update group_chat_members set pinned = true where group_chat_id = $1 and user_id = $2`, [pinGroupId, u1]);
  });
  const pinnedMembership = (await db.query(`select pinned from group_chat_members where group_chat_id = $1 and user_id = $2`, [pinGroupId, u1])).rows[0];
  check('group_chat_members.pinned: la fila real queda fijada', pinnedMembership.pinned === true);

  // --- chats.marked_unread_by_a/b + group_chat_members.marked_unread
  // (0088_mark_chat_unread.sql): marcar un chat como no leído
  // manualmente, comparado con WhatsApp/Telegram/Messenger -- mismo
  // patrón exacto que protect_chat_pinned_flags/protect_chat_muted_flags,
  // capa puramente personal por encima del estado real de lectura. ---
  await asUser(u2);
  await db.query(`update chats set marked_unread_by_b = true where id = $1`, [chat.id]);
  const markedUnreadByB = (await db.query(`select marked_unread_by_a, marked_unread_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_unread_flags: u2 (user_b) SÍ marca su propia copia real como no leída', markedUnreadByB.marked_unread_by_b === true && markedUnreadByB.marked_unread_by_a === false);

  await db.query(`update chats set marked_unread_by_a = true where id = $1`, [chat.id]);
  const stillNotMarkedByA = (await db.query(`select marked_unread_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_unread_flags: u2 NO puede marcar la copia real de u1 (revertido en silencio, no lanza)', stillNotMarkedByA.marked_unread_by_a === false);

  await asUser(u1);
  await db.query(`update chats set marked_unread_by_a = true where id = $1`, [chat.id]);
  const markedUnreadByA = (await db.query(`select marked_unread_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_unread_flags: u1 (user_a) SÍ marca su propia copia real como no leída', markedUnreadByA.marked_unread_by_a === true);

  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [pinGroupId, u2]);
  await asUser(u2);
  await expectOk('group_chat_members_update_own: u2 SÍ marca su propia fila real de membresía como no leída', async () => {
    await db.query(`update group_chat_members set marked_unread = true where group_chat_id = $1 and user_id = $2`, [pinGroupId, u2]);
  });
  const markedUnreadMembership = (await db.query(`select marked_unread from group_chat_members where group_chat_id = $1 and user_id = $2`, [pinGroupId, u2])).rows[0];
  check('group_chat_members.marked_unread: la fila real de u2 queda marcada como no leída', markedUnreadMembership.marked_unread === true);

  await asUser(u1);
  await db.query(`update group_chat_members set marked_unread = false where group_chat_id = $1 and user_id = $2`, [pinGroupId, u2]);
  const stillMarkedUnreadByCreator = (await db.query(`select marked_unread from group_chat_members where group_chat_id = $1 and user_id = $2`, [pinGroupId, u2])).rows[0];
  check('group_chat_members_update_own: u1 (creador del grupo) NO puede tocar la fila real de membresía de u2 (0 filas afectadas, no un error)', stillMarkedUnreadByCreator.marked_unread === true);

  // --- calls.group_chat_id + call_participants (0083_group_calls.sql):
  // videollamada de GRUPO real, comparado con WhatsApp/Messenger/Telegram
  // -- hueco aplazado explícitamente en 0079_calls.sql ("llamadas de
  // GRUPO quedan fuera de esta ronda"). Grupo propio y nuevo (no el
  // `group` usado desde el bloque de chats de grupo de más arriba, que
  // tiene un historial real de altas/bajas/expulsiones no trivial de
  // reconstruir aquí). ---
  const callGroupId = crypto.randomUUID();
  await asUser(u1);
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [callGroupId, 'Grupo para llamar', u1]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [callGroupId, u2]);

  const groupCall = (await db.query(
    `insert into calls (group_chat_id, caller_id, kind) values ($1, $2, 'video') returning id, status, room_name`,
    [callGroupId, u1]
  )).rows[0];
  check('calls_insert (grupo): room_name real autogenerado, no vacío', typeof groupCall.room_name === 'string' && groupCall.room_name.length > 0);
  // El RETURNING del propio INSERT reflejaba 'ringing' (el valor por
  // defecto de la columna en el momento de insertar) -- Postgres NO
  // recoge en RETURNING los cambios que un trigger AFTER INSERT hace
  // luego con una sentencia UPDATE aparte sobre la misma fila, solo los
  // que un trigger BEFORE hace sobre NEW dentro de la misma sentencia.
  // Hallazgo real de Postgres, no un fallo de populate_call_participants
  // -- se confirma con un SELECT aparte, que sí ve el estado ya escrito.
  const groupCallPersisted = (await db.query(`select status from calls where id = $1`, [groupCall.id])).rows[0];
  check('calls (grupo): arranca ya \'accepted\' a nivel global -- no hay un único destinatario que la acepte primero', groupCallPersisted.status === 'accepted');

  const callerParticipant = (await db.query(`select status, joined_at from call_participants where call_id = $1 and user_id = $2`, [groupCall.id, u1])).rows[0];
  check('populate_call_participants: el propio emisor real entra ya \'accepted\' con joined_at real', callerParticipant.status === 'accepted' && callerParticipant.joined_at !== null);
  const calleeParticipant = (await db.query(`select status, joined_at from call_participants where call_id = $1 and user_id = $2`, [groupCall.id, u2])).rows[0];
  check('populate_call_participants: el resto real de miembros del grupo entra \'ringing\' sin joined_at', calleeParticipant.status === 'ringing' && calleeParticipant.joined_at === null);

  await asUser(u4);
  await expectFail('calls_insert (grupo): u4 real, que NO es miembro del grupo, NO puede crear una llamada de grupo ajena', async () => {
    await db.query(`insert into calls (group_chat_id, caller_id, kind) values ($1, $2, 'audio')`, [callGroupId, u4]);
  });
  const groupCallAsStranger = (await db.query(`select id from calls where id = $1`, [groupCall.id])).rows;
  check('calls_select (grupo): un tercero real (u4), que no es participante, NO ve la llamada de grupo ajena', groupCallAsStranger.length === 0);
  const participantsAsStranger = (await db.query(`select user_id from call_participants where call_id = $1`, [groupCall.id])).rows;
  check('call_participants_select: un tercero real (u4) NO ve la lista de participantes de una llamada ajena', participantsAsStranger.length === 0);

  await asUser(u2);
  const groupCallAsParticipant = (await db.query(`select id from calls where id = $1`, [groupCall.id])).rows;
  check('calls_select (grupo): un participante real (u2) SÍ ve la llamada de grupo', groupCallAsParticipant.length === 1);
  const participantsAsParticipant = (await db.query(`select user_id, status from call_participants where call_id = $1`, [groupCall.id])).rows;
  check('call_participants_select: un participante real (u2) SÍ ve a TODOS los participantes, no solo su propia fila', participantsAsParticipant.length === 2);

  await expectOk('call_participants_update: u2 SÍ puede aceptar su propia participación real', async () => {
    await db.query(`update call_participants set status = 'accepted', joined_at = now() where call_id = $1 and user_id = $2`, [groupCall.id, u2]);
  });
  const u2Accepted = (await db.query(`select status from call_participants where call_id = $1 and user_id = $2`, [groupCall.id, u2])).rows[0];
  check('call_participants_update: la fila real de u2 queda \'accepted\'', u2Accepted.status === 'accepted');

  // RLS `using` filtra la fila ajena antes de tocarla -- 0 filas
  // afectadas, no un error (mismo criterio ya documentado varias veces en
  // este archivo, p. ej. group_chats_update_own para quien no es
  // creador).
  await db.query(`update call_participants set status = 'declined' where call_id = $1 and user_id = $2`, [groupCall.id, u1]);
  const u1StillAccepted = (await db.query(`select status from call_participants where call_id = $1 and user_id = $2`, [groupCall.id, u1])).rows[0];
  check('call_participants_update: u2 NO puede tocar la participación ajena de u1 (RLS real: 0 filas afectadas, no un error)', u1StillAccepted.status === 'accepted');

  await asUser(u1);
  await db.query(`update calls set caller_id = $2, group_chat_id = $3, chat_id = $2, room_name = 'hackeado-grupo' where id = $1`, [groupCall.id, u4, pinGroupId]);
  const groupCallAfterIdentityAttack = (await db.query(`select caller_id, group_chat_id, chat_id, room_name from calls where id = $1`, [groupCall.id])).rows[0];
  check(
    'protect_call_identity (grupo): un UPDATE real NO puede redirigir caller_id/group_chat_id/chat_id/room_name de una llamada de grupo',
    groupCallAfterIdentityAttack.caller_id === u1 && groupCallAfterIdentityAttack.group_chat_id === callGroupId && groupCallAfterIdentityAttack.chat_id === null && groupCallAfterIdentityAttack.room_name === groupCall.room_name
  );

  // --- profiles.read_receipts_enabled (0091_read_receipts_toggle.sql):
  // desactivar el recibo de lectura real, comparado con WhatsApp/
  // Instagram/Messenger -- columna normal sin trigger ni política nueva
  // (mismo criterio que compat_public/location_public): profiles_update_own
  // (0002_rls.sql) ya deja tocar cualquier columna propia, y
  // profiles_select_public (0002_rls.sql) ya expone el resto de columnas
  // de cualquier perfil visible -- aquí solo se confirma el valor por
  // defecto real y que de verdad es visible/editable, sin duplicar esas
  // pruebas genéricas. ---
  const defaultReceipts = (await db.query(`select read_receipts_enabled from profiles where id = $1`, [u2])).rows[0];
  check('profiles.read_receipts_enabled: arranca en true por defecto', defaultReceipts.read_receipts_enabled === true);

  await asUser(u2);
  await expectOk('profiles_update_own: u2 SÍ puede desactivar su propio recibo de lectura', async () => {
    await db.query(`update profiles set read_receipts_enabled = false where id = $1`, [u2]);
  });

  await asUser(u1);
  const receiptsSeenByOther = (await db.query(`select read_receipts_enabled from profiles where id = $1`, [u2])).rows[0];
  check('profiles_select_public: u1 real SÍ ve el recibo desactivado de u2 (necesario para no pintarle "Leído" en el chat)', receiptsSeenByOther.read_receipts_enabled === false);

  // --- posts.hide_like_count/reels.hide_like_count
  // (0094_hide_like_count.sql): ocultar el número de "me gusta" real,
  // comparado con Instagram/Facebook -- columna normal sin trigger ni
  // política nueva (mismo criterio que read_receipts_enabled arriba):
  // posts_write_own/reels_write_own (ya "for all") ya dejan al autor
  // tocar cualquier columna propia, y like_count sigue siendo pública
  // para cualquiera -- aquí solo se confirma el valor por defecto real y
  // que el propio autor de verdad puede activarlo. ---
  await asUser(u1);
  const likeCountPost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'publicación real para ocultar likes') returning id, hide_like_count`, [u1]
  )).rows[0];
  check('posts.hide_like_count: arranca en false por defecto', likeCountPost.hide_like_count === false);

  await expectOk('posts_write_own: u1 SÍ puede ocultar el número de me gusta de su propia publicación', async () => {
    await db.query(`update posts set hide_like_count = true where id = $1`, [likeCountPost.id]);
  });
  await asUser(u2);
  const likeCountSeenByOther = (await db.query(`select hide_like_count, like_count from posts where id = $1`, [likeCountPost.id])).rows[0];
  check('posts_select: u2 real SÍ ve hide_like_count activado (necesario para no pintarle el número en su cliente)', likeCountSeenByOther.hide_like_count === true);

  // --- posts.location_name (0095_post_location_tag.sql): etiqueta de
  // ubicación real (texto libre, no geocodificado), comparado con
  // Instagram/Facebook/Twitter/Snapchat -- sin RLS ni trigger nuevos
  // (posts_write_own ya cubre tocar la propia fila), solo se confirma el
  // límite real de longitud y que un texto normal SÍ se guarda. ---
  await asUser(u1);
  await expectOk('posts_write_own: u1 SÍ puede etiquetar su propia publicación con un nombre de sitio real', async () => {
    await db.query(`insert into posts (author_id, caption, location_name) values ($1, 'en el café', 'Café Comercial, Madrid')`, [u1]);
  });
  await expectFail('posts_location_name_length: más de 100 caracteres reales NO se puede guardar', async () => {
    await db.query(`insert into posts (author_id, caption, location_name) values ($1, 'texto', $2)`, [u1, 'x'.repeat(101)]);
  });

  // --- posts.is_sensitive/reels.is_sensitive (0096_sensitive_content.sql):
  // marcar contenido como sensible, comparado con Instagram/Twitter/
  // TikTok -- columna normal sin trigger ni política nueva (mismo
  // criterio que hide_like_count arriba): posts_write_own (ya "for all")
  // ya deja al autor tocar cualquier columna propia, y la fila sigue
  // siendo pública para cualquiera -- aquí solo se confirma el valor por
  // defecto real y que el propio autor de verdad puede activarlo. ---
  const sensitivePost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'publicación real sensible') returning id, is_sensitive`, [u1]
  )).rows[0];
  check('posts.is_sensitive: arranca en false por defecto', sensitivePost.is_sensitive === false);

  await expectOk('posts_write_own: u1 SÍ puede marcar su propia publicación como sensible', async () => {
    await db.query(`update posts set is_sensitive = true where id = $1`, [sensitivePost.id]);
  });
  await asUser(u2);
  const sensitiveSeenByOther = (await db.query(`select is_sensitive from posts where id = $1`, [sensitivePost.id])).rows[0];
  check('posts_select: u2 real SÍ ve is_sensitive activado (necesario para difuminarlo en su cliente)', sensitiveSeenByOther.is_sensitive === true);

  // --- post_notification_subscriptions (0098_post_notifications.sql):
  // activar avisos de publicaciones de una cuenta real ("🔔"), comparado
  // con Instagram/Twitter/X -- mismo criterio de privacidad real que
  // restricts_select_own: nadie más que el propio suscriptor puede leer
  // a quién se ha suscrito. ---
  await asUser(u2);
  await expectOk('post_notification_subscriptions_insert_own: u2 SÍ puede suscribirse real a los avisos de publicaciones de u1', async () => {
    await db.query(`insert into post_notification_subscriptions (subscriber_id, creator_id) values ($1, $2)`, [u2, u1]);
  });
  await asUser(u4);
  const subsSeenByStranger = (await db.query(`select 1 from post_notification_subscriptions where subscriber_id = $1`, [u2])).rows;
  check('post_notification_subscriptions_select_own: un tercero real (u4) NO puede ver a quién está suscrito u2', subsSeenByStranger.length === 0);
  await asUser(u2);
  await expectOk('post_notification_subscriptions_delete_own: u2 SÍ puede darse de baja real', async () => {
    await db.query(`delete from post_notification_subscriptions where subscriber_id = $1 and creator_id = $2`, [u2, u1]);
  });

  // --- messages.reply_to_message_id/group_messages.reply_to_message_id
  // (0102_message_reply.sql): responder a un mensaje concreto (cita),
  // comparado con WhatsApp/Telegram/iMessage/Instagram DM. Usuarios
  // NUEVOS a propósito (mismo motivo ya documentado varias veces esta
  // sesión con storyResponder/storyOtherViewer/hlAuthor): sin ninguna
  // relación previa de bloqueo que pueda contaminar esta prueba de
  // mensajería. ---
  await asSuperuser();
  const replyA = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const replyB = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Responde A'), ($2, 'Responde B')
     on conflict (id) do update set display_name = excluded.display_name`,
    [replyA, replyB]
  );
  const replyChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [replyA, replyB])).rows[0];

  await asUser(replyA);
  const originalMessage = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje original real') returning id`, [replyChat.id, replyA]
  )).rows[0];

  await asUser(replyB);
  const replyMessage = (await db.query(
    `insert into messages (chat_id, sender_id, body, reply_to_message_id) values ($1, $2, 'respondiendo de verdad', $3) returning id`,
    [replyChat.id, replyB, originalMessage.id]
  )).rows[0];
  const replySeen = (await db.query(`select reply_to_message_id from messages where id = $1`, [replyMessage.id])).rows[0];
  check('trg_check_reply_same_chat: SÍ deja responder a un mensaje real del mismo chat', replySeen.reply_to_message_id === originalMessage.id);

  // Chat ajeno real, sin ninguna relación con replyChat -- el mensaje
  // citado de ahí NUNCA debe poder colarse como respuesta en replyChat.
  await asUser(replyA);
  const otherChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [replyA, u4])).rows[0];
  const foreignMessage = (await db.query(
    `insert into messages (chat_id, sender_id, body) values ($1, $2, 'mensaje de otro chat real') returning id`, [otherChat.id, replyA]
  )).rows[0];
  await expectFail('trg_check_reply_same_chat: NO deja citar un mensaje real de OTRO chat distinto', async () => {
    await db.query(
      `insert into messages (chat_id, sender_id, body, reply_to_message_id) values ($1, $2, 'cita cruzada real', $3)`,
      [replyChat.id, replyA, foreignMessage.id]
    );
  });

  // Al borrar el mensaje citado, la respuesta real se queda sin él
  // (`on delete set null`) -- nunca bloqueada por el propio trigger de
  // integridad, que solo se dispara en INSERT.
  await asSuperuser();
  await db.query(`delete from messages where id = $1`, [originalMessage.id]);
  const replyAfterOriginalDeleted = (await db.query(`select reply_to_message_id from messages where id = $1`, [replyMessage.id])).rows[0];
  check('reply_to_message_id: al borrar el mensaje citado real, la respuesta se queda sin él (on delete set null), no bloqueada', replyAfterOriginalDeleted.reply_to_message_id === null);

  // Mismo espejo real en un chat de grupo.
  await asUser(replyA);
  const replyGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [replyGroupId, 'Grupo para responder', replyA]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [replyGroupId, replyB]);
  const originalGroupMessage = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje de grupo real') returning id`, [replyGroupId, replyA]
  )).rows[0];
  await asUser(replyB);
  await expectOk('trg_check_group_reply_same_chat: SÍ deja responder a un mensaje real del mismo grupo', async () => {
    await db.query(
      `insert into group_messages (group_chat_id, sender_id, body, reply_to_message_id) values ($1, $2, 'respondiendo en grupo de verdad', $3)`,
      [replyGroupId, replyB, originalGroupMessage.id]
    );
  });
  const otherGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [otherGroupId, 'Otro grupo real', replyB]);
  const foreignGroupMessage = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'mensaje de otro grupo real') returning id`, [otherGroupId, replyB]
  )).rows[0];
  await expectFail('trg_check_group_reply_same_chat: NO deja citar un mensaje real de OTRO grupo distinto', async () => {
    await db.query(
      `insert into group_messages (group_chat_id, sender_id, body, reply_to_message_id) values ($1, $2, 'cita cruzada real de grupo', $3)`,
      [replyGroupId, replyB, foreignGroupMessage.id]
    );
  });

  // --- broadcast_lists/broadcast_list_members (0103_broadcast_lists.sql):
  // listas de difusión reales, comparado con WhatsApp -- totalmente
  // privadas, ni siquiera el propio miembro añadido sabe que está en la
  // lista de otro (mismo criterio real que close_friends). Usuarios
  // NUEVOS a propósito (mismo motivo ya documentado varias veces esta
  // sesión): sin ninguna relación previa de bloqueo que pueda contaminar
  // esta prueba. ---
  await asSuperuser();
  const blOwner = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const blMemberA = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const blMemberB = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const blBlocked = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Difunde'), ($2, 'Miembro A'), ($3, 'Miembro B'), ($4, 'Bloqueado')
     on conflict (id) do update set display_name = excluded.display_name`,
    [blOwner, blMemberA, blMemberB, blBlocked]
  );

  await asUser(blOwner);
  const broadcastList = (await db.query(
    `insert into broadcast_lists (owner_id, name) values ($1, 'Amigos cercanos') returning id`, [blOwner]
  )).rows[0];
  await expectOk('broadcast_list_members_write_own: blOwner SÍ puede añadir miembros reales a su propia lista', async () => {
    await db.query(`insert into broadcast_list_members (broadcast_list_id, member_id) values ($1, $2), ($1, $3)`, [broadcastList.id, blMemberA, blMemberB]);
  });

  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [blOwner, blBlocked]);
  await expectFail('broadcast_list_members_write_own: blOwner NO puede añadir a alguien ya bloqueado real a su propia lista', async () => {
    await db.query(`insert into broadcast_list_members (broadcast_list_id, member_id) values ($1, $2)`, [broadcastList.id, blBlocked]);
  });

  await asUser(blMemberA);
  const listAsMember = (await db.query(`select id from broadcast_lists where id = $1`, [broadcastList.id])).rows;
  check('broadcast_lists_select_own: ni siquiera el propio miembro añadido (blMemberA) puede leer la lista de blOwner', listAsMember.length === 0);
  const broadcastMembersAsMember = (await db.query(`select id from broadcast_list_members where broadcast_list_id = $1`, [broadcastList.id])).rows;
  check('broadcast_list_members_select_own: ni siquiera el propio miembro añadido (blMemberA) puede leer con quién más se comparte la lista', broadcastMembersAsMember.length === 0);

  await expectFail('broadcast_list_members_write_own: un tercero real (blMemberA) NO puede añadirse a sí mismo a la lista ajena de blOwner', async () => {
    await db.query(`insert into broadcast_list_members (broadcast_list_id, member_id) values ($1, $2)`, [broadcastList.id, blMemberA]);
  });

  await asUser(blOwner);
  const membersAsOwner = (await db.query(`select member_id from broadcast_list_members where broadcast_list_id = $1`, [broadcastList.id])).rows;
  check('broadcast_list_members_select_own: blOwner SÍ ve los dos miembros reales de su propia lista', membersAsOwner.length === 2);
  await expectOk('broadcast_list_members_write_own: blOwner SÍ puede quitar un miembro real de su propia lista', async () => {
    await db.query(`delete from broadcast_list_members where broadcast_list_id = $1 and member_id = $2`, [broadcastList.id, blMemberB]);
  });
  const membersAfterRemoval = (await db.query(`select member_id from broadcast_list_members where broadcast_list_id = $1`, [broadcastList.id])).rows;
  check('broadcast_list_members_write_own: tras quitarlo de verdad, la lista se queda con un solo miembro real', membersAfterRemoval.length === 1);

  // --- comments.parent_comment_id/reel_comments.parent_comment_id
  // (0104_comment_replies.sql): responder a un comentario concreto (hilo
  // de un nivel), comparado con Instagram/Facebook/Twitter/TikTok.
  // Usuarios NUEVOS a propósito (mismo motivo ya documentado varias
  // veces esta sesión): sin ninguna relación previa que pueda
  // contaminar esta prueba. ---
  await asSuperuser();
  const crAuthor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const crCommenterA = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const crCommenterB = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Autor'), ($2, 'Comenta A'), ($3, 'Comenta B')
     on conflict (id) do update set display_name = excluded.display_name`,
    [crAuthor, crCommenterA, crCommenterB]
  );

  await asUser(crAuthor);
  const crPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real para hilos') returning id`, [crAuthor])).rows[0];
  const crReel = (await db.query(`insert into reels (author_id, video_url) values ($1, 'reel.mp4') returning id`, [crAuthor])).rows[0];

  await asUser(crCommenterA);
  const topLevelComment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'comentario real de primer nivel') returning id`, [crPost.id, crCommenterA]
  )).rows[0];

  await asUser(crCommenterB);
  const replyComment = (await db.query(
    `insert into comments (post_id, author_id, body, parent_comment_id) values ($1, $2, 'respondiendo de verdad', $3) returning id`,
    [crPost.id, crCommenterB, topLevelComment.id]
  )).rows[0];
  check('trg_check_comment_reply_same_post: SÍ deja responder a un comentario real de primer nivel', replyComment.id !== undefined);

  await expectFail('trg_check_comment_reply_same_post: NO deja responder a una respuesta real (límite real de un solo nivel)', async () => {
    await db.query(
      `insert into comments (post_id, author_id, body, parent_comment_id) values ($1, $2, 'intento de segundo nivel', $3)`,
      [crPost.id, crCommenterA, replyComment.id]
    );
  });

  await asUser(crAuthor);
  const crOtherPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'otra publicación real, sin relación') returning id`, [crAuthor])).rows[0];
  await asUser(crCommenterA);
  const foreignComment = (await db.query(
    `insert into comments (post_id, author_id, body) values ($1, $2, 'comentario real de otra publicación') returning id`, [crOtherPost.id, crCommenterA]
  )).rows[0];
  await expectFail('trg_check_comment_reply_same_post: NO deja citar un comentario real de OTRA publicación distinta', async () => {
    await db.query(
      `insert into comments (post_id, author_id, body, parent_comment_id) values ($1, $2, 'cita cruzada real', $3)`,
      [crPost.id, crCommenterA, foreignComment.id]
    );
  });

  await asSuperuser();
  await db.query(`delete from comments where id = $1`, [topLevelComment.id]);
  const replyAfterParentDeleted = (await db.query(`select id from comments where id = $1`, [replyComment.id])).rows;
  check('parent_comment_id: on delete cascade real -- borrar el comentario de primer nivel se lleva su respuesta con él', replyAfterParentDeleted.length === 0);

  // Mismo espejo real en reel_comments.
  await asUser(crCommenterA);
  const topLevelReelComment = (await db.query(
    `insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'comentario real de primer nivel en un reel') returning id`, [crReel.id, crCommenterA]
  )).rows[0];
  await asUser(crCommenterB);
  await expectOk('trg_check_reel_comment_reply_same_reel: SÍ deja responder a un comentario real de primer nivel en un reel', async () => {
    await db.query(
      `insert into reel_comments (reel_id, author_id, body, parent_comment_id) values ($1, $2, 'respondiendo en un reel de verdad', $3)`,
      [crReel.id, crCommenterB, topLevelReelComment.id]
    );
  });
  await asUser(crAuthor);
  const otherReel = (await db.query(`insert into reels (author_id, video_url) values ($1, 'otro_reel.mp4') returning id`, [crAuthor])).rows[0];
  await asUser(crCommenterB);
  const foreignReelComment = (await db.query(
    `insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'comentario real de otro reel') returning id`, [otherReel.id, crCommenterB]
  )).rows[0];
  await expectFail('trg_check_reel_comment_reply_same_reel: NO deja citar un comentario real de OTRO reel distinto', async () => {
    await db.query(
      `insert into reel_comments (reel_id, author_id, body, parent_comment_id) values ($1, $2, 'cita cruzada real de reel', $3)`,
      [crReel.id, crCommenterB, foreignReelComment.id]
    );
  });

  // --- messages.view_once/opened_at (0105_view_once_messages.sql): foto
  // para ver una vez, comparado con WhatsApp/Instagram DM/Snapchat.
  // Usuarios NUEVOS a propósito (mismo motivo ya documentado varias
  // veces esta sesión): sin ninguna relación previa que pueda contaminar
  // esta prueba. ---
  await asSuperuser();
  const voSender = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const voRecipient = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Envía'), ($2, 'Recibe')
     on conflict (id) do update set display_name = excluded.display_name`,
    [voSender, voRecipient]
  );
  const voChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [voSender, voRecipient])).rows[0];

  await asUser(voSender);
  await expectFail('messages_view_once_needs_media: una foto real "para ver una vez" SIN media_url no se puede enviar', async () => {
    await db.query(`insert into messages (chat_id, sender_id, body, view_once) values ($1, $2, 'solo texto', true)`, [voChat.id, voSender]);
  });

  const voMessage = (await db.query(
    `insert into messages (chat_id, sender_id, media_url, view_once) values ($1, $2, 'una_vez.jpg', true) returning id`, [voChat.id, voSender]
  )).rows[0];

  await asUser(voRecipient);
  const beforeOpening = (await db.query(`select media_url, opened_at from messages where id = $1`, [voMessage.id])).rows[0];
  check('messages_select: el destinatario real (voRecipient) SÍ ve la foto real antes de abrirla', beforeOpening.media_url === 'una_vez.jpg' && beforeOpening.opened_at === null);

  // RLS real (`messages_update_own`) SÍ deja pasar la sentencia del
  // propio remitente (sender_id = auth.uid() se cumple igual) -- no
  // lanza ninguna excepción real, el guardia de columnas la revierte en
  // silencio por debajo, mismo criterio real ya documentado para
  // read_at/body en 0049. Por eso se comprueba con expectOk + un check
  // aparte del valor real, nunca con expectFail.
  await asUser(voSender);
  await expectOk('messages_update_own: la sentencia del propio remitente (voSender) no lanza ninguna excepción real (RLS la deja pasar)', async () => {
    await db.query(`update messages set opened_at = now() where id = $1`, [voMessage.id]);
  });
  const afterSenderAttempt = (await db.query(`select opened_at, media_url from messages where id = $1`, [voMessage.id])).rows[0];
  check('protect_message_columns: pero el propio remitente real (voSender) NO consigue marcar su propia foto como abierta (revertido de verdad)', afterSenderAttempt.opened_at === null && afterSenderAttempt.media_url === 'una_vez.jpg');

  await asUser(voRecipient);
  await expectOk('messages_update_read: el destinatario real (voRecipient) SÍ puede abrir su foto real "para ver una vez"', async () => {
    await db.query(`update messages set opened_at = now() where id = $1`, [voMessage.id]);
  });
  const afterOpening = (await db.query(`select media_url, opened_at from messages where id = $1`, [voMessage.id])).rows[0];
  check('protect_message_columns: al abrirla de verdad, media_url real queda vacío del todo (nunca decidido por el cliente)', afterOpening.media_url === null && afterOpening.opened_at !== null);

  await asUser(voSender);
  const asSenderAfterOpening = (await db.query(`select media_url, opened_at from messages where id = $1`, [voMessage.id])).rows[0];
  check('protect_message_columns: el propio remitente real (voSender) tampoco puede volver a verla, aunque sí sabe que se abrió', asSenderAfterOpening.media_url === null && asSenderAfterOpening.opened_at !== null);

  await asUser(voRecipient);
  await db.query(`update messages set opened_at = null where id = $1`, [voMessage.id]);
  const afterUnopenAttempt = (await db.query(`select opened_at from messages where id = $1`, [voMessage.id])).rows[0];
  check('protect_message_columns: intentar "desabrir" una foto real ya consumida no lo consigue (irreversible de verdad)', afterUnopenAttempt.opened_at !== null);

  await db.query(`update messages set media_url = 'evil.jpg' where id = $1`, [voMessage.id]);
  const afterFakeMediaAttempt = (await db.query(`select media_url from messages where id = $1`, [voMessage.id])).rows[0];
  check('protect_message_columns: el destinatario real NO puede escribir un media_url falso directamente', afterFakeMediaAttempt.media_url === null);

  await asUser(voSender);
  const voSecondMessage = (await db.query(
    `insert into messages (chat_id, sender_id, media_url) values ($1, $2, 'normal.jpg') returning id`, [voChat.id, voSender]
  )).rows[0];
  await asUser(voRecipient);
  await db.query(`update messages set view_once = true where id = $1`, [voSecondMessage.id]);
  const viewOnceAfterAttempt = (await db.query(`select view_once from messages where id = $1`, [voSecondMessage.id])).rows[0];
  check('protect_message_columns: view_once real es inmutable tras el envío -- el destinatario NO puede activarlo después', viewOnceAfterAttempt.view_once === false);

  // --- posts.pinned_at (0106_pin_posts_to_profile.sql): fijar una
  // publicación en el perfil (hasta 3), comparado con Instagram.
  // Usuario NUEVO a propósito (mismo motivo ya documentado varias veces
  // esta sesión): sin ninguna publicación previa que pueda contaminar
  // el recuento real de fijadas. ---
  await asSuperuser();
  const pnAuthor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const pnStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Fija'), ($2, 'Ajeno')
     on conflict (id) do update set display_name = excluded.display_name`,
    [pnAuthor, pnStranger]
  );

  await asUser(pnAuthor);
  const pnPost1 = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real 1') returning id`, [pnAuthor])).rows[0];
  const pnPost2 = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real 2') returning id`, [pnAuthor])).rows[0];
  const pnPost3 = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real 3') returning id`, [pnAuthor])).rows[0];
  const pnPost4 = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real 4') returning id`, [pnAuthor])).rows[0];

  await expectOk('posts_write_own: pnAuthor SÍ puede fijar su primera publicación real', async () => {
    await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost1.id]);
  });
  await expectOk('posts_write_own: pnAuthor SÍ puede fijar su segunda publicación real', async () => {
    await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost2.id]);
  });
  await expectOk('posts_write_own: pnAuthor SÍ puede fijar su tercera publicación real', async () => {
    await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost3.id]);
  });
  await expectFail('trg_limit_pinned_posts: pnAuthor NO puede fijar una cuarta publicación real (límite real de 3)', async () => {
    await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost4.id]);
  });

  await expectOk('posts_write_own: pnAuthor SÍ puede desfijar una publicación real ya fijada', async () => {
    await db.query(`update posts set pinned_at = null where id = $1`, [pnPost1.id]);
  });
  await expectOk('trg_limit_pinned_posts: tras desfijar una, pnAuthor SÍ puede fijar la cuarta publicación real', async () => {
    await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost4.id]);
  });

  await asUser(pnStranger);
  await db.query(`update posts set pinned_at = now() where id = $1`, [pnPost1.id]);
  await asSuperuser();
  const pnPost1AfterStrangerAttempt = (await db.query(`select pinned_at from posts where id = $1`, [pnPost1.id])).rows[0];
  check('posts_write_own: un tercero real (pnStranger) NO puede fijar la publicación ajena de pnAuthor (0 filas afectadas por RLS, no un error)', pnPost1AfterStrangerAttempt.pinned_at === null);

  // --- group_chat_members.is_admin (0107_group_chat_admins.sql):
  // administradores reales de un chat de grupo, comparado con
  // WhatsApp/Telegram/Messenger. Usuarios NUEVOS a propósito (mismo
  // motivo ya documentado varias veces esta sesión): sin ninguna
  // relación previa que pueda contaminar esta prueba. ---
  await asSuperuser();
  const gaCreator = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gaMemberA = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gaMemberB = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gaMemberC = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gaMemberD = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Crea'), ($2, 'Miembro A'), ($3, 'Miembro B'), ($4, 'Miembro C'), ($5, 'Miembro D')
     on conflict (id) do update set display_name = excluded.display_name`,
    [gaCreator, gaMemberA, gaMemberB, gaMemberC, gaMemberD]
  );

  await asUser(gaCreator);
  const gaGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [gaGroupId, 'Grupo con admins reales', gaCreator]);
  const creatorMembershipRow = (await db.query(`select is_admin from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaCreator])).rows[0];
  check('add_group_creator_as_member: el creador real (gaCreator) se marca admin de un tirón al crear el grupo', creatorMembershipRow.is_admin === true);

  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2), ($1, $3), ($1, $4), ($1, $5)`, [gaGroupId, gaMemberA, gaMemberB, gaMemberC, gaMemberD]);

  await asUser(gaMemberA);
  await db.query(`update group_chat_members set is_admin = true where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA]);
  const afterSelfPromoteAttempt = (await db.query(`select is_admin from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA])).rows[0];
  check('protect_group_chat_member_identity: gaMemberA (sin ser admin real) NO consigue ascenderse a sí mismo (revertido de verdad)', afterSelfPromoteAttempt.is_admin === false);

  await asUser(gaMemberB);
  await db.query(`delete from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberC]);
  await asSuperuser();
  const cAfterNonAdminKickAttempt = (await db.query(`select 1 from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberC])).rows;
  check('group_chat_members_delete_by_admin: gaMemberB (sin ser admin real) NO puede expulsar a gaMemberC (0 filas afectadas por RLS, no un error)', cAfterNonAdminKickAttempt.length === 1);

  await asUser(gaCreator);
  await expectOk('group_chat_members_update_admin: el creador real (gaCreator) SÍ puede ascender a gaMemberA', async () => {
    await db.query(`update group_chat_members set is_admin = true where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA]);
  });

  await asUser(gaMemberA);
  await expectOk('group_chat_members_update_admin: un admin real NO creador (gaMemberA, recién ascendido) SÍ puede ascender a gaMemberB', async () => {
    await db.query(`update group_chat_members set is_admin = true where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberB]);
  });
  await expectOk('group_chat_members_delete_by_admin: un admin real NO creador (gaMemberA) SÍ puede expulsar a gaMemberC', async () => {
    await db.query(`delete from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberC]);
  });

  await asUser(gaMemberD);
  await db.query(`update group_chat_members set is_admin = false where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA]);
  const aAfterNonAdminDemoteAttempt = (await db.query(`select is_admin from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA])).rows[0];
  check('protect_group_chat_member_identity: gaMemberD (sin ser admin real) NO puede descender a gaMemberA (revertido de verdad)', aAfterNonAdminDemoteAttempt.is_admin === true);

  await asUser(gaMemberB);
  await expectOk('group_chat_members_update_admin: un admin real (gaMemberB) SÍ puede descender a otro admin real (gaMemberA)', async () => {
    await db.query(`update group_chat_members set is_admin = false where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA]);
  });
  const aAfterRealDemote = (await db.query(`select is_admin from group_chat_members where group_chat_id = $1 and user_id = $2`, [gaGroupId, gaMemberA])).rows[0];
  check('group_chat_members_update_admin: gaMemberA queda de verdad descendido tras el intento real de gaMemberB', aAfterRealDemote.is_admin === false);

  // --- group_chats_update_by_admin (0108_group_chat_rename_by_admin.sql):
  // renombrar el grupo/cambiar su foto también para admins, comparado
  // con WhatsApp/Telegram/Messenger. Usuarios NUEVOS a propósito (mismo
  // motivo ya documentado varias veces esta sesión): sin ninguna
  // relación previa que pueda contaminar esta prueba. ---
  await asSuperuser();
  const rnCreator = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const rnAdmin = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const rnStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Crea'), ($2, 'Admin'), ($3, 'Ajeno')
     on conflict (id) do update set display_name = excluded.display_name`,
    [rnCreator, rnAdmin, rnStranger]
  );

  await asUser(rnCreator);
  const rnGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [rnGroupId, 'Grupo para renombrar', rnCreator]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2), ($1, $3)`, [rnGroupId, rnAdmin, rnStranger]);
  await db.query(`update group_chat_members set is_admin = true where group_chat_id = $1 and user_id = $2`, [rnGroupId, rnAdmin]);

  await asUser(rnStranger);
  await db.query(`update group_chats set name = 'Intento ajeno real' where id = $1`, [rnGroupId]);
  const afterStrangerRename = (await db.query(`select name from group_chats where id = $1`, [rnGroupId])).rows[0];
  check('group_chats_update_by_admin: un miembro real que NO es admin (rnStranger) NO puede renombrar el grupo (0 filas afectadas por RLS, no un error)', afterStrangerRename.name === 'Grupo para renombrar');

  await asUser(rnAdmin);
  await expectOk('group_chats_update_by_admin: un admin real NO creador (rnAdmin) SÍ puede renombrar el grupo', async () => {
    await db.query(`update group_chats set name = 'Renombrado de verdad por un admin' where id = $1`, [rnGroupId]);
  });
  const afterRealRename = (await db.query(`select name from group_chats where id = $1`, [rnGroupId])).rows[0];
  check('group_chats_update_by_admin: el nombre real queda renombrado de verdad', afterRealRename.name === 'Renombrado de verdad por un admin');

  await db.query(`update group_chats set created_by = $1 where id = $2`, [rnAdmin, rnGroupId]);
  const afterHijackAttempt = (await db.query(`select created_by from group_chats where id = $1`, [rnGroupId])).rows[0];
  check('protect_group_chat_identity: un admin real (rnAdmin) NO puede robar el grupo reescribiendo created_by (revertido de verdad)', afterHijackAttempt.created_by === rnCreator);

  // --- apply_duel_compatibility (0109_duel_affects_compatibility.sql):
  // el resultado real de un duelo por fin ajusta chats.compatibility_score,
  // no solo la pantalla de resultado del duelo. Usuarios NUEVOS a
  // propósito, mismo motivo ya documentado varias veces esta sesión. ---
  await asSuperuser();
  const dcU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const dcU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'DuelUno'), ($2, 'DuelDos')
     on conflict (id) do update set display_name = excluded.display_name`,
    [dcU1, dcU2]
  );
  const dcChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id, compatibility_score`, [dcU1, dcU2])).rows[0];
  check('apply_duel_compatibility: el chat nuevo arranca en 50 por defecto', dcChat.compatibility_score === 50);

  // Simula exactamente lo que hace duel-ai/index.ts (handleScoreDuel):
  // un INSERT real en `duels` con `service_role`, con compatibility_delta
  // ya calculado por la IA -- el cliente nunca inserta aquí (0035).
  await db.query(
    `insert into duels (chat_id, initiator_id, opponent_id, questions, answers, compatibility_delta, explanation, is_public)
     values ($1, $2, $3, '[]', '[]', 10, 'primer duelo real', false)`,
    [dcChat.id, dcU1, dcU2]
  );
  const dcAfterFirst = (await db.query(`select compatibility_score from chats where id = $1`, [dcChat.id])).rows[0];
  check('apply_duel_compatibility: un duelo real con delta +10 sube el % real del chat a 60', dcAfterFirst.compatibility_score === 60);

  // Un segundo duelo con delta grande debe QUEDARSE en 100, no pasarse.
  await db.query(
    `insert into duels (chat_id, initiator_id, opponent_id, questions, answers, compatibility_delta, explanation, is_public)
     values ($1, $2, $3, '[]', '[]', 100, 'segundo duelo real', false)`,
    [dcChat.id, dcU1, dcU2]
  );
  const dcAfterHigh = (await db.query(`select compatibility_score from chats where id = $1`, [dcChat.id])).rows[0];
  check('apply_duel_compatibility: un delta real que se pasaría de 100 queda tope real en 100', dcAfterHigh.compatibility_score === 100);

  // Un tercer duelo con delta muy negativo debe QUEDARSE en 0, no bajar de ahí.
  await db.query(
    `insert into duels (chat_id, initiator_id, opponent_id, questions, answers, compatibility_delta, explanation, is_public)
     values ($1, $2, $3, '[]', '[]', -1000, 'tercer duelo real', false)`,
    [dcChat.id, dcU1, dcU2]
  );
  const dcAfterLow = (await db.query(`select compatibility_score from chats where id = $1`, [dcChat.id])).rows[0];
  check('apply_duel_compatibility: un delta real muy negativo queda tope real en 0, nunca negativo', dcAfterLow.compatibility_score === 0);

  // --- profiles.note_text/note_updated_at (0110_profile_notes.sql): nota
  // efímera real sobre el propio perfil, comparado con Instagram/Facebook
  // Messenger -- sin RLS ni trigger nuevos (profiles_update_own ya cubre
  // tocar la propia fila, profiles_select_public ya expone el resto de
  // columnas de cualquier perfil visible), solo se confirma el valor por
  // defecto, el límite real de longitud y que otro usuario real la ve. ---
  await asSuperuser();
  const npDefault = (await db.query(`select note_text, note_updated_at from profiles where id = $1`, [u1])).rows[0];
  check('profiles.note_text: arranca en null por defecto', npDefault.note_text === null && npDefault.note_updated_at === null);

  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede ponerse una nota real de perfil', async () => {
    await db.query(`update profiles set note_text = 'pensando en pizza 🍕', note_updated_at = now() where id = $1`, [u1]);
  });
  await expectFail('profiles_note_text_length: más de 60 caracteres reales NO se puede guardar', async () => {
    await db.query(`update profiles set note_text = $2 where id = $1`, [u1, 'x'.repeat(61)]);
  });

  await asUser(u2);
  const noteSeenByOther = (await db.query(`select note_text from profiles where id = $1`, [u1])).rows[0];
  check('profiles_select_public: u2 real SÍ ve la nota de u1 (para pintarla en la bandeja de chats)', noteSeenByOther.note_text === 'pensando en pizza 🍕');

  // --- seed_chat_compatibility (0111_seed_chat_compatibility_from_interests.sql):
  // el % real de un chat nuevo arranca de los intereses compartidos, no
  // de un 50 fijo -- quinto hallazgo de la auditoría de sistemas propios
  // de SOCIAL. Usuarios NUEVOS a propósito, mismo motivo ya documentado
  // varias veces esta sesión. ---
  await asSuperuser();
  const scU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU3 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU4 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU5 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU6 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU7 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scU8 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name, interests) values
     ($1, 'Sc1', ARRAY['viajes','musica']), ($2, 'Sc2', ARRAY['musica','cine']),
     ($3, 'Sc3', ARRAY['deportes']), ($4, 'Sc4', ARRAY[]::text[]),
     ($5, 'Sc5', ARRAY['arte']), ($6, 'Sc6', ARRAY['arte']),
     ($7, 'Sc7', ARRAY['a']), ($8, 'Sc8', ARRAY['b'])
     on conflict (id) do update set display_name = excluded.display_name, interests = excluded.interests`,
    [scU1, scU2, scU3, scU4, scU5, scU6, scU7, scU8]
  );

  await asUser(scU1);
  const scChatPartial = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning compatibility_score`, [scU1, scU2])).rows[0];
  check('seed_chat_compatibility: intersección parcial (1 de 3 intereses reales compartidos) da 33%, no 50', scChatPartial.compatibility_score === 33);

  await asUser(scU3);
  const scChatEmpty = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning compatibility_score`, [scU3, scU4])).rows[0];
  check('seed_chat_compatibility: sin intereses reales que comparar (uno de los dos vacío) conserva el 50 de siempre', scChatEmpty.compatibility_score === 50);

  await asUser(scU5);
  const scChatFull = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning compatibility_score`, [scU5, scU6])).rows[0];
  check('seed_chat_compatibility: los mismos intereses reales exactos dan 100%', scChatFull.compatibility_score === 100);

  // Hallazgo de seguridad real (encontrado diseñando esta migración, no
  // simulado): chats_insert (0002_rls.sql) nunca restringió qué columnas
  // fija el propio INSERT -- sin este trigger, un cliente modificado
  // podía insertar compatibility_score=100 de un tirón, sin haber
  // compartido ni un solo interés real.
  await asUser(scU7);
  const scChatHijack = (await db.query(`insert into chats (user_a_id, user_b_id, compatibility_score) values ($1, $2, 100) returning compatibility_score`, [scU7, scU8])).rows[0];
  check('seed_chat_compatibility: un compatibility_score=100 mandado directo por el cliente en el INSERT queda sobrescrito de verdad a 0 (sin intereses reales compartidos)', scChatHijack.compatibility_score === 0);

  // --- compatibility_votes_insert (0112_compatibility_votes_cooldown.sql):
  // cooldown real de 30s entre votos de la MISMA persona en el MISMO
  // chat, sexto hallazgo de la auditoría de sistemas propios de SOCIAL.
  // Usuarios NUEVOS a propósito, mismo motivo ya documentado varias
  // veces esta sesión. ---
  await asSuperuser();
  const cvU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const cvU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Cv1'), ($2, 'Cv2')
     on conflict (id) do update set display_name = excluded.display_name`,
    [cvU1, cvU2]
  );
  const cvChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [cvU1, cvU2])).rows[0];

  await asUser(cvU1);
  await expectOk('compatibility_votes_insert: cvU1 SÍ puede votar la primera vez', async () => {
    await db.query(`insert into compatibility_votes (chat_id, voter_id, delta) values ($1, $2, 10)`, [cvChat.id, cvU1]);
  });
  await expectFail('compatibility_votes_insert: cooldown real de 30s -- cvU1 NO puede votar otra vez de inmediato', async () => {
    await db.query(`insert into compatibility_votes (chat_id, voter_id, delta) values ($1, $2, 10)`, [cvChat.id, cvU1]);
  });

  await asUser(cvU2);
  await expectOk('compatibility_votes_insert: el cooldown es POR PERSONA -- cvU2 SÍ puede votar aunque cvU1 esté en cooldown', async () => {
    await db.query(`insert into compatibility_votes (chat_id, voter_id, delta) values ($1, $2, 10)`, [cvChat.id, cvU2]);
  });

  // --- post_polls/post_poll_votes/sync_post_poll_counts
  // (0113_post_polls.sql): encuesta real en una publicación normal,
  // comparado con Twitter/X/Facebook -- mismo diseño que
  // 0100_story_polls.sql, aplicado a posts. Usuarios NUEVOS a
  // propósito. ---
  await asSuperuser();
  const ppAuthor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const ppVoter1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const ppVoter2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const ppBlocked = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'PpAutor'), ($2, 'PpVoto1'), ($3, 'PpVoto2'), ($4, 'PpBloqueado')
     on conflict (id) do update set display_name = excluded.display_name`,
    [ppAuthor, ppVoter1, ppVoter2, ppBlocked]
  );

  await asUser(ppAuthor);
  const ppPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real con encuesta') returning id`, [ppAuthor])).rows[0];
  const ppPoll = (await db.query(
    `insert into post_polls (post_id, question, options) values ($1, '¿Pizza o sushi?', '["Pizza", "Sushi"]'::jsonb) returning id`, [ppPost.id]
  )).rows[0];
  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [ppAuthor, ppBlocked]);

  await asUser(ppVoter1);
  await expectFail('post_poll_votes_insert_own: un option_index real fuera de rango (2, solo hay 0 y 1) NO se puede votar', async () => {
    await db.query(`insert into post_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 2)`, [ppPoll.id, ppVoter1]);
  });
  await expectOk('post_poll_votes_insert_own: ppVoter1 SÍ puede votar de verdad ("Pizza")', async () => {
    await db.query(`insert into post_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 0)`, [ppPoll.id, ppVoter1]);
  });

  await asUser(ppVoter2);
  await expectOk('post_poll_votes_insert_own: ppVoter2 SÍ puede votar de verdad ("Sushi")', async () => {
    await db.query(`insert into post_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 1)`, [ppPoll.id, ppVoter2]);
  });
  const ppOwnVote = (await db.query(`select option_index from post_poll_votes where poll_id = $1 and voter_id = $2`, [ppPoll.id, ppVoter2])).rows;
  check('post_poll_votes_select: ppVoter2 SÍ ve su propio voto real', ppOwnVote.length === 1 && ppOwnVote[0].option_index === 1);
  const ppOtherVote = (await db.query(`select id from post_poll_votes where poll_id = $1 and voter_id = $2`, [ppPoll.id, ppVoter1])).rows;
  check('post_poll_votes_select: ppVoter2 NO ve el voto real de ppVoter1 (ni siquiera que existe)', ppOtherVote.length === 0);

  const ppCounts = (await db.query(`select vote_counts from post_polls where id = $1`, [ppPoll.id])).rows[0];
  check('sync_post_poll_counts: el reparto agregado real es visible para cualquier votante ([1,1])', JSON.stringify(ppCounts.vote_counts) === '[1,1]');

  await expectOk('post_poll_votes_update_own: ppVoter2 SÍ puede cambiar de opción real ("Pizza" en vez de "Sushi")', async () => {
    await db.query(`update post_poll_votes set option_index = 0 where poll_id = $1 and voter_id = $2`, [ppPoll.id, ppVoter2]);
  });
  const ppCountsAfterChange = (await db.query(`select vote_counts from post_polls where id = $1`, [ppPoll.id])).rows[0];
  check('sync_post_poll_counts: cambiar de opción reagrega bien de verdad ([2,0])', JSON.stringify(ppCountsAfterChange.vote_counts) === '[2,0]');

  await asUser(ppAuthor);
  const ppVotesAsAuthor = (await db.query(`select voter_id, option_index from post_poll_votes where poll_id = $1 order by voter_id`, [ppPoll.id])).rows;
  check('post_poll_votes_select: el autor real de la publicación SÍ ve TODOS los votos individuales, con quién los emitió', ppVotesAsAuthor.length === 2);

  await asUser(ppBlocked);
  await expectFail('post_poll_votes_insert_own: ppBlocked (bloqueado por el autor real) NO puede votar', async () => {
    await db.query(`insert into post_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 0)`, [ppPoll.id, ppBlocked]);
  });

  // --- reels.location_name (0114_reel_location_tag.sql): etiqueta de
  // ubicación real también en un reel, comparado con Instagram/TikTok --
  // mismo diseño exacto que posts.location_name (0095), sin RLS ni
  // trigger nuevos (reels_write_own ya cubre tocar la propia fila). ---
  await asUser(u1);
  await expectOk('reels_write_own: u1 SÍ puede etiquetar su propio reel con un nombre de sitio real', async () => {
    await db.query(`insert into reels (author_id, video_url, location_name) values ($1, 'https://example.com/v.mp4', 'Parque del Retiro, Madrid')`, [u1]);
  });
  await expectFail('reels_location_name_length: más de 100 caracteres reales NO se puede guardar', async () => {
    await db.query(`insert into reels (author_id, video_url, location_name) values ($1, 'https://example.com/v2.mp4', $2)`, [u1, 'x'.repeat(101)]);
  });

  // --- Mensajes que desaparecen real para todo el chat
  // (0115_disappearing_messages.sql), comparado con WhatsApp/Instagram
  // DM. Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const dmU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const dmU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Dm1'), ($2, 'Dm2')
     on conflict (id) do update set display_name = excluded.display_name`,
    [dmU1, dmU2]
  );
  const dmChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id, disappearing_seconds`, [dmU1, dmU2])).rows[0];
  check('chats.disappearing_seconds: arranca en null (desactivado) por defecto', dmChat.disappearing_seconds === null);

  await asUser(dmU1);
  await expectFail('chats_disappearing_seconds_valid: un valor real fuera de las 3 opciones (3600) NO se puede guardar', async () => {
    await db.query(`update chats set disappearing_seconds = 3600 where id = $1`, [dmChat.id]);
  });
  await expectOk('chats_update: dmU1 SÍ puede activar 24h reales de verdad', async () => {
    await db.query(`update chats set disappearing_seconds = 86400 where id = $1`, [dmChat.id]);
  });

  const dmMsg1 = (await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'este desaparece') returning id, disappear_at`, [dmChat.id, dmU1])).rows[0];
  check('set_message_disappear_at: un mensaje real enviado con el modo activo SÍ recibe un disappear_at real futuro', dmMsg1.disappear_at !== null && new Date(dmMsg1.disappear_at) > new Date());

  await expectOk('chats_update: dmU1 SÍ puede desactivar el modo real de nuevo', async () => {
    await db.query(`update chats set disappearing_seconds = null where id = $1`, [dmChat.id]);
  });
  const dmMsg2 = (await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'este NO desaparece') returning id, disappear_at`, [dmChat.id, dmU1])).rows[0];
  check('set_message_disappear_at: desactivar NO es retroactivo -- un mensaje real nuevo tras desactivar no recibe disappear_at', dmMsg2.disappear_at === null);

  await expectOk('protect_message_columns: dmU1 (el propio remitente) NO consigue tocar disappear_at directamente (revertido de verdad)', async () => {
    await db.query(`update messages set disappear_at = now() + interval '1 year' where id = $1`, [dmMsg1.id]);
  });
  const dmMsg1AfterAttempt = (await db.query(`select disappear_at from messages where id = $1`, [dmMsg1.id])).rows[0];
  check('protect_message_columns: disappear_at real queda igual tras el intento (inmutable de verdad)', new Date(dmMsg1AfterAttempt.disappear_at).getTime() === new Date(dmMsg1.disappear_at).getTime());

  await asUser(dmU2);
  const dmVisibleBeforeExpiry = (await db.query(`select id from messages where id = $1`, [dmMsg1.id])).rows;
  check('messages_select: dmU2 real SÍ ve el mensaje real antes de que caduque', dmVisibleBeforeExpiry.length === 1);

  // Simula el paso real del tiempo (sin cron real en este proyecto,
  // aviso de honestidad documentado en la propia migración): un
  // superusuario adelanta disappear_at al pasado, como haría un
  // temporizador real ya cumplido.
  await asSuperuser();
  await db.query(`update messages set disappear_at = now() - interval '1 minute' where id = $1`, [dmMsg1.id]);

  await asUser(dmU1);
  const dmHiddenFromSender = (await db.query(`select id from messages where id = $1`, [dmMsg1.id])).rows;
  check('messages_select: el propio remitente real (dmU1) YA NO ve su mensaje una vez caducado', dmHiddenFromSender.length === 0);
  await asUser(dmU2);
  const dmHiddenFromRecipient = (await db.query(`select id from messages where id = $1`, [dmMsg1.id])).rows;
  check('messages_select: dmU2 real tampoco lo ve una vez caducado', dmHiddenFromRecipient.length === 0);

  // --- profiles.muted_feed_keywords (0116_muted_feed_keywords.sql):
  // palabras silenciadas reales en el propio feed, comparado con
  // Twitter/X -- columna normal sin trigger ni política nueva (mismo
  // criterio que read_receipts_enabled/hide_like_count): solo se
  // confirma el valor por defecto real y que el propio dueño de verdad
  // puede guardarlas (profiles_update_own ya cubre tocar la propia
  // fila; el filtrado real ocurre en el cliente, nunca en RLS). ---
  const defaultMutedFeed = (await db.query(`select muted_feed_keywords from profiles where id = $1`, [u1])).rows[0];
  check('profiles.muted_feed_keywords: arranca en lista vacía por defecto', Array.isArray(defaultMutedFeed.muted_feed_keywords) && defaultMutedFeed.muted_feed_keywords.length === 0);

  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede guardar su propia lista real de palabras silenciadas', async () => {
    await db.query(`update profiles set muted_feed_keywords = ARRAY['spoiler', 'política'] where id = $1`, [u1]);
  });
  const mutedFeedAfterSave = (await db.query(`select muted_feed_keywords from profiles where id = $1`, [u1])).rows[0];
  check('profiles.muted_feed_keywords: la lista real queda guardada de verdad', JSON.stringify(mutedFeedAfterSave.muted_feed_keywords) === JSON.stringify(['spoiler', 'política']));

  // --- messages.delivered_at (0117_message_delivered_status.sql):
  // estado real de "Entregado", comparado con WhatsApp. ---
  await asSuperuser();
  const dvU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const dvU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Dv1'), ($2, 'Dv2') on conflict (id) do update set display_name = excluded.display_name`,
    [dvU1, dvU2]
  );
  const dvChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [dvU1, dvU2])).rows[0];
  await asUser(dvU1);
  const dvMsg = (await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'hola') returning id`, [dvChat.id, dvU1])).rows[0];

  await expectOk('protect_message_columns: dvU1 (remitente) NO consigue marcar su propio mensaje como entregado (revertido)', async () => {
    await db.query(`update messages set delivered_at = now() where id = $1`, [dvMsg.id]);
  });
  const dvAfterSenderAttempt = (await db.query(`select delivered_at from messages where id = $1`, [dvMsg.id])).rows[0];
  check('protect_message_columns: delivered_at sigue null tras el intento del propio remitente', dvAfterSenderAttempt.delivered_at === null);

  await asUser(dvU2);
  await expectOk('messages_update_read: dvU2 (destinatario) SÍ puede marcar el mensaje real como entregado', async () => {
    await db.query(`update messages set delivered_at = now() where id = $1`, [dvMsg.id]);
  });
  const dvAfterRecipient = (await db.query(`select delivered_at from messages where id = $1`, [dvMsg.id])).rows[0];
  check('messages_update_read: delivered_at real queda fijado por el destinatario', dvAfterRecipient.delivered_at !== null);

  // --- messages.deleted_for (0118_delete_message_for_me.sql): "Eliminar
  // para mí" real, comparado con WhatsApp. ---
  await asSuperuser();
  const dfU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const dfU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Df1'),($2,'Df2') on conflict (id) do update set display_name=excluded.display_name`, [dfU1, dfU2]);
  const dfChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1,$2) returning id`, [dfU1, dfU2])).rows[0];
  await asUser(dfU1);
  const dfMsg = (await db.query(`insert into messages (chat_id, sender_id, body) values ($1,$2,'hola real') returning id`, [dfChat.id, dfU1])).rows[0];

  await expectOk('protect_message_columns: dfU1 SÍ puede eliminar el mensaje real solo para sí mismo', async () => {
    await db.query(`update messages set deleted_for = array[$2]::uuid[] where id = $1`, [dfMsg.id, dfU1]);
  });
  const dfAfterOwnDelete = (await db.query(`select deleted_for from messages where id = $1`, [dfMsg.id])).rows[0];
  check('protect_message_columns: el array real queda con dfU1 tras "eliminar para mí"', dfAfterOwnDelete.deleted_for.length === 1 && dfAfterOwnDelete.deleted_for[0] === dfU1);

  await asUser(dfU2);
  const dfSeenByU2 = (await db.query(`select id from messages where id = $1`, [dfMsg.id])).rows;
  check('messages_select: dfU2 SIGUE viendo el mensaje real con normalidad (solo se borró para dfU1, resuelto en cliente)', dfSeenByU2.length === 1);

  await expectOk('protect_message_columns: dfU2 NO consigue quitar a dfU1 del array real (revertido)', async () => {
    await db.query(`update messages set deleted_for = array[]::uuid[] where id = $1`, [dfMsg.id]);
  });
  await asSuperuser();
  const dfAfterTamper = (await db.query(`select deleted_for from messages where id = $1`, [dfMsg.id])).rows[0];
  check('protect_message_columns: el array real sigue teniendo a dfU1 (nadie puede quitar a otro)', dfAfterTamper.deleted_for.length === 1);

  // --- profiles.last_active_at (0119_last_active_at.sql): "Últ. vez",
  // comparado con WhatsApp. ---
  const defaultLastActive = (await db.query(`select last_active_at from profiles where id = $1`, [u1])).rows[0];
  check('profiles.last_active_at: arranca en null por defecto', defaultLastActive.last_active_at === null);
  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede actualizar su propia last_active_at', async () => {
    await db.query(`update profiles set last_active_at = now() where id = $1`, [u1]);
  });
  await asUser(u2);
  const lastActiveSeenByOther = (await db.query(`select last_active_at from profiles where id = $1`, [u1])).rows[0];
  check('profiles_select_public: u2 real SÍ ve la last_active_at de u1', lastActiveSeenByOther.last_active_at !== null);

  // --- group_messages.deleted_for (0120_delete_group_message_for_me.sql):
  // "Eliminar para mí" también en grupo, mismo diseño que 0118. ---
  await asSuperuser();
  const gdU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gdU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Gd1'),($2,'Gd2') on conflict (id) do update set display_name=excluded.display_name`, [gdU1, gdU2]);
  await asUser(gdU1);
  const gdGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [gdGroupId, 'Grupo eliminar para mí', gdU1]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [gdGroupId, gdU2]);
  const gdMsg = (await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1,$2,'hola grupo real') returning id`, [gdGroupId, gdU1])).rows[0];

  await expectOk('protect_group_message_identity: gdU1 SÍ puede eliminar su mensaje real de grupo solo para sí mismo', async () => {
    await db.query(`update group_messages set deleted_for = array[$2]::uuid[] where id = $1`, [gdMsg.id, gdU1]);
  });
  const gdAfterOwnDelete = (await db.query(`select deleted_for from group_messages where id = $1`, [gdMsg.id])).rows[0];
  check('protect_group_message_identity: el array real de grupo queda con gdU1 tras "eliminar para mí"', gdAfterOwnDelete.deleted_for.length === 1 && gdAfterOwnDelete.deleted_for[0] === gdU1);

  await asUser(gdU2);
  const gdSeenByU2 = (await db.query(`select id from group_messages where id = $1`, [gdMsg.id])).rows;
  check('group_messages_select: gdU2 SIGUE viendo el mensaje real con normalidad (solo se borró para gdU1, resuelto en cliente)', gdSeenByU2.length === 1);

  await expectOk('protect_group_message_identity: gdU2 NO consigue quitar a gdU1 del array real de grupo (revertido)', async () => {
    await db.query(`update group_messages set deleted_for = array[]::uuid[] where id = $1`, [gdMsg.id]);
  });
  await asSuperuser();
  const gdAfterTamper = (await db.query(`select deleted_for from group_messages where id = $1`, [gdMsg.id])).rows[0];
  check('protect_group_message_identity: el array real de grupo sigue teniendo a gdU1 (nadie puede quitar a otro)', gdAfterTamper.deleted_for.length === 1);

  // --- messages.is_video/group_messages.is_video (0121_video_messages.sql):
  // vídeos reales en el chat, comparado con WhatsApp/Telegram. ---
  await asSuperuser();
  const vidU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const vidU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Vid1'),($2,'Vid2') on conflict (id) do update set display_name=excluded.display_name`, [vidU1, vidU2]);
  const vidChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1,$2) returning id`, [vidU1, vidU2])).rows[0];
  await asUser(vidU1);
  const vidMsg = (await db.query(
    `insert into messages (chat_id, sender_id, media_url, is_video) values ($1,$2,'https://example.com/v.mp4', true) returning id, is_video`,
    [vidChat.id, vidU1]
  )).rows[0];
  check('messages: un vídeo real se guarda con is_video=true', vidMsg.is_video === true);

  await asUser(vidU2);
  await expectOk('protect_message_columns: vidU2 (no remitente) NO consigue reescribir is_video (revertido)', async () => {
    await db.query(`update messages set is_video = false where id = $1`, [vidMsg.id]);
  });
  const vidAfterAttempt = (await db.query(`select is_video from messages where id = $1`, [vidMsg.id])).rows[0];
  check('protect_message_columns: is_video real sigue en true tras el intento ajeno', vidAfterAttempt.is_video === true);

  // --- profiles.share_last_active (0122_last_active_privacy_toggle.sql):
  // interruptor recíproco de privacidad para "Últ. vez", comparado con
  // WhatsApp/Telegram -- columna normal sin trigger ni política nueva
  // (mismo criterio que read_receipts_enabled arriba). ---
  const defaultShareLastActive = (await db.query(`select share_last_active from profiles where id = $1`, [vidU2])).rows[0];
  check('profiles.share_last_active: arranca en true por defecto', defaultShareLastActive.share_last_active === true);

  await asUser(vidU2);
  await expectOk('profiles_update_own: vidU2 SÍ puede desactivar su propia "Últ. vez"', async () => {
    await db.query(`update profiles set share_last_active = false where id = $1`, [vidU2]);
  });

  await asUser(vidU1);
  const shareLastActiveSeenByOther = (await db.query(`select share_last_active from profiles where id = $1`, [vidU2])).rows[0];
  check('profiles_select_public: vidU1 real SÍ ve la "Últ. vez" desactivada de vidU2 (necesario para no pintarla en el chat)', shareLastActiveSeenByOther.share_last_active === false);

  // --- group_chats.disappearing_seconds/group_messages.disappear_at
  // (0124_group_disappearing_messages.sql): mensajes que desaparecen
  // también en el chat de GRUPO, comparado con WhatsApp/Instagram DM --
  // cierra el alcance deliberado documentado en 0115. A diferencia del
  // 1:1, solo el creador/admin puede activarlo (group_chats_update_own,
  // 0057), no cualquier miembro. Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const gdisU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gdisU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Gdis1'),($2,'Gdis2') on conflict (id) do update set display_name=excluded.display_name`, [gdisU1, gdisU2]);
  await asUser(gdisU1);
  const gdisGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [gdisGroupId, 'Grupo desvanecimiento', gdisU1]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [gdisGroupId, gdisU2]);

  const gdisChat = (await db.query(`select disappearing_seconds from group_chats where id = $1`, [gdisGroupId])).rows[0];
  check('group_chats.disappearing_seconds: arranca en null (desactivado) por defecto', gdisChat.disappearing_seconds === null);

  await expectFail('group_chats_disappearing_seconds_valid: un valor real fuera de las 3 opciones (3600) NO se puede guardar', async () => {
    await db.query(`update group_chats set disappearing_seconds = 3600 where id = $1`, [gdisGroupId]);
  });

  await asUser(gdisU2);
  await db.query(`update group_chats set disappearing_seconds = 86400 where id = $1`, [gdisGroupId]);
  const gdisAfterMemberAttempt = (await db.query(`select disappearing_seconds from group_chats where id = $1`, [gdisGroupId])).rows[0];
  check('group_chats_update_own: gdisU2 (miembro normal, no creador) NO puede activar el modo (0 filas afectadas, no un error)', gdisAfterMemberAttempt.disappearing_seconds === null);

  await asUser(gdisU1);
  await expectOk('group_chats_update_own: el creador real (gdisU1) SÍ puede activar 24h reales', async () => {
    await db.query(`update group_chats set disappearing_seconds = 86400 where id = $1`, [gdisGroupId]);
  });

  const gdisMsg1 = (await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'este desaparece') returning id, disappear_at`, [gdisGroupId, gdisU1])).rows[0];
  check('set_group_message_disappear_at: un mensaje real de grupo enviado con el modo activo SÍ recibe un disappear_at real futuro', gdisMsg1.disappear_at !== null && new Date(gdisMsg1.disappear_at) > new Date());

  await expectOk('group_chats_update_own: el creador real SÍ puede desactivar el modo de nuevo', async () => {
    await db.query(`update group_chats set disappearing_seconds = null where id = $1`, [gdisGroupId]);
  });
  const gdisMsg2 = (await db.query(`insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'este NO desaparece') returning id, disappear_at`, [gdisGroupId, gdisU1])).rows[0];
  check('set_group_message_disappear_at: desactivar NO es retroactivo -- un mensaje real nuevo tras desactivar no recibe disappear_at', gdisMsg2.disappear_at === null);

  await expectOk('protect_group_message_identity: gdisU1 (el propio remitente) NO consigue tocar disappear_at directamente (revertido de verdad)', async () => {
    await db.query(`update group_messages set disappear_at = now() + interval '1 year' where id = $1`, [gdisMsg1.id]);
  });
  const gdisMsg1AfterAttempt = (await db.query(`select disappear_at from group_messages where id = $1`, [gdisMsg1.id])).rows[0];
  check('protect_group_message_identity: disappear_at real de grupo queda igual tras el intento (inmutable de verdad)', new Date(gdisMsg1AfterAttempt.disappear_at).getTime() === new Date(gdisMsg1.disappear_at).getTime());

  await asUser(gdisU2);
  const gdisVisibleBeforeExpiry = (await db.query(`select id from group_messages where id = $1`, [gdisMsg1.id])).rows;
  check('group_messages_select: gdisU2 real SÍ ve el mensaje real de grupo antes de que caduque', gdisVisibleBeforeExpiry.length === 1);

  await asSuperuser();
  await db.query(`update group_messages set disappear_at = now() - interval '1 minute' where id = $1`, [gdisMsg1.id]);

  await asUser(gdisU1);
  const gdisHiddenFromSender = (await db.query(`select id from group_messages where id = $1`, [gdisMsg1.id])).rows;
  check('group_messages_select: el propio remitente real (gdisU1) YA NO ve su mensaje de grupo una vez caducado', gdisHiddenFromSender.length === 0);
  await asUser(gdisU2);
  const gdisHiddenFromMember = (await db.query(`select id from group_messages where id = $1`, [gdisMsg1.id])).rows;
  check('group_messages_select: gdisU2 tampoco lo ve una vez caducado', gdisHiddenFromMember.length === 0);

  // --- saved_posts.collection_name (0125_saved_post_collections.sql):
  // colecciones reales para publicaciones guardadas, comparado con
  // Instagram -- columna normal sin trigger ni política nueva (mismo
  // criterio que muted_feed_keywords/hide_like_count):
  // saved_posts_select_own/insert_own/delete_own (0009) ya cubren
  // cualquier columna de la fila. Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const spU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const spU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Sp1'),($2,'Sp2') on conflict (id) do update set display_name=excluded.display_name`, [spU1, spU2]);
  const spPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'post para guardar') returning id`, [spU1])).rows[0];

  await asUser(spU1);
  const spSaved = (await db.query(
    `insert into saved_posts (post_id, user_id) values ($1, $2) returning id, collection_name`, [spPost.id, spU1]
  )).rows[0];
  check('saved_posts.collection_name: arranca en null (sin colección) por defecto', spSaved.collection_name === null);

  await expectFail('saved_posts_collection_name_length: un nombre real de más de 50 caracteres NO se puede guardar', async () => {
    await db.query(`update saved_posts set collection_name = $2 where id = $1`, [spSaved.id, 'x'.repeat(51)]);
  });

  await expectOk('saved_posts_insert_own/update: spU1 SÍ puede ponerle una colección real propia', async () => {
    await db.query(`update saved_posts set collection_name = 'Viajes' where id = $1`, [spSaved.id]);
  });
  const spAfterCollection = (await db.query(`select collection_name from saved_posts where id = $1`, [spSaved.id])).rows[0];
  check('saved_posts.collection_name: la colección real queda guardada de verdad', spAfterCollection.collection_name === 'Viajes');

  await asUser(spU2);
  const spSeenByOther = (await db.query(`select id from saved_posts where id = $1`, [spSaved.id])).rows;
  check('saved_posts_select_own: un tercero real (spU2) NO ve el guardado ajeno (privado, 0009_saved_posts.sql)', spSeenByOther.length === 0);

  // --- muted_accounts (0126_muted_accounts.sql): silenciar una cuenta
  // real sin dejar de seguir ni bloquear, comparado con Instagram/
  // Twitter/Facebook -- columnas normales, sin trigger ni función
  // security definer (filtrado real en cliente, nunca en RLS de
  // posts/reels). Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const maU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const maU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Ma1'),($2,'Ma2') on conflict (id) do update set display_name=excluded.display_name`, [maU1, maU2]);

  await asUser(maU1);
  await expectFail('muted_accounts: silenciarse a sí mismo (muter_id = muted_id) NO se puede guardar', async () => {
    await db.query(`insert into muted_accounts (muter_id, muted_id) values ($1, $1)`, [maU1]);
  });

  await expectOk('muted_accounts_insert_own: maU1 SÍ puede silenciar a maU2', async () => {
    await db.query(`insert into muted_accounts (muter_id, muted_id) values ($1, $2)`, [maU1, maU2]);
  });

  await asUser(maU2);
  const maSeenByMuted = (await db.query(`select muter_id from muted_accounts where muted_id = $1`, [maU2])).rows;
  check('muted_accounts_select_own: maU2 (la persona silenciada) NUNCA puede ver que la silenciaron -- mismo criterio real que restricts_select_own', maSeenByMuted.length === 0);

  await asUser(maU1);
  const maSeenByMuter = (await db.query(`select muted_id from muted_accounts where muter_id = $1`, [maU1])).rows;
  check('muted_accounts_select_own: maU1 SÍ ve su propia lista real de silenciados', maSeenByMuter.length === 1 && maSeenByMuter[0].muted_id === maU2);

  await expectOk('muted_accounts_delete_own: maU1 SÍ puede dejar de silenciar', async () => {
    await db.query(`delete from muted_accounts where muter_id = $1 and muted_id = $2`, [maU1, maU2]);
  });
  const maAfterUnmute = (await db.query(`select muted_id from muted_accounts where muter_id = $1`, [maU1])).rows;
  check('muted_accounts_delete_own: la lista real queda vacía tras dejar de silenciar', maAfterUnmute.length === 0);

  // --- post_reposts (0127_post_reposts.sql): repostear una publicación
  // real, comparado con Twitter/X/Facebook -- mismo patrón real que
  // likes (público, solo el propio autor del repost puede crear/
  // borrarlo). Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const rpU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const rpU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const rpU3 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Rp1'),($2,'Rp2'),($3,'Rp3') on conflict (id) do update set display_name=excluded.display_name`, [rpU1, rpU2, rpU3]);
  const rpPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'post para repostear') returning id`, [rpU1])).rows[0];

  await asUser(rpU2);
  await expectOk('post_reposts_insert_own: rpU2 SÍ puede repostear la publicación de rpU1', async () => {
    await db.query(`insert into post_reposts (post_id, user_id) values ($1, $2)`, [rpPost.id, rpU2]);
  });

  await asUser(rpU3);
  const rpSeenByThird = (await db.query(`select user_id from post_reposts where post_id = $1`, [rpPost.id])).rows;
  check('post_reposts_select: un tercero real (rpU3) SÍ ve quién reposteó (público, mismo criterio que likes)', rpSeenByThird.length === 1 && rpSeenByThird[0].user_id === rpU2);

  await db.query(`delete from post_reposts where post_id = $1 and user_id = $2`, [rpPost.id, rpU2]);
  const rpAfterForeignDelete = (await db.query(`select user_id from post_reposts where post_id = $1`, [rpPost.id])).rows;
  check('post_reposts_delete_own: un tercero real (rpU3) NO puede borrar el repost ajeno (0 filas afectadas, no un error)', rpAfterForeignDelete.length === 1);

  await asUser(rpU2);
  await expectOk('post_reposts_delete_own: el propio autor real del repost (rpU2) SÍ puede quitarlo', async () => {
    await db.query(`delete from post_reposts where post_id = $1 and user_id = $2`, [rpPost.id, rpU2]);
  });
  const rpAfterOwnDelete = (await db.query(`select user_id from post_reposts where post_id = $1`, [rpPost.id])).rows;
  check('post_reposts_delete_own: el repost real desaparece de verdad', rpAfterOwnDelete.length === 0);

  await asUser(rpU2);
  await db.query(`insert into post_reposts (post_id, user_id) values ($1, $2)`, [rpPost.id, rpU2]);
  await asUser(rpU1);
  // Segundo aviso real de verdad: el primer insert_own de arriba ya
  // generó uno -- este vuelve a repostear tras haberlo quitado, mismo
  // criterio real que un "me gusta"/"quitar me gusta"/"me gusta" genera
  // un aviso nuevo cada vez que se vuelve a dar.
  const rpNotif = (await db.query(`select kind, payload from notifications where recipient_id = $1 and kind = 'repost'`, [rpU1])).rows;
  check('notify_new_repost: el autor real de la publicación (rpU1) recibe un aviso real por cada repost (2: el primero + el de después de quitar y repostear)', rpNotif.length === 2 && rpNotif.every(n => n.payload.post_id === rpPost.id));

  // --- post_drafts (0128_post_drafts.sql): borrador de publicación no
  // enviada, comparado con Instagram/Twitter/X -- un borrador por usuario
  // (author_id PRIMARY KEY, upsert).
  await asSuperuser();
  const pdU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const pdU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Pd1'),($2,'Pd2') on conflict (id) do update set display_name=excluded.display_name`, [pdU1, pdU2]);

  await asUser(pdU1);
  await expectOk('post_drafts_insert_own: pdU1 SÍ puede guardar su propio borrador', async () => {
    await db.query(`insert into post_drafts (author_id, caption, location_name, is_sensitive) values ($1, 'a medio escribir...', 'Madrid', false)`, [pdU1]);
  });
  await asUser(pdU2);
  const pdSeenByOther = (await db.query(`select caption from post_drafts where author_id = $1`, [pdU1])).rows;
  check('post_drafts_select_own: pdU2 NO ve el borrador de pdU1 (0 filas)', pdSeenByOther.length === 0);

  await asUser(pdU1);
  await expectOk('post_drafts_update_own (upsert): pdU1 SÍ puede actualizar su propio borrador', async () => {
    await db.query(`update post_drafts set caption = 'texto final del borrador' where author_id = $1`, [pdU1]);
  });
  const pdUpdated = (await db.query(`select caption from post_drafts where author_id = $1`, [pdU1])).rows[0];
  check('post_drafts_update_own: el cambio real se guardó', pdUpdated.caption === 'texto final del borrador');

  await expectOk('post_drafts_delete_own: pdU1 SÍ puede descartar su propio borrador (p. ej. al publicar)', async () => {
    await db.query(`delete from post_drafts where author_id = $1`, [pdU1]);
  });
  const pdAfterDelete = (await db.query(`select caption from post_drafts where author_id = $1`, [pdU1])).rows;
  check('post_drafts_delete_own: el borrador real desaparece de verdad', pdAfterDelete.length === 0);

  // --- stories.shared_post_id/shared_post_author_id (0129_story_shared_post.sql):
  // compartir una publicación a tu Historia con atribución real al autor
  // original, comparado con Instagram/Facebook.
  await asSuperuser();
  const ssU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const ssU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`insert into profiles (id, display_name) values ($1,'Ss1'),($2,'Ss2') on conflict (id) do update set display_name=excluded.display_name`, [ssU1, ssU2]);
  const ssPost = (await db.query(`insert into posts (author_id, caption, media_url) values ($1, 'post con foto', 'https://x/photo.jpg') returning id`, [ssU1])).rows[0];

  await asUser(ssU2);
  await expectOk('stories_write_own: ssU2 SÍ puede compartir el post real de ssU1 como su propia historia', async () => {
    await db.query(
      `insert into stories (author_id, media_url, shared_post_id, shared_post_author_id) values ($1, $2, $3, $4)`,
      [ssU2, 'https://x/photo.jpg', ssPost.id, ssU1]
    );
  });
  await asUser(ssU1);
  const ssNotif = (await db.query(`select kind, payload from notifications where recipient_id = $1 and kind = 'story_share'`, [ssU1])).rows;
  check('notify_story_share: el autor real del post (ssU1) recibe un aviso real al compartirse a una historia', ssNotif.length === 1 && ssNotif[0].payload.post_id === ssPost.id);

  await asUser(ssU2);
  await expectOk('stories_write_own (control): una historia normal, sin post compartido, SIGUE funcionando sin disparar el trigger', async () => {
    await db.query(`insert into stories (author_id, media_url) values ($1, 'https://x/normal.jpg')`, [ssU2]);
  });
  await asUser(ssU1);
  const ssNotifAfterNormal = (await db.query(`select kind from notifications where recipient_id = $1 and kind = 'story_share'`, [ssU1])).rows;
  check('notify_story_share: una historia normal (sin shared_post_id) NO genera un aviso de más', ssNotifAfterNormal.length === 1);

  // --- messages.screenshot_taken_at (0130_message_screenshot_alert.sql):
  // aviso real de captura de pantalla, comparado con Snapchat. Usuarios
  // NUEVOS a propósito, mismo motivo ya documentado varias veces esta
  // sesión. ---
  await asSuperuser();
  const scSender = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const scRecipient = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'ScSender'), ($2, 'ScRecipient')
     on conflict (id) do update set display_name = excluded.display_name`,
    [scSender, scRecipient]
  );
  const scChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [scSender, scRecipient])).rows[0];
  const scMessage = (await db.query(
    `insert into messages (chat_id, sender_id, media_url, view_once) values ($1, $2, 'snap.jpg', true) returning id`, [scChat.id, scSender]
  )).rows[0];

  await asUser(scSender);
  await expectOk('messages_update_own: la sentencia del propio remitente no lanza ninguna excepción real (RLS la deja pasar)', async () => {
    await db.query(`update messages set screenshot_taken_at = now() where id = $1`, [scMessage.id]);
  });
  const scAfterSenderAttempt = (await db.query(`select screenshot_taken_at from messages where id = $1`, [scMessage.id])).rows[0];
  check('protect_message_columns: el propio remitente real (scSender) NO puede marcar su propio mensaje como capturado (revertido de verdad)', scAfterSenderAttempt.screenshot_taken_at === null);

  await asUser(scRecipient);
  await expectOk('messages_update_read: el destinatario real (scRecipient) SÍ puede marcar que hizo una captura real', async () => {
    await db.query(`update messages set screenshot_taken_at = now() where id = $1`, [scMessage.id]);
  });
  const scAfterRecipient = (await db.query(`select screenshot_taken_at from messages where id = $1`, [scMessage.id])).rows[0];
  check('protect_message_columns: screenshot_taken_at real queda fijado por el destinatario', scAfterRecipient.screenshot_taken_at !== null);

  await asUser(scSender);
  const scNotif = (await db.query(`select kind, payload from notifications where recipient_id = $1 and kind = 'screenshot'`, [scSender])).rows;
  check('notify_message_screenshot: el remitente real (scSender) recibe un aviso real de la captura', scNotif.length === 1 && scNotif[0].payload.chat_id === scChat.id);

  await asUser(scRecipient);
  await db.query(`update messages set screenshot_taken_at = null where id = $1`, [scMessage.id]);
  const scAfterUnmarkAttempt = (await db.query(`select screenshot_taken_at from messages where id = $1`, [scMessage.id])).rows[0];
  check('protect_message_columns: intentar "desmarcar" una captura real ya registrada no lo consigue (irreversible de verdad)', scAfterUnmarkAttempt.screenshot_taken_at !== null);

  // --- profile_visits (0132_profile_visits.sql): "quién visitó tu
  // perfil", comparado con LinkedIn/Twitter-X (Premium). Usuarios NUEVOS
  // a propósito, mismo motivo ya documentado varias veces esta sesión. ---
  await asSuperuser();
  const pvVisitor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const pvVisited = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const pvStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'PvVisitor'), ($2, 'PvVisited'), ($3, 'PvStranger')
     on conflict (id) do update set display_name = excluded.display_name`,
    [pvVisitor, pvVisited, pvStranger]
  );

  await asUser(pvVisitor);
  await expectFail('profile_visits: check visitor_id <> visited_id -- no se puede registrar una autovisita', async () => {
    await db.query(`insert into profile_visits (visitor_id, visited_id) values ($1, $1)`, [pvVisitor]);
  });
  await expectOk('profile_visits_insert_own: pvVisitor SÍ puede registrar su propia visita real al perfil de pvVisited', async () => {
    await db.query(`insert into profile_visits (visitor_id, visited_id) values ($1, $2)`, [pvVisitor, pvVisited]);
  });
  const pvSeenByVisitor = (await db.query(`select id from profile_visits where visitor_id = $1`, [pvVisitor])).rows;
  check('profile_visits_select_own: pvVisitor (el visitante) SÍ ve su propia fila (necesario para el upsert, sin UI real que lo muestre)', pvSeenByVisitor.length === 1);

  await asUser(pvVisited);
  const pvSeenByVisited = (await db.query(`select visitor_id from profile_visits where visited_id = $1`, [pvVisited])).rows;
  check('profile_visits_select_own: el visitado real (pvVisited) SÍ ve quién visitó su perfil', pvSeenByVisited.length === 1 && pvSeenByVisited[0].visitor_id === pvVisitor);

  await asUser(pvStranger);
  const pvSeenByStranger = (await db.query(`select visitor_id from profile_visits where visited_id = $1`, [pvVisited])).rows;
  check('profile_visits_select_own: un tercero real (pvStranger) NO ve la lista de visitas ajena', pvSeenByStranger.length === 0);

  await asUser(pvVisitor);
  await expectOk('profile_visits_update_own (upsert): una segunda visita real actualiza visited_at en vez de duplicar fila', async () => {
    await db.query(
      `insert into profile_visits (visitor_id, visited_id) values ($1, $2)
       on conflict (visitor_id, visited_id) do update set visited_at = now()`,
      [pvVisitor, pvVisited]
    );
  });
  await asUser(pvVisited);
  const pvAfterSecondVisit = (await db.query(`select visitor_id from profile_visits where visited_id = $1`, [pvVisited])).rows;
  check('profile_visits: una segunda visita real del mismo visitante NO duplica la fila (sigue habiendo 1)', pvAfterSecondVisit.length === 1);

  // --- group_message_polls/group_message_poll_votes
  // (0133_group_chat_polls.sql): encuesta real dentro de un chat de
  // GRUPO, comparado con WhatsApp. Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const gpU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gpU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const gpStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1,'Gp1'),($2,'Gp2'),($3,'GpStranger') on conflict (id) do update set display_name=excluded.display_name`,
    [gpU1, gpU2, gpStranger]
  );
  await asUser(gpU1);
  const gpGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [gpGroupId, 'Grupo con encuesta', gpU1]);
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [gpGroupId, gpU2]);

  const gpMessage = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, '¿Quedamos el sábado o el domingo?') returning id`,
    [gpGroupId, gpU1]
  )).rows[0];
  await expectOk('group_message_polls_insert_own: gpU1 (remitente real del mensaje) SÍ puede crear la encuesta', async () => {
    await db.query(
      `insert into group_message_polls (group_message_id, question, options) values ($1, $2, $3)`,
      [gpMessage.id, '¿Quedamos el sábado o el domingo?', JSON.stringify(['Sábado', 'Domingo'])]
    );
  });
  const gpPoll = (await db.query(`select id from group_message_polls where group_message_id = $1`, [gpMessage.id])).rows[0];

  await asUser(gpStranger);
  const gpSeenByStranger = (await db.query(`select id from group_message_polls where group_message_id = $1`, [gpMessage.id])).rows;
  check('group_message_polls_select: un tercero real (gpStranger, no miembro) NO ve la encuesta del grupo', gpSeenByStranger.length === 0);
  await expectFail('group_message_poll_votes_insert_own: un tercero real (gpStranger, no miembro) NO puede votar', async () => {
    await db.query(`insert into group_message_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 0)`, [gpPoll.id, gpStranger]);
  });

  await asUser(gpU2);
  await expectOk('group_message_poll_votes_insert_own: gpU2 (miembro real del grupo) SÍ puede votar', async () => {
    await db.query(`insert into group_message_poll_votes (poll_id, voter_id, option_index) values ($1, $2, 1)`, [gpPoll.id, gpU2]);
  });
  const gpCountsAfterVote = (await db.query(`select vote_counts from group_message_polls where id = $1`, [gpPoll.id])).rows[0];
  check('sync_group_message_poll_counts: vote_counts real refleja el voto de gpU2 (opción 1)', JSON.stringify(gpCountsAfterVote.vote_counts) === JSON.stringify([0, 1]));

  await asUser(gpU1);
  const gpVotesSeenByOtherMember = (await db.query(`select voter_id, option_index from group_message_poll_votes where poll_id = $1`, [gpPoll.id])).rows;
  check('group_message_poll_votes_select: gpU1 (otro miembro real, no autor de la encuesta) SÍ ve el voto individual de gpU2 -- criterio distinto de post_polls', gpVotesSeenByOtherMember.length === 1 && gpVotesSeenByOtherMember[0].voter_id === gpU2);

  await asUser(gpU2);
  await expectOk('group_message_poll_votes_update_own: gpU2 SÍ puede cambiar de opción real (voto 1 -> 0)', async () => {
    await db.query(`update group_message_poll_votes set option_index = 0 where poll_id = $1 and voter_id = $2`, [gpPoll.id, gpU2]);
  });
  const gpCountsAfterChange = (await db.query(`select vote_counts from group_message_polls where id = $1`, [gpPoll.id])).rows[0];
  check('sync_group_message_poll_counts: vote_counts real se recalcula tras cambiar de opción (0 -> ahora la opción 0)', JSON.stringify(gpCountsAfterChange.vote_counts) === JSON.stringify([1, 0]));

  // --- comment_likes.emoji/reel_comment_likes.emoji (0134_comment_reactions.sql):
  // reacciones con emoji variado a un comentario, comparado con Facebook.
  // Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const cxAuthor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const cxReactor = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const cxStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1,'CrAuthor'),($2,'CrReactor'),($3,'CrStranger') on conflict (id) do update set display_name=excluded.display_name`,
    [cxAuthor, cxReactor, cxStranger]
  );
  const cxPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'post con comentario') returning id`, [cxAuthor])).rows[0];
  await asUser(cxAuthor);
  const cxComment = (await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'comentario real') returning id`, [cxPost.id, cxAuthor])).rows[0];

  await asUser(cxReactor);
  await expectOk('comment_likes_insert_own: cxReactor SÍ puede reaccionar con el emoji real por defecto', async () => {
    await db.query(`insert into comment_likes (comment_id, user_id) values ($1, $2)`, [cxComment.id, cxReactor]);
  });
  const cxDefaultEmoji = (await db.query(`select emoji from comment_likes where comment_id = $1 and user_id = $2`, [cxComment.id, cxReactor])).rows[0];
  check('comment_likes.emoji: arranca en el emoji real por defecto (❤️)', cxDefaultEmoji.emoji === '❤️');

  await expectOk('comment_likes_update_own: cxReactor SÍ puede cambiar de reacción real (❤️ -> 😂)', async () => {
    await db.query(`update comment_likes set emoji = '😂' where comment_id = $1 and user_id = $2`, [cxComment.id, cxReactor]);
  });
  const cxChangedEmoji = (await db.query(`select emoji from comment_likes where comment_id = $1 and user_id = $2`, [cxComment.id, cxReactor])).rows[0];
  check('comment_likes.emoji: el cambio real de reacción queda guardado', cxChangedEmoji.emoji === '😂');

  await expectFail('comment_likes: un emoji real fuera de la lista permitida NO se puede guardar', async () => {
    await db.query(`update comment_likes set emoji = '🍕' where comment_id = $1 and user_id = $2`, [cxComment.id, cxReactor]);
  });

  await asUser(cxStranger);
  await db.query(`insert into comment_likes (comment_id, user_id) values ($1, $2)`, [cxComment.id, cxStranger]);
  await expectOk('protect_comment_like_identity: la sentencia de cxStranger no lanza ninguna excepción real (RLS la deja pasar sobre su propia fila)', async () => {
    await db.query(`update comment_likes set comment_id = $1, user_id = $2 where comment_id = $1 and user_id = $2`, [cxComment.id, cxStranger]);
  });
  // Intento real de robar la fila de cxReactor reasignándola a sí mismo -- RLS
  // ya lo bloquea (0 filas, la condición USING no encuentra la fila ajena),
  // así que ni siquiera llega al trigger; se confirma con el conteo final.
  await db.query(`update comment_likes set user_id = $1 where comment_id = $2 and user_id = $3`, [cxStranger, cxComment.id, cxReactor]);
  const cxReactionsAfterHijackAttempt = (await db.query(`select user_id, emoji from comment_likes where comment_id = $1`, [cxComment.id])).rows;
  check('protect_comment_like_identity: cxReactor sigue siendo dueño real de su propia reacción (no robada)', cxReactionsAfterHijackAttempt.some(r => r.user_id === cxReactor && r.emoji === '😂'));
  check('comment_likes: cxStranger también conserva su propia reacción real, sin duplicarse', cxReactionsAfterHijackAttempt.filter(r => r.user_id === cxStranger).length === 1);

  // --- get_chat_streak (0135_chat_streak.sql): racha real de días
  // consecutivos hablando en un chat 1:1, comparado con Snapchat
  // (Snapstreaks). Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const csU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const csU2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const csStranger = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1,'Cs1'),($2,'Cs2'),($3,'CsStranger') on conflict (id) do update set display_name=excluded.display_name`,
    [csU1, csU2, csStranger]
  );
  await asUser(csU1);
  const csChat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id`, [csU1, csU2])).rows[0];

  // 3 días anteriores reales (hoy-3, hoy-2, hoy-1) con mensaje real de
  // AMBOS -- racha real de 3, sin tocar el día de hoy todavía.
  for (const daysAgo of [3, 2, 1]) {
    await asUser(csU1);
    await db.query(
      `insert into messages (chat_id, sender_id, body, created_at) values ($1, $2, 'real', current_date - $3::int)`,
      [csChat.id, csU1, daysAgo]
    );
    await asUser(csU2);
    await db.query(
      `insert into messages (chat_id, sender_id, body, created_at) values ($1, $2, 'real', current_date - $3::int)`,
      [csChat.id, csU2, daysAgo]
    );
  }
  await asUser(csU1);
  const csStreakBeforeToday = (await db.query(`select get_chat_streak($1) as streak`, [csChat.id])).rows[0];
  check('get_chat_streak: racha real de 3 días anteriores, sin depender de que hoy ya se haya escrito', csStreakBeforeToday.streak === 3);

  // Hoy solo escribe csU1 -- la racha real NO sube todavía (hace falta
  // que las DOS partes escriban hoy), pero tampoco se pierde.
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'solo yo hoy')`, [csChat.id, csU1]);
  const csStreakOneSidedToday = (await db.query(`select get_chat_streak($1) as streak`, [csChat.id])).rows[0];
  check('get_chat_streak: un solo lado real escribiendo hoy no sube la racha todavía (sigue en 3)', csStreakOneSidedToday.streak === 3);

  // csU2 también escribe hoy -- AHORA sí sube a 4.
  await asUser(csU2);
  await db.query(`insert into messages (chat_id, sender_id, body) values ($1, $2, 'yo también hoy')`, [csChat.id, csU2]);
  const csStreakBothToday = (await db.query(`select get_chat_streak($1) as streak`, [csChat.id])).rows[0];
  check('get_chat_streak: racha real sube a 4 en cuanto las DOS partes escriben hoy', csStreakBothToday.streak === 4);

  // Un tercero real (csStranger, no participante del chat) obtiene 0 --
  // la propia función no encuentra su chat_id real entre user_a_id/user_b_id.
  await asUser(csStranger);
  const csStreakAsStranger = (await db.query(`select get_chat_streak($1) as streak`, [csChat.id])).rows[0];
  check('get_chat_streak: un tercero real que no participa en el chat obtiene 0', csStreakAsStranger.streak === 0);

  // --- compat_requests.highlighted (0136_compat_request_highlight.sql):
  // "Interés destacado" real al pedir ver compatibilidad, comparado con
  // Tinder/Bumble (Super Like). Usuarios NUEVOS a propósito. ---
  await asSuperuser();
  const chU1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const chTarget1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const chTarget2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1,'Ch1'),($2,'ChTarget1'),($3,'ChTarget2') on conflict (id) do update set display_name=excluded.display_name`,
    [chU1, chTarget1, chTarget2]
  );
  await asUser(chU1);
  await expectOk('compat_requests_insert: chU1 SÍ puede destacar su primera solicitud real del día', async () => {
    await db.query(`insert into compat_requests (requester_id, target_id, highlighted) values ($1, $2, true)`, [chU1, chTarget1]);
  });
  await expectFail('idx_compat_requests_highlighted_daily: chU1 NO puede destacar una segunda solicitud real el mismo día', async () => {
    await db.query(`insert into compat_requests (requester_id, target_id, highlighted) values ($1, $2, true)`, [chU1, chTarget2]);
  });
  await expectOk('compat_requests_insert: chU1 SÍ puede enviar una segunda solicitud real SIN destacar el mismo día', async () => {
    await db.query(`insert into compat_requests (requester_id, target_id, highlighted) values ($1, $2, false)`, [chU1, chTarget2]);
  });

  await asUser(chTarget1);
  const chNotif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'compat_request'`, [chTarget1])).rows;
  check('notify_new_compat_request: chTarget1 recibe el aviso real con highlighted=true en el payload', chNotif.length === 1 && chNotif[0].payload.highlighted === true);

  await asUser(chTarget2);
  const chNotif2 = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'compat_request'`, [chTarget2])).rows;
  check('notify_new_compat_request: chTarget2 recibe el aviso real con highlighted=false (la segunda, no destacada)', chNotif2.length === 1 && chNotif2[0].payload.highlighted === false);

  // --- profiles.location_updated_at (0137_location_updated_at.sql):
  // "hace X min" real en Find, comparado con Snapchat Map/Find My. ---
  const defaultLocationUpdatedAt = (await db.query(`select location_updated_at from profiles where id = $1`, [u1])).rows[0];
  check('profiles.location_updated_at: arranca en null por defecto', defaultLocationUpdatedAt.location_updated_at === null);
  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede actualizar su propia location_updated_at junto con last_lat/last_lng', async () => {
    await db.query(`update profiles set last_lat = 40.4, last_lng = -3.7, location_updated_at = now() where id = $1`, [u1]);
  });
  const afterLocationUpdate = (await db.query(`select last_lat, location_updated_at from profiles where id = $1`, [u1])).rows[0];
  check('profiles.location_updated_at: el cambio real queda guardado junto con la ubicación', Number(afterLocationUpdate.last_lat) === 40.4 && afterLocationUpdate.location_updated_at !== null);

  // --- chats.wallpaper_by_a/b + group_chat_members.wallpaper_key
  // (0139_chat_wallpaper.sql): fondo de chat por persona, comparado con
  // WhatsApp/Telegram/Messenger -- mismo patrón exacto que
  // protect_chat_pinned_flags/protect_chat_muted_flags. ---
  await asUser(u2);
  await db.query(`update chats set wallpaper_by_b = 'ocean' where id = $1`, [chat.id]);
  const wallpaperByB = (await db.query(`select wallpaper_by_a, wallpaper_by_b from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_wallpaper_flags: u2 (user_b) SÍ pone su propio fondo', wallpaperByB.wallpaper_by_b === 'ocean' && wallpaperByB.wallpaper_by_a === null);

  await db.query(`update chats set wallpaper_by_a = 'sunset' where id = $1`, [chat.id]);
  const stillNoWallpaperA = (await db.query(`select wallpaper_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_wallpaper_flags: u2 NO puede poner el fondo de u1 (revertido en silencio, no lanza)', stillNoWallpaperA.wallpaper_by_a === null);

  await asUser(u1);
  await db.query(`update chats set wallpaper_by_a = 'sunset' where id = $1`, [chat.id]);
  const wallpaperByA = (await db.query(`select wallpaper_by_a from chats where id = $1`, [chat.id])).rows[0];
  check('protect_chat_wallpaper_flags: u1 (user_a) SÍ pone su propio fondo', wallpaperByA.wallpaper_by_a === 'sunset');

  const wpGroupId = crypto.randomUUID();
  await db.query(`insert into group_chats (id, name, created_by) values ($1, $2, $3)`, [wpGroupId, 'Grupo para fondo', u1]);
  await expectOk('group_chat_members_update_own: u1 SÍ puede fijar el fondo de su propia fila de membresía', async () => {
    await db.query(`update group_chat_members set wallpaper_key = 'forest' where group_chat_id = $1 and user_id = $2`, [wpGroupId, u1]);
  });
  const wallpaperMembership = (await db.query(`select wallpaper_key from group_chat_members where group_chat_id = $1 and user_id = $2`, [wpGroupId, u1])).rows[0];
  check('group_chat_members.wallpaper_key: la fila real queda con el fondo elegido', wallpaperMembership.wallpaper_key === 'forest');

  // --- handle_new_user() ampliado (0140_birthday.sql): birth_date real
  // ya se le pedía al usuario al registrarse para verificar la edad
  // (AuthViewModel.kt/.swift), pero se descartaba -- ahora viaja en
  // raw_user_meta_data igual que display_name. ---
  await asSuperuser();
  const bdUser = (await db.query(
    `insert into auth.users (raw_user_meta_data) values ($1) returning id`,
    [JSON.stringify({ display_name: 'Con fecha', birth_date: '2000-05-15' })]
  )).rows[0].id;
  const bdProfile = (await db.query(`select display_name, birth_date from profiles where id = $1`, [bdUser])).rows[0];
  const bdISO = bdProfile.birth_date instanceof Date ? bdProfile.birth_date.toISOString() : String(bdProfile.birth_date);
  check('handle_new_user: birth_date real de raw_user_meta_data llega a profiles', bdProfile.birth_date !== null && bdISO.startsWith('2000-05-15'));
  check('handle_new_user: display_name real sigue funcionando igual que antes', bdProfile.display_name === 'Con fecha');

  const noBdUser = (await db.query(
    `insert into auth.users (raw_user_meta_data) values ($1) returning id`,
    [JSON.stringify({ display_name: 'Sin fecha' })]
  )).rows[0].id;
  const noBdProfile = (await db.query(`select birth_date from profiles where id = $1`, [noBdUser])).rows[0];
  check('handle_new_user: sin birth_date real en los metadatos, queda en null (no rompe el registro)', noBdProfile.birth_date === null);

  // --- profiles.birth_date/show_birthday + is_birthday_today()
  // (0140_birthday.sql): insignia real de cumpleaños (🎂), comparado con
  // Instagram/Facebook -- sin cron, calculado al leer. ---
  await asUser(u1);
  await expectOk('profiles_update_own: u1 SÍ puede fijar su propia fecha de nacimiento', async () => {
    await db.query(`update profiles set birth_date = current_date where id = $1`, [u1]);
  });
  const birthdayToday = (await db.query(`select is_birthday_today($1) as v`, [u1])).rows[0];
  check('is_birthday_today: hoy real SÍ cuenta como cumpleaños', birthdayToday.v === true);

  await db.query(`update profiles set birth_date = current_date - interval '1 day' where id = $1`, [u1]);
  const birthdayYesterday = (await db.query(`select is_birthday_today($1) as v`, [u1])).rows[0];
  check('is_birthday_today: ayer real NO cuenta como cumpleaños', birthdayYesterday.v === false);

  await db.query(`update profiles set birth_date = current_date, show_birthday = false where id = $1`, [u1]);
  const birthdayHidden = (await db.query(`select is_birthday_today($1) as v`, [u1])).rows[0];
  check('is_birthday_today: show_birthday=false real oculta la insignia aunque sea hoy', birthdayHidden.v === false);
  await db.query(`update profiles set show_birthday = true where id = $1`, [u1]);

  const birthdayNoDate = (await db.query(`select is_birthday_today($1) as v`, [u2])).rows[0];
  check('is_birthday_today: sin fecha de nacimiento real, nunca cuenta como cumpleaños', birthdayNoDate.v === false);

  // --- scheduled_posts + publish_due_scheduled_posts() (0141_scheduled_posts.sql):
  // programar la publicación de un post real, comparado con Instagram/
  // Twitter-X/TikTok. SIN pg_cron -- publicado al llamar la función,
  // mismo criterio "catch up" ya explicado en la propia migración. ---
  await asUser(u1);
  const duePostId = (await db.query(
    `insert into scheduled_posts (author_id, caption, scheduled_for) values ($1, 'ya vencido', now() - interval '1 minute') returning id`,
    [u1]
  )).rows[0].id;
  const futurePostId = (await db.query(
    `insert into scheduled_posts (author_id, caption, scheduled_for) values ($1, 'todavía no', now() + interval '1 day') returning id`,
    [u1]
  )).rows[0].id;

  const published = (await db.query(`select * from publish_due_scheduled_posts()`)).rows;
  check('publish_due_scheduled_posts: publica el post real ya vencido', published.length === 1 && published[0].caption === 'ya vencido');

  const stillScheduled = (await db.query(`select id from scheduled_posts where id = $1`, [futurePostId])).rows;
  check('publish_due_scheduled_posts: el post real FUTURO no se toca todavía', stillScheduled.length === 1);

  const goneFromScheduled = (await db.query(`select id from scheduled_posts where id = $1`, [duePostId])).rows;
  check('publish_due_scheduled_posts: el post real vencido ya no está en scheduled_posts', goneFromScheduled.length === 0);

  const nowInPosts = (await db.query(`select caption from posts where author_id = $1 and caption = 'ya vencido'`, [u1])).rows;
  check('publish_due_scheduled_posts: el post real vencido SÍ aparece en posts', nowInPosts.length === 1);

  await asUser(u2);
  const u2SeesU1Scheduled = (await db.query(`select id from scheduled_posts where id = $1`, [futurePostId])).rows;
  check('scheduled_posts_own: u2 NO puede leer los posts programados reales de u1', u2SeesU1Scheduled.length === 0);
  const u2Published = (await db.query(`select * from publish_due_scheduled_posts()`)).rows;
  check('publish_due_scheduled_posts: u2 NO publica nada ajeno (no tiene posts programados propios)', u2Published.length === 0);

  // --- post_collaborators (0142_post_collaborators.sql): publicación
  // colaborativa real ("Collab"), comparado con Instagram. ---
  await asUser(u1);
  const collabPostId = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'post colaborativo real') returning id`,
    [u1]
  )).rows[0].id;
  await expectOk('post_collaborators_insert: u1 (autor real) SÍ puede invitar a u2 como colaborador', async () => {
    await db.query(`insert into post_collaborators (post_id, user_id) values ($1, $2)`, [collabPostId, u2]);
  });
  await expectFail('post_collaborators_insert: u3 (NO autor real) NO puede invitar a nadie a ese post', async () => {
    await asUser(u3);
    await db.query(`insert into post_collaborators (post_id, user_id) values ($1, $2)`, [collabPostId, crypto.randomUUID()]);
  });
  await asUser(u1);

  await asUser(u2);
  const collabNotif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'post_collab_invite'`, [u2])).rows;
  check('notify_post_collab_invite: u2 recibe el aviso real de invitación', collabNotif.length === 1 && collabNotif[0].payload.post_id === collabPostId);

  await expectOk('post_collaborators_update: u2 (invitado real) SÍ puede aceptar su propia invitación', async () => {
    await db.query(`update post_collaborators set status = 'accepted', responded_at = now() where post_id = $1 and user_id = $2`, [collabPostId, u2]);
  });
  const acceptedRow = (await db.query(`select status from post_collaborators where post_id = $1 and user_id = $2`, [collabPostId, u2])).rows[0];
  check('post_collaborators: el estado real queda en accepted', acceptedRow.status === 'accepted');

  await db.query(`update post_collaborators set post_id = $1 where post_id = $2 and user_id = $3`, [crypto.randomUUID(), collabPostId, u2]);
  const stillSamePost = (await db.query(`select post_id from post_collaborators where user_id = $1 and post_id = $2`, [u2, collabPostId])).rows;
  check('protect_post_collaborator_identity: u2 NO puede trasladar su fila real a otro post_id (revertido en silencio)', stillSamePost.length === 1);

  await asUser(u3);
  const u3SeesInvite = (await db.query(`select post_id from post_collaborators where post_id = $1 and user_id = $2`, [collabPostId, u2])).rows;
  check('post_collaborators_select: u3 (ajeno real) NO ve la invitación de otra persona', u3SeesInvite.length === 0);

  // --- stories.caption + notify_mentions_in_story (0143_story_caption_mentions.sql):
  // texto sobre la Historia + @menciones reales ahí, comparado con
  // Instagram/TikTok/Snapchat. Reutiliza extract_mentioned_profile_ids
  // ya probada por post/reel/comment/reel_comment. ---
  await asUser(u1);
  await expectOk('stories_write_own: u1 SÍ puede publicar una historia real con caption y una @mención', async () => {
    await db.query(`insert into stories (author_id, media_url, caption) values ($1, 'https://cdn.example/story.jpg', 'hola @maria99, mira esto')`, [u1]);
  });
  await asUser(u2);
  const storyMentionNotif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'mention' and payload ? 'story_id'`, [u2])).rows;
  check('notify_mentions_in_story: u2 (@maria99) recibe el aviso real de mención en una historia', storyMentionNotif.length === 1);

  await asUser(u1);
  await expectOk('stories_write_own: u1 SÍ puede publicar una historia real sin ninguna @mención (caption normal)', async () => {
    await db.query(`insert into stories (author_id, media_url, caption) values ($1, 'https://cdn.example/story2.jpg', 'sin mencionar a nadie')`, [u1]);
  });
  await asUser(u2);
  const storyMentionNotifStillOne = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'mention' and payload ? 'story_id'`, [u2])).rows;
  check('notify_mentions_in_story: una historia real sin @mención no genera un segundo aviso', storyMentionNotifStillOne.length === 1);

  // --- hashtag_follows (0144_hashtag_follows.sql): seguir un hashtag
  // real, comparado con Instagram/TikTok/X. ---
  await asUser(u1);
  await expectOk('hashtag_follows_own: u1 SÍ puede seguir su propio hashtag real', async () => {
    await db.query(`insert into hashtag_follows (user_id, hashtag) values ($1, 'atardecer')`, [u1]);
  });
  await expectFail('hashtag_follows: un hashtag real con "#" NO se puede guardar (constraint real)', async () => {
    await db.query(`insert into hashtag_follows (user_id, hashtag) values ($1, '#atardecer')`, [u1]);
  });
  await expectFail('hashtag_follows: un hashtag real en mayúsculas NO se puede guardar sin normalizar (constraint real)', async () => {
    await db.query(`insert into hashtag_follows (user_id, hashtag) values ($1, 'Atardecer')`, [u1]);
  });

  await asUser(u2);
  const u2SeesU1Hashtags = (await db.query(`select hashtag from hashtag_follows where user_id = $1`, [u1])).rows;
  check('hashtag_follows_own: u2 NO ve los hashtags reales que sigue u1', u2SeesU1Hashtags.length === 0);
  await expectFail('hashtag_follows_own: u2 NO puede seguir un hashtag real en nombre de u1', async () => {
    await db.query(`insert into hashtag_follows (user_id, hashtag) values ($1, 'playa')`, [u1]);
  });

  await asUser(u1);
  const u1Hashtags = (await db.query(`select hashtag from hashtag_follows where user_id = $1`, [u1])).rows;
  check('hashtag_follows_own: u1 SÍ ve su propio hashtag real seguido', u1Hashtags.length === 1 && u1Hashtags[0].hashtag === 'atardecer');
  await expectOk('hashtag_follows_own: u1 SÍ puede dejar de seguir su propio hashtag real', async () => {
    await db.query(`delete from hashtag_follows where user_id = $1 and hashtag = 'atardecer'`, [u1]);
  });
  const u1HashtagsAfterUnfollow = (await db.query(`select hashtag from hashtag_follows where user_id = $1`, [u1])).rows;
  check('hashtag_follows_own: el hashtag real ya no aparece tras dejar de seguirlo', u1HashtagsAfterUnfollow.length === 0);

  // --- post_views + get_post_insights() (0145_post_insights.sql): panel
  // de estadísticas real del post ("Insights"), comparado con Instagram/
  // TikTok/Facebook. Mismo patrón de profundidad anidada ya usado en
  // reel_views (0131) para rodear protect_post_counts. ---
  await asUser(u1);
  const insightsPostId = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'post con estadísticas reales') returning id`,
    [u1]
  )).rows[0].id;

  await asUser(u2);
  await expectOk('post_views_insert_own: u2 SÍ puede registrar su propia vista real', async () => {
    await db.query(`insert into post_views (post_id, viewer_id) values ($1, $2)`, [insightsPostId, u2]);
  });
  await expectFail('post_views_insert_own: u2 NO puede registrar una vista real en nombre de otro', async () => {
    await db.query(`insert into post_views (post_id, viewer_id) values ($1, $2)`, [insightsPostId, u3]);
  });
  await asUser(u3);
  await db.query(`insert into post_views (post_id, viewer_id) values ($1, $2)`, [insightsPostId, u3]);

  await asUser(u1);
  const viewCountRow = (await db.query(`select view_count from posts where id = $1`, [insightsPostId])).rows[0];
  check('sync_post_view_count: el alcance real sube con cada vista real distinta', viewCountRow.view_count === 2);

  await db.query(`update posts set view_count = 999999 where id = $1`, [insightsPostId]);
  const stillProtectedViewCount = (await db.query(`select view_count from posts where id = $1`, [insightsPostId])).rows[0];
  check('protect_post_counts: el propio autor real NO puede falsear view_count a mano', stillProtectedViewCount.view_count === 2);

  await asUser(u2);
  await db.query(`insert into saved_posts (post_id, user_id) values ($1, $2)`, [insightsPostId, u2]);
  await asUser(u1);
  const insights = (await db.query(`select * from get_post_insights($1)`, [insightsPostId])).rows[0];
  check('get_post_insights: el autor real ve el alcance/me gusta/comentarios/guardados reales', insights.view_count === 2 && Number(insights.saved_count) === 1);

  await asUser(u2);
  await expectFail('get_post_insights: u2 (NO autor real) NO puede ver las estadísticas ajenas', async () => {
    await db.query(`select * from get_post_insights($1)`, [insightsPostId]);
  });

  // --- stories.link_url + story_link_clicks (0146_story_link.sql):
  // sticker de enlace real ("swipe up"), comparado con Instagram
  // Stories/TikTok/Snapchat. Mismo patrón real que story_views (0053). ---
  await asUser(u1);
  await expectOk('stories_write_own: u1 SÍ puede publicar una historia real con un link_url real (https)', async () => {
    await db.query(`insert into stories (author_id, media_url, link_url) values ($1, 'https://cdn.example/story.jpg', 'https://social.example/promo')`, [u1]);
  });
  const linkStoryId = (await db.query(`select id from stories where author_id = $1 and link_url is not null`, [u1])).rows[0].id;
  await expectFail('stories: un link_url real sin http(s):// NO se puede guardar (constraint real)', async () => {
    await db.query(`insert into stories (author_id, media_url, link_url) values ($1, 'https://cdn.example/story3.jpg', 'no-es-una-url')`, [u1]);
  });

  await asUser(u2);
  await expectOk('story_link_clicks_insert_own: u2 SÍ puede registrar su propio clic real en el enlace', async () => {
    await db.query(`insert into story_link_clicks (story_id, user_id) values ($1, $2)`, [linkStoryId, u2]);
  });
  await expectFail('story_link_clicks_insert_own: u2 NO puede registrar un clic real en nombre de otro', async () => {
    await db.query(`insert into story_link_clicks (story_id, user_id) values ($1, $2)`, [linkStoryId, u3]);
  });
  const u2SeesClicks = (await db.query(`select id from story_link_clicks where story_id = $1`, [linkStoryId])).rows;
  check('story_link_clicks_select_own_story: u2 (NO autor real de la historia) NO ve los clics', u2SeesClicks.length === 0);

  await asUser(u1);
  const u1SeesClicks = (await db.query(`select id from story_link_clicks where story_id = $1`, [linkStoryId])).rows;
  check('story_link_clicks_select_own_story: u1 (autor real de la historia) SÍ ve el clic real registrado', u1SeesClicks.length === 1);

  // --- stories.countdown_target_at + story_countdown_reminders +
  // notify_due_story_countdowns() (0147_story_countdown.sql): sticker de
  // cuenta atrás real, comparado con Instagram (Countdown)/Snapchat. SIN
  // pg_cron -- mismo patrón real que publish_due_scheduled_posts (0141). ---
  await asUser(u1);
  const dueCountdownStoryId = (await db.query(
    `insert into stories (author_id, media_url, countdown_label, countdown_target_at) values ($1, 'https://cdn.example/story.jpg', 'ya vencida', now() - interval '1 minute') returning id`,
    [u1]
  )).rows[0].id;
  const futureCountdownStoryId = (await db.query(
    `insert into stories (author_id, media_url, countdown_label, countdown_target_at) values ($1, 'https://cdn.example/story2.jpg', 'todavía no', now() + interval '1 day') returning id`,
    [u1]
  )).rows[0].id;

  await asUser(u2);
  await expectOk('story_countdown_reminders_own: u2 SÍ puede apuntarse a un recordatorio real', async () => {
    await db.query(`insert into story_countdown_reminders (story_id, user_id) values ($1, $2)`, [dueCountdownStoryId, u2]);
    await db.query(`insert into story_countdown_reminders (story_id, user_id) values ($1, $2)`, [futureCountdownStoryId, u2]);
  });

  await db.query(`select notify_due_story_countdowns()`);
  const dueNotif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'countdown_due'`, [u2])).rows;
  check('notify_due_story_countdowns: u2 recibe el aviso real del recordatorio ya vencido', dueNotif.length === 1 && dueNotif[0].payload.story_id === dueCountdownStoryId);

  const stillReminded = (await db.query(`select story_id from story_countdown_reminders where user_id = $1 and story_id = $2`, [u2, futureCountdownStoryId])).rows;
  check('notify_due_story_countdowns: el recordatorio real FUTURO no se toca todavía', stillReminded.length === 1);

  const goneReminder = (await db.query(`select story_id from story_countdown_reminders where user_id = $1 and story_id = $2`, [u2, dueCountdownStoryId])).rows;
  check('notify_due_story_countdowns: el recordatorio real vencido ya no está en story_countdown_reminders', goneReminder.length === 0);

  await asUser(u3);
  const u3SeesU2Reminder = (await db.query(`select story_id from story_countdown_reminders where user_id = $1`, [u2])).rows;
  check('story_countdown_reminders_own: u3 NO ve los recordatorios reales de u2', u3SeesU2Reminder.length === 0);
  await db.query(`select notify_due_story_countdowns()`);
  const u3Notif = (await db.query(`select payload from notifications where recipient_id = $1 and kind = 'countdown_due'`, [u3])).rows;
  check('notify_due_story_countdowns: u3 NO recibe ningún aviso ajeno (no tiene recordatorios propios)', u3Notif.length === 0);

  // --- stories.slider_emoji/slider_average + story_slider_responses
  // (0148_story_slider.sql): sticker de emoji deslizante real, comparado
  // con Instagram (desde 2018)/Facebook Stories. Mismo patrón real que
  // story_polls (0100): reparto público, respuesta individual privada. ---
  await asUser(u1);
  const sliderStoryId = (await db.query(
    `insert into stories (author_id, media_url, slider_emoji, slider_label) values ($1, 'https://cdn.example/slider.jpg', '🔥', '¿Qué tal esta ronda?') returning id`,
    [u1]
  )).rows[0].id;

  await asUser(storyResponder);
  await expectFail('story_slider_responses_insert_own: un value real fuera de rango (150) NO se puede guardar (constraint real)', async () => {
    await db.query(`insert into story_slider_responses (story_id, user_id, value) values ($1, $2, 150)`, [sliderStoryId, storyResponder]);
  });
  await expectOk('story_slider_responses_insert_own: storyResponder SÍ puede responder de verdad al slider', async () => {
    await db.query(`insert into story_slider_responses (story_id, user_id, value) values ($1, $2, 80)`, [sliderStoryId, storyResponder]);
  });

  await asUser(storyOtherViewer);
  await expectOk('story_slider_responses_insert_own: storyOtherViewer SÍ puede responder de verdad al slider', async () => {
    await db.query(`insert into story_slider_responses (story_id, user_id, value) values ($1, $2, 40)`, [sliderStoryId, storyOtherViewer]);
  });
  const avgAsOtherViewer = (await db.query(`select slider_average, slider_count from stories where id = $1`, [sliderStoryId])).rows[0];
  check('sync_story_slider_average: cualquier espectador real (storyOtherViewer) SÍ ve el promedio agregado real (60), sin ver la respuesta de storyResponder', Number(avgAsOtherViewer.slider_average) === 60 && avgAsOtherViewer.slider_count === 2);
  const otherViewerSeesResponderResponse = (await db.query(`select id from story_slider_responses where story_id = $1 and user_id = $2`, [sliderStoryId, storyResponder])).rows;
  check('story_slider_responses_select: storyOtherViewer NO ve la respuesta individual real de storyResponder', otherViewerSeesResponderResponse.length === 0);

  await asUser(storyResponder);
  await expectOk('story_slider_responses_update_own: storyResponder SÍ puede cambiar de valor real (20 en vez de 80)', async () => {
    await db.query(`update story_slider_responses set value = 20 where story_id = $1 and user_id = $2`, [sliderStoryId, storyResponder]);
  });
  const avgAfterChange = (await db.query(`select slider_average from stories where id = $1`, [sliderStoryId])).rows[0];
  check('sync_story_slider_average: tras cambiar de valor real, el promedio agregado ya refleja (20+40)/2=30', Number(avgAfterChange.slider_average) === 30);

  await asUser(u1);
  const responsesAsAuthor = (await db.query(`select user_id, value from story_slider_responses where story_id = $1 order by user_id`, [sliderStoryId])).rows;
  check('story_slider_responses_select: el autor real de la historia (u1) SÍ ve TODAS las respuestas individuales, con quién las mandó', responsesAsAuthor.length === 2);

  // --- app_sessions + profiles.daily_time_limit_minutes/daily_reminder_enabled
  // (0149_screen_time.sql): tiempo en pantalla real ("Bienestar
  // digital"), comparado con Instagram/TikTok/Facebook/Snapchat. ---
  await asUser(u1);
  const sessionId = (await db.query(
    `insert into app_sessions (user_id, started_at) values ($1, now() - interval '5 minutes') returning id`, [u1]
  )).rows[0].id;
  await expectOk('app_sessions_own: u1 SÍ puede cerrar su propia sesión real con la duración calculada', async () => {
    await db.query(`update app_sessions set ended_at = now(), duration_seconds = 300 where id = $1`, [sessionId]);
  });
  await expectOk('profiles_update_own: u1 SÍ puede fijar su propio límite diario real', async () => {
    await db.query(`update profiles set daily_time_limit_minutes = 60, daily_reminder_enabled = true where id = $1`, [u1]);
  });
  await expectFail('app_sessions.daily_time_limit_minutes: un límite real de 0 minutos NO se puede guardar (constraint real)', async () => {
    await db.query(`update profiles set daily_time_limit_minutes = 0 where id = $1`, [u1]);
  });

  await asUser(u2);
  await expectFail('app_sessions_own: u2 NO puede registrar una sesión real en nombre de u1', async () => {
    await db.query(`insert into app_sessions (user_id, started_at) values ($1, now())`, [u1]);
  });
  const u2SeesU1Sessions = (await db.query(`select id from app_sessions where user_id = $1`, [u1])).rows;
  check('app_sessions_own: u2 NO ve las sesiones reales de u1', u2SeesU1Sessions.length === 0);

  await asUser(u1);
  const u1OwnSessions = (await db.query(`select duration_seconds from app_sessions where user_id = $1`, [u1])).rows;
  check('app_sessions_own: u1 SÍ ve su propia sesión real con la duración guardada', u1OwnSessions.length === 1 && u1OwnSessions[0].duration_seconds === 300);

  // --- reels.sound_source_reel_id/sound_use_count (0150_reel_sounds.sql):
  // sonido de un reel reutilizable ("usar este sonido") + "Reels con
  // este sonido", comparado con TikTok/Instagram Reels. Mismo patrón
  // real de profundidad anidada ya usado en reel_view_count (0131). ---
  await asUser(u1);
  const rootReelId = (await db.query(
    `insert into reels (author_id, video_url) values ($1, 'https://cdn.example/root.mp4') returning id`, [u1]
  )).rows[0].id;

  await asUser(u2);
  const middleReelId = (await db.query(
    `insert into reels (author_id, video_url, sound_source_reel_id) values ($1, 'https://cdn.example/middle.mp4', $2) returning id`, [u2, rootReelId]
  )).rows[0].id;
  const middleRow = (await db.query(`select sound_source_reel_id, sound_use_count from reels where id = $1`, [middleReelId])).rows[0];
  check('resolve_reel_sound_root: sound_source_reel_id real del segundo reel apunta directo a la raíz (rootReelId)', middleRow.sound_source_reel_id === rootReelId);

  await asUser(u3);
  const leafReelId = (await db.query(
    `insert into reels (author_id, video_url, sound_source_reel_id) values ($1, 'https://cdn.example/leaf.mp4', $2) returning id`, [u3, middleReelId]
  )).rows[0].id;
  const leafRow = (await db.query(`select sound_source_reel_id from reels where id = $1`, [leafReelId])).rows[0];
  check('resolve_reel_sound_root: sound_source_reel_id real del TERCER reel (encadenado sobre el segundo) también apunta directo a la raíz, no al eslabón intermedio', leafRow.sound_source_reel_id === rootReelId);

  const rootAfterTwoUses = (await db.query(`select sound_use_count from reels where id = $1`, [rootReelId])).rows[0];
  check('sync_reel_sound_use_count: el sonido raíz real acumula 2 usos reales (middleReelId + leafReelId), aunque el segundo se registrara "sobre" el intermedio', rootAfterTwoUses.sound_use_count === 2);

  await asUser(u1);
  await db.query(`update reels set sound_use_count = 999999 where id = $1`, [rootReelId]);
  const stillProtectedSoundCount = (await db.query(`select sound_use_count from reels where id = $1`, [rootReelId])).rows[0];
  check('protect_reel_counts: el propio autor real NO puede falsear sound_use_count a mano', stillProtectedSoundCount.sound_use_count === 2);

  const reelsWithThisSound = (await db.query(`select id from reels where sound_source_reel_id = $1 order by created_at`, [rootReelId])).rows;
  check('"Reels con este sonido": una sola consulta plana por sound_source_reel_id real encuentra los 2 reels reales que lo usan', reelsWithThisSound.length === 2);

  // --- posts.alt_text/post_media.alt_text (0151_post_alt_text.sql):
  // texto alternativo real (accesibilidad), comparado con Instagram/
  // Facebook/Twitter-X. Sin RLS nueva -- reutiliza posts_write_own/
  // post_media_insert_own ya existentes. ---
  await asUser(u1);
  const altTextPostId = (await db.query(
    `insert into posts (author_id, caption, media_url, alt_text) values ($1, 'foto real con descripción', 'https://cdn.example/foto.jpg', 'Atardecer real sobre el mar') returning id`,
    [u1]
  )).rows[0].id;
  const altTextRow = (await db.query(`select alt_text from posts where id = $1`, [altTextPostId])).rows[0];
  check('posts.alt_text: el texto alternativo real se guarda tal cual', altTextRow.alt_text === 'Atardecer real sobre el mar');

  await expectFail('posts.alt_text: un texto alternativo real de más de 1000 caracteres NO se puede guardar (constraint real)', async () => {
    await db.query(`update posts set alt_text = repeat('x', 1001) where id = $1`, [altTextPostId]);
  });

  await expectOk('post_media_insert_own: u1 SÍ puede añadir una foto real adicional con su propio texto alternativo', async () => {
    await db.query(`insert into post_media (post_id, media_url, alt_text) values ($1, 'https://cdn.example/foto2.jpg', 'Segunda foto real: barco de vela')`, [altTextPostId]);
  });
  const mediaAltText = (await db.query(`select alt_text from post_media where post_id = $1`, [altTextPostId])).rows[0];
  check('post_media.alt_text: la foto adicional real tiene su propio texto alternativo distinto', mediaAltText.alt_text === 'Segunda foto real: barco de vela');

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
