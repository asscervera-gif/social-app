import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';

const MIGRATIONS_DIR = process.argv[2];
const CONNECTION_STRING = process.argv[3];

const client = new pg.Client({ connectionString: CONNECTION_STRING, ssl: { rejectUnauthorized: false } });

async function main() {
  await client.connect();
  const files = fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
  for (const file of files) {
    const full = path.join(MIGRATIONS_DIR, file);
    const sql = fs.readFileSync(full, 'utf8');
    try {
      await client.query(sql);
      console.log(`OK   ${file}`);
    } catch (e) {
      console.log(`FAIL ${file}: ${e.message}`);
      await client.end();
      process.exit(1);
    }
  }
  console.log(`\n${files.length}/${files.length} migraciones aplicadas a tu proyecto Supabase real.`);
  await client.end();
}

main();
