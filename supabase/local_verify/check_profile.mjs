import pg from 'pg';
const client = new pg.Client({ connectionString: process.argv[2], ssl: { rejectUnauthorized: false } });
await client.connect();
const r = await client.query(`select id, display_name from profiles where id = (select id from auth.users where email = $1)`, [process.argv[3]]);
console.log(r.rows);
await client.end();
