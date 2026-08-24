import pg from 'pg';
const region = process.argv[2];
const password = process.argv[3];
const connStr = `postgresql://postgres.yzxzsaprvtsavkuhqfao:${password}@aws-0-${region}.pooler.supabase.com:6543/postgres`;
const c = new pg.Client({ connectionString: connStr, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 8000 });
try {
  await c.connect();
  console.log(`SUCCESS ${region}`);
  await c.end();
  process.exit(0);
} catch (e) {
  console.log(`FAIL ${region}: ${e.message}`);
  process.exit(1);
}
