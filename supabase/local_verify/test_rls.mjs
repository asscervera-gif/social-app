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

  // --- comments.is_pinned/reel_comments.is_pinned (0084_pin_comments.sql):
  // fijar un comentario, comparado con Instagram/Twitter -- primer caso
  // real de esta sesión donde alguien DISTINTO del autor de la fila
  // (aquí, el autor de la publicación) puede tocarla vía RLS directa.
  // Reutiliza mutedWordsPost (autor real u1) y cleanComment (de u2, sin
  // palabra silenciada) del bloque de arriba. ---
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
