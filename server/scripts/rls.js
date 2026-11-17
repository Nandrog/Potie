// Supabase exposes every table in the `public` schema through its REST API using
// the public anon key. All access in this project goes through the Node API
// (Prisma connects as the postgres role, which bypasses RLS), so we switch RLS
// on with NO policies: the anon/authenticated roles then see nothing.
require('dotenv').config();
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient(); // no Supabase key needed for this script

const TABLES = ['users', 'waiters', 'pots', 'tokens', 'extensions', 'audit_log', 'settings', 'alerts'];

(async () => {
  for (const t of TABLES) {
    await prisma.$executeRawUnsafe(`ALTER TABLE public."${t}" ENABLE ROW LEVEL SECURITY`);
  }
  console.log('Row Level Security enabled on:', TABLES.join(', '));
  await prisma.$disconnect();
})().catch((e) => { console.error(e); process.exit(1); });
