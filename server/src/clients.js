require('dotenv').config();
const { PrismaClient } = require('@prisma/client');
const { createClient } = require('@supabase/supabase-js');

const prisma = new PrismaClient();

// Service-role client: verifies user JWTs and manages Auth users. Server only.
const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** Email+password sign in on a throwaway client so no session is kept server-side. */
async function signInWithPassword(email, password) {
  const probe = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await probe.auth.signInWithPassword({ email, password });
  return { session: error ? null : data.session, error };
}

const passwordIsValid = async (email, password) => !(await signInWithPassword(email, password)).error;

module.exports = { prisma, supabase, signInWithPassword, passwordIsValid };
