import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';

const MIGRATIONS_DIR = process.argv[2];
const db = new PGlite();

async function setupStubs() {
  // Stubs para lo que en un proyecto Supabase real proveen las
  // extensiones/esquemas internos, que PGlite (Postgres real en WASM,
  // pero sin el entorno completo de Supabase) no trae de fábrica.
  await db.exec(`
    do $$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon;
      end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated;
      end if;
      if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role;
      end if;
    end $$;
    create schema if not exists auth;
    create table if not exists auth.users (
      id uuid primary key default gen_random_uuid(),
      email text,
      raw_user_meta_data jsonb not null default '{}'
    );
    create or replace function auth.uid() returns uuid
      language sql stable as $$ select null::uuid $$;
    create or replace function auth.role() returns text
      language sql stable as $$ select 'authenticated'::text $$;
    create or replace function uuid_generate_v4() returns uuid
      language sql as $$ select gen_random_uuid() $$;
    create schema if not exists private;
    create schema if not exists storage;
    create table if not exists storage.buckets (
      id text primary key,
      name text not null,
      public boolean not null default false
    );
    create table if not exists storage.objects (
      id uuid primary key default gen_random_uuid(),
      bucket_id text,
      name text,
      owner uuid
    );
    -- Réplica mínima de la función real que provee el motor de Storage
    -- de Supabase (no en el propio Postgres) — divide el path por "/" y
    -- devuelve todo menos el último segmento, mismo comportamiento
    -- documentado del original.
    create or replace function storage.foldername(name text) returns text[]
      language sql immutable as $$
        select case when array_length(regexp_split_to_array(name, '/'), 1) > 1
          then (regexp_split_to_array(name, '/'))[1:array_length(regexp_split_to_array(name, '/'), 1) - 1]
          else array[]::text[]
        end
      $$;
  `);
}

function stripUnavailableExtension(sql) {
  // La única línea que de verdad no se puede satisfacer en este stub
  // (uuid_generate_v4 ya se define arriba a mano) — todo lo demás del
  // archivo se ejecuta tal cual, sin tocar nada más.
  return sql.replace(/create extension if not exists "uuid-ossp";?/gi, '-- (uuid-ossp) stub: uuid_generate_v4 ya definida arriba');
}

async function main() {
  await setupStubs();
  const files = fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
  let okCount = 0;
  const failures = [];
  for (const file of files) {
    const full = path.join(MIGRATIONS_DIR, file);
    const sql = stripUnavailableExtension(fs.readFileSync(full, 'utf8'));
    try {
      await db.exec(sql);
      okCount++;
      console.log(`OK   ${file}`);
    } catch (e) {
      failures.push({ file, message: e.message });
      console.log(`FAIL ${file}: ${e.message}`);
    }
  }
  console.log(`\n${okCount}/${files.length} migraciones aplicadas sin error.`);
  if (failures.length) {
    console.log('\nFallos:');
    for (const f of failures) console.log(`- ${f.file}: ${f.message}`);
    process.exitCode = 1;
  }
}

main();
