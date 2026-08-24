import pg from 'pg';
const client = new pg.Client({ connectionString: process.argv[2], ssl: { rejectUnauthorized: false } });
await client.connect();

// Dos usuarios reales de prueba: uno admin, uno normal.
const admin = (await client.query(`insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change_token_new, email_change, is_sso_user, is_anonymous) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'verify-admin@test.local', crypt('x', gen_salt('bf')), now(), now(), now(), '{}', '{}', '', '', '', '', false, false) returning id`)).rows[0].id;
const target = (await client.query(`insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change_token_new, email_change, is_sso_user, is_anonymous) values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'verify-target@test.local', crypt('x', gen_salt('bf')), now(), now(), now(), '{}', '{}', '', '', '', '', false, false) returning id`)).rows[0].id;

await client.query(`update profiles set is_admin = true where id = $1`, [admin]);

// Llama admin_ban_user EXACTAMENTE como lo haría PostgREST: SET ROLE
// authenticated + el JWT claim real que auth.uid()/auth.role() leen de
// verdad en este proyecto (request.jwt.claim.role / .claims).
await client.query(`set role authenticated`);
await client.query(`select set_config('request.jwt.claim.sub', $1, false)`, [admin]);
await client.query(`select set_config('request.jwt.claim.role', 'authenticated', false)`);
await client.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({sub: admin, role: 'authenticated'})]);

await client.query(`select admin_ban_user($1, true, null, 'verificación real')`, [target]);

await client.query(`reset role`);
const row = (await client.query(`select is_banned, ban_reason from profiles where id = $1`, [target])).rows[0];
console.log('Resultado real tras admin_ban_user:', row);
if (row.is_banned !== true) {
  console.log('FALLO: is_banned sigue en false — el arreglo NO funcionó de verdad.');
  process.exit(1);
} else {
  console.log('OK: el baneo real funciona contra Supabase de producción.');
}

// limpieza
await client.query(`delete from auth.users where id in ($1, $2)`, [admin, target]);
await client.end();
