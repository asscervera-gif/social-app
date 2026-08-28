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
    create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    create or replace function auth.role() returns text language sql stable as $$ select 'authenticated'::text $$;
    create or replace function uuid_generate_v4() returns uuid language sql as $$ select gen_random_uuid() $$;
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

// Mismo hallazgo real documentado en test_rls.mjs: `create extension
// pg_net` (0041_notify_push_trigger.sql) lanzaba una excepción sin
// capturar que tumbaba applyMigrations() entero -- stubbeada aquí igual
// que uuid-ossp.
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

let allPassed = true;
function check(label, condition) {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${label}`);
  if (!condition) allPassed = false;
  return condition;
}

async function main() {
  await setupStubs();
  await applyMigrations();
  console.log('--- migraciones aplicadas, empiezan las pruebas funcionales de triggers ---\n');

  // Setup: dos usuarios reales para las pruebas.
  const u1 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u2 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(`
    insert into profiles (id, display_name, username) values ($1, 'Uno', 'uno_test'), ($2, 'Dos', 'dos_test')
    on conflict (id) do update set display_name = excluded.display_name, username = excluded.username
  `, [u1, u2]);

  // --- Prueba 1: is_verified no se puede autoconceder por UPDATE directo ---
  await db.query(`update profiles set is_verified = true where id = $1`, [u1]);
  const p1 = (await db.query(`select is_verified from profiles where id = $1`, [u1])).rows[0];
  check('protect_is_verified: UPDATE directo NO concede is_verified', p1.is_verified === false);

  // --- Prueba 2: post like_count/comment_count no se pueden inflar por UPDATE directo ---
  const post = (await db.query(`insert into posts (author_id, caption) values ($1, 'hola') returning id`, [u1])).rows[0];
  await db.query(`update posts set like_count = 999 where id = $1`, [post.id]);
  const postAfter = (await db.query(`select like_count from posts where id = $1`, [post.id])).rows[0];
  check('protect_post_counts: UPDATE directo NO infla like_count', postAfter.like_count === 0);

  // El trigger real de likes SÍ debe poder subirlo (vía INSERT en likes, camino legítimo).
  await db.query(`insert into likes (post_id, user_id) values ($1, $2)`, [post.id, u2]);
  const postAfterLike = (await db.query(`select like_count from posts where id = $1`, [post.id])).rows[0];
  check('sync_post_like_count: INSERT en likes SÍ sube like_count a 1', postAfterLike.like_count === 1);

  // --- Prueba 3: compatibility_score no se puede escribir directo, pero SÍ vía voto real ---
  const chat = (await db.query(`insert into chats (user_a_id, user_b_id) values ($1, $2) returning id, compatibility_score`, [u1, u2])).rows[0];
  check('chats: compatibility_score arranca en 50 por defecto', chat.compatibility_score === 50);
  await db.query(`update chats set compatibility_score = 100 where id = $1`, [chat.id]);
  const chatAfterDirect = (await db.query(`select compatibility_score from chats where id = $1`, [chat.id])).rows[0];
  check('protect_compatibility_score: UPDATE directo NO cambia el score', chatAfterDirect.compatibility_score === 50);

  await db.query(`insert into compatibility_votes (chat_id, voter_id, delta) values ($1, $2, 10)`, [chat.id, u1]);
  const chatAfterVote = (await db.query(`select compatibility_score from chats where id = $1`, [chat.id])).rows[0];
  check('apply_compatibility_vote: INSERT en compatibility_votes SÍ sube el score a 60', chatAfterVote.compatibility_score === 60);

  // --- Prueba 4: event_attendees social_count real, incrementado cuando un social se acepta dentro de un evento activo ---
  const event = (await db.query(`insert into events (name, starts_at, ends_at, venue_lat, venue_lng) values ('Fiesta', now() - interval '1 hour', now() + interval '1 hour', 0, 0) returning id`)).rows[0];
  await db.query(`insert into event_attendees (event_id, profile_id) values ($1, $2), ($1, $3)`, [event.id, u1, u2]);
  const social = (await db.query(`insert into socials (requester_id, addressee_id, status) values ($1, $2, 'pending') returning id`, [u1, u2])).rows[0];
  await db.query(`update socials set status = 'accepted' where id = $1`, [social.id]);
  const attendeesAfter = (await db.query(`select profile_id, social_count from event_attendees where event_id = $1 order by profile_id`, [event.id])).rows;
  check('increment_event_social_count: ambos asistentes suben a 1 tras aceptar el social dentro del evento', attendeesAfter.every(r => r.social_count === 1));

  // --- Prueba 5: @menciones reales en captions/comentarios (0074_mentions.sql) ---
  const mentionPost = (await db.query(
    `insert into posts (author_id, caption) values ($1, 'hola @dos_test, mira esto') returning id`,
    [u1]
  )).rows[0];
  const mentionPostNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'post_id' = $2`,
    [u2, mentionPost.id]
  )).rows;
  check('notify_mentions_in_post: @dos_test en un caption real SÍ genera un aviso real a u2', mentionPostNotif.length === 1);

  await db.query(`insert into comments (post_id, author_id, body) values ($1, $2, 'gracias @uno_test')`, [mentionPost.id, u2]);
  const mentionCommentNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'post_id' = $2`,
    [u1, mentionPost.id]
  )).rows;
  check('notify_mentions_in_comment: @uno_test en un comentario real SÍ genera un aviso real a u1', mentionCommentNotif.length === 1);

  await db.query(`insert into posts (author_id, caption) values ($1, 'hablando de mí mismo, @uno_test') returning id`, [u1]);
  const selfMentionCount = (await db.query(`select count(*)::int as n from notifications where kind = 'mention' and recipient_id = $1 and actor_id = $1`, [u1])).rows[0].n;
  check('notify_mentions_in_post: automencionarse (@uno_test siendo u1) NO genera aviso', selfMentionCount === 0);

  const mentionReel = (await db.query(
    `insert into reels (author_id, video_url, caption) values ($1, 'v.mp4', 'reel con @dos_test') returning id`,
    [u1]
  )).rows[0];
  const mentionReelNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'reel_id' = $2`,
    [u2, mentionReel.id]
  )).rows;
  check('notify_mentions_in_reel: @dos_test en un caption de reel real SÍ genera un aviso real a u2', mentionReelNotif.length === 1);

  await db.query(`insert into reel_comments (reel_id, author_id, body) values ($1, $2, 'jaja @uno_test')`, [mentionReel.id, u2]);
  const mentionReelCommentNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'reel_id' = $2 and payload ? 'comment_id'`,
    [u1, mentionReel.id]
  )).rows;
  check('notify_mentions_in_reel_comment: @uno_test en un comentario de reel real SÍ genera un aviso real a u1', mentionReelCommentNotif.length === 1);

  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [u2, u1]);
  const blockedMentionPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'oye @dos_test') returning id`, [u1])).rows[0];
  const blockedMentionNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'post_id' = $2`,
    [u2, blockedMentionPost.id]
  )).rows;
  check('notify_mentions_in_post: mencionar a alguien que te bloqueó NO genera aviso', blockedMentionNotif.length === 0);

  // --- Prueba 6: @menciones reales dentro de un chat de GRUPO
  // (0090_group_message_mentions.sql), comparado con WhatsApp/Messenger/
  // Telegram -- a diferencia de un mensaje normal, salta el silencio real
  // del grupo, y solo notifica si el mencionado es de verdad miembro.
  // Usuarios NUEVOS a propósito (no u1/u2): más arriba en este mismo
  // archivo u2 ya bloqueó a u1 (prueba de "mencionar a alguien que te
  // bloqueó"), y private.is_blocked() comprueba las dos direcciones --
  // reutilizar u1/u2 aquí habría filtrado la mención por ese bloqueo real
  // ya existente, no por ningún fallo del trigger nuevo (confirmado con
  // una reproducción aislada: la misma inserción, sin ese bloqueo previo,
  // sí generaba el aviso correctamente). ---
  const u4 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u5 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u6 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name, username) values ($1, 'Cuatro', 'cuatro_test'), ($2, 'Cinco', 'cinco_test'), ($3, 'Seis', 'seis_test')
     on conflict (id) do update set display_name = excluded.display_name, username = excluded.username`,
    [u4, u5, u6]
  );
  const mentionGroup = (await db.query(`insert into group_chats (name, created_by) values ('Grupo mención', $1) returning id`, [u4])).rows[0];
  await db.query(`insert into group_chat_members (group_chat_id, user_id) values ($1, $2)`, [mentionGroup.id, u5]);
  await db.query(`update group_chat_members set muted = true where group_chat_id = $1 and user_id = $2`, [mentionGroup.id, u5]);

  const mentionGroupMsg = (await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'oye @cinco_test, mira esto') returning id`,
    [mentionGroup.id, u4]
  )).rows[0];
  const mentionGroupNotif = (await db.query(
    `select * from notifications where kind = 'mention' and recipient_id = $1 and payload->>'group_message_id' = $2`,
    [u5, mentionGroupMsg.id]
  )).rows;
  check('notify_mentions_in_group_message: @cinco_test real (silenciado) SÍ recibe el aviso de mención, salta el silencio del grupo', mentionGroupNotif.length === 1);
  const groupMessageNotifDespiteMute = (await db.query(
    `select id from notifications where kind = 'group_message' and recipient_id = $1 and payload->>'group_chat_id' = $2`,
    [u5, mentionGroup.id]
  )).rows;
  check('notify_new_group_message: el aviso NORMAL sigue sin llegar (grupo silenciado) -- la mención es la única vía real que lo salta', groupMessageNotifDespiteMute.length === 0);

  await db.query(
    `insert into group_messages (group_chat_id, sender_id, body) values ($1, $2, 'y tú @seis_test, que ni eres del grupo')`,
    [mentionGroup.id, u4]
  );
  const nonMemberMentionNotif = (await db.query(`select id from notifications where kind = 'mention' and recipient_id = $1`, [u6])).rows;
  check('notify_mentions_in_group_message: @seis_test real, que NO es miembro del grupo, NO recibe aviso (evita la fuga real de que ese grupo existe)', nonMemberMentionNotif.length === 0);

  // --- post_notification_subscriptions / notify_post_subscribers
  // (0098_post_notifications.sql): activar avisos de publicaciones de
  // una cuenta real ("🔔"), comparado con Instagram/Twitter/X. Usuarios
  // nuevos a propósito (mismo motivo ya documentado en la ronda de
  // menciones en grupo: evitar estado ajeno de bloqueos/follows de más
  // arriba en este mismo archivo). ---
  const u7 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u8 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u9 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Siete'), ($2, 'Ocho'), ($3, 'Nueve')
     on conflict (id) do update set display_name = excluded.display_name`,
    [u7, u8, u9]
  );
  await db.query(`insert into post_notification_subscriptions (subscriber_id, creator_id) values ($1, $2)`, [u8, u7]);

  const subscribedPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'publicación real nueva') returning id`, [u7])).rows[0];
  const newPostNotif = (await db.query(
    `select id from notifications where kind = 'new_post' and recipient_id = $1 and payload->>'post_id' = $2`,
    [u8, subscribedPost.id]
  )).rows;
  check('notify_post_subscribers: u8 real, suscrito a u7, SÍ recibe el aviso real de la publicación nueva', newPostNotif.length === 1);

  const unsubscribedNotif = (await db.query(`select id from notifications where kind = 'new_post' and recipient_id = $1`, [u9])).rows;
  check('notify_post_subscribers: u9 real, que NO está suscrito a u7, NO recibe ningún aviso', unsubscribedNotif.length === 0);

  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [u8, u7]);
  const secondPost = (await db.query(`insert into posts (author_id, caption) values ($1, 'segunda publicación real') returning id`, [u7])).rows[0];
  const notifAfterBlock = (await db.query(
    `select id from notifications where kind = 'new_post' and recipient_id = $1 and payload->>'post_id' = $2`,
    [u8, secondPost.id]
  )).rows;
  check('notify_post_subscribers: tras bloquear real al autor, u8 NO recibe aviso de su nueva publicación aunque siga suscrito', notifAfterBlock.length === 0);

  // --- notify_story_question_response (0099_story_questions.sql): avisa
  // al autor real de una historia en cuanto llega una respuesta real a
  // su pregunta, comparado con Instagram. ---
  const u10 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u11 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Diez'), ($2, 'Once')
     on conflict (id) do update set display_name = excluded.display_name`,
    [u10, u11]
  );
  const questionStory = (await db.query(`insert into stories (author_id, media_url) values ($1, 'historia.jpg') returning id`, [u10])).rows[0];
  const realQuestion = (await db.query(`insert into story_questions (story_id, prompt) values ($1, '¿qué opinas?') returning id`, [questionStory.id])).rows[0];
  const realResponse = (await db.query(
    `insert into story_question_responses (question_id, responder_id, body) values ($1, $2, 'me parece genial') returning id`,
    [realQuestion.id, u11]
  )).rows[0];
  const storyQuestionNotif = (await db.query(
    `select id from notifications where kind = 'story_question_response' and recipient_id = $1 and payload->>'response_id' = $2`,
    [u10, realResponse.id]
  )).rows;
  check('notify_story_question_response: u10 real, autor de la historia, SÍ recibe el aviso real de la respuesta', storyQuestionNotif.length === 1);

  // --- notify_live_start (0138_live_start_notification.sql): aviso real
  // a tus seguidores al empezar un Directo, comparado con
  // Instagram/TikTok. Usuarios NUEVOS a propósito. ---
  const u12 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u13 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  const u14 = (await db.query(`insert into auth.users default values returning id`)).rows[0].id;
  await db.query(
    `insert into profiles (id, display_name) values ($1, 'Doce'), ($2, 'Trece'), ($3, 'Catorce')
     on conflict (id) do update set display_name = excluded.display_name`,
    [u12, u13, u14]
  );
  // u13 sigue a u12 (host real); u14 no lo sigue.
  await db.query(`insert into follows (follower_id, followee_id) values ($1, $2)`, [u13, u12]);
  const realStream = (await db.query(`insert into live_streams (host_id) values ($1) returning id`, [u12])).rows[0];
  const liveStartNotifFollower = (await db.query(
    `select id from notifications where kind = 'live_start' and recipient_id = $1 and payload->>'stream_id' = $2`,
    [u13, realStream.id]
  )).rows;
  check('notify_live_start: u13 real, que sigue a u12, SÍ recibe el aviso real al empezar el Directo', liveStartNotifFollower.length === 1);
  const liveStartNotifNonFollower = (await db.query(`select id from notifications where kind = 'live_start' and recipient_id = $1`, [u14])).rows;
  check('notify_live_start: u14 real, que NO sigue a u12, NO recibe ningún aviso', liveStartNotifNonFollower.length === 0);

  await db.query(`insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [u13, u12]);
  const secondStream = (await db.query(`insert into live_streams (host_id) values ($1) returning id`, [u12])).rows[0];
  const liveStartNotifAfterBlock = (await db.query(
    `select id from notifications where kind = 'live_start' and recipient_id = $1 and payload->>'stream_id' = $2`,
    [u13, secondStream.id]
  )).rows;
  check('notify_live_start: tras bloquear real al host, u13 NO recibe aviso de su nuevo Directo aunque le siga', liveStartNotifAfterBlock.length === 0);

  console.log('\n--- fin de las pruebas funcionales ---');
  if (!allPassed) process.exitCode = 1;
}

main().catch(e => { console.error('ERROR INESPERADO:', e.message); process.exit(1); });
