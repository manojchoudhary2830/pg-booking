import { Client } from 'pg';
import * as fs from 'fs';
import * as path from 'path';
import * as dotenv from 'dotenv';

dotenv.config();

async function runMigration() {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl) {
    console.error('❌ Error: DATABASE_URL environment variable is required.');
    console.error('Usage: DATABASE_URL="postgresql://postgres:[password]@db.[ref].supabase.co:5432/postgres" npm run migrate:supabase');
    process.exit(1);
  }

  console.log('Connecting to PostgreSQL database...');
  const isRemote = dbUrl.includes('supabase.co') || dbUrl.includes('supabase.com') || process.env.DB_SSL === 'true';
  const client = new Client({
    connectionString: dbUrl,
    ssl: isRemote ? { rejectUnauthorized: false } : false,
  });

  try {
    await client.connect();
    console.log('✅ Connected to database successfully.');

    const schemaPath = path.resolve(__dirname, '../../../../../database/supabase_full_schema.sql');
    if (!fs.existsSync(schemaPath)) {
      throw new Error(`Schema file not found at: ${schemaPath}`);
    }

    console.log(`Reading schema from: ${schemaPath}...`);
    const sql = fs.readFileSync(schemaPath, 'utf8');

    console.log('Executing full schema migration on Supabase...');
    await client.query(sql);

    console.log('Verifying installed tables...');
    const res = await client.query(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      ORDER BY table_name;
    `);

    console.log(`✅ Migration completed! Tables created (${res.rows.length}):`);
    res.rows.forEach((r) => console.log(`  - ${r.table_name}`));
  } catch (error) {
    console.error('❌ Migration failed:', (error as Error).message);
    process.exit(1);
  } finally {
    await client.end();
  }
}

runMigration();
