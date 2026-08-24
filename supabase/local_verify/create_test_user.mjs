import pg from 'pg';

const CONNECTION_STRING = process.argv[2];
const email = process.argv[3];
const password = process.argv[4];
const displayName = process.argv[5];

const client = new pg.Client({ connectionString: CONNECTION_STRING, ssl: { rejectUnauthorized: false } });

async function main() {
  await client.connect();
  // Crea el usuario directamente ya confirmado (email_confirmed_at = now()),
  // saltándose el envío real de email de confirmación — es EL MISMO efecto
  // que tendría confirmar el enlace del email, solo que sin esperar al
  // límite de envíos del plan gratuito de Supabase. auth.identities es
  // obligatoria para que el login por email/password funcione en GoTrue
  // moderno (sin ella, signInWithPassword no encuentra el proveedor).
  const res = await client.query(
    `insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      is_sso_user, is_anonymous
    ) values (
      '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
      $1, crypt($2, gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}', jsonb_build_object('display_name', $3::text),
      '', '', '', '',
      false, false
    ) returning id`,
    [email, password, displayName]
  );
  const userId = res.rows[0].id;

  await client.query(
    `insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at, last_sign_in_at)
     values (gen_random_uuid(), $1::uuid, $2::text, jsonb_build_object('sub', $2::text, 'email', $3::text), 'email', now(), now(), now())`,
    [userId, userId, email]
  );

  console.log(`Usuario creado y confirmado: ${email} (id=${userId})`);
  await client.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
