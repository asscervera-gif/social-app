import pg from 'pg';
const client = new pg.Client({ connectionString: process.argv[2], ssl: { rejectUnauthorized: false } });
await client.connect();
const r = await client.query(`select prosrc from pg_proc where proname = 'role' and pronamespace = 'auth'::regnamespace`);
console.log(r.rows[0]?.prosrc || 'NOT FOUND');
await client.end();
