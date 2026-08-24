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
    insert into profiles (id, display_name) values ($1, 'Uno'), ($2, 'Dos')
    on conflict (id) do update set display_name = excluded.display_name
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

  console.log('\n--- fin de las pruebas funcionales ---');
  if (!allPassed) process.exitCode = 1;
}

main().catch(e => { console.error('ERROR INESPERADO:', e.message); process.exit(1); });
