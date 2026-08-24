import pg from 'pg';
const client = new pg.Client({ connectionString: process.argv[2], ssl: { rejectUnauthorized: false } });
await client.connect();
// Crea una función temporal SECURITY DEFINER (dueña = postgres, igual que
// admin_ban_user) para ver qué current_user/session_user ve DE VERDAD
// cuando la llama el rol authenticated.
await client.query(`
  create or replace function public.__probe_definer()
  returns table(cu text, su text, rl text)
  language plpgsql security definer set search_path = '' as $$
  begin
    return query select current_user::text, session_user::text, current_setting('role', true)::text;
  end; $$;
  grant execute on function public.__probe_definer() to authenticated;
`);
await client.query(`set role authenticated`);
const r = await client.query(`select * from __probe_definer()`);
console.log('Como rol authenticated llamando a la función SECURITY DEFINER:', r.rows[0]);
await client.query(`reset role`);
await client.query(`drop function public.__probe_definer()`);
await client.end();
