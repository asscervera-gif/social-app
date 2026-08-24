import pg from 'pg';
const client = new pg.Client({ connectionString: process.argv[2], ssl: { rejectUnauthorized: false } });
await client.connect();
const email = process.argv[3];
const u = await client.query(`select id from auth.users where email = $1`, [email]);
const userId = u.rows[0].id;
await client.query(
  `insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at, last_sign_in_at)
   values (gen_random_uuid(), $1::uuid, $2::text, jsonb_build_object('sub', $2::text, 'email', $3::text), 'email', now(), now(), now())
   on conflict do nothing`,
  [userId, userId, email]
);
console.log('identity ok for', userId);
await client.end();
