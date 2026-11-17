// Seeds Supabase Auth users + matching Prisma rows. Safe to re-run.
const { prisma, supabase } = require('../src/clients');

const USERS = [
  { name: 'Maria Manager', email: process.env.SEED_MANAGER_EMAIL || 'manager@potie.app',
    password: process.env.SEED_MANAGER_PASSWORD || 'Manager@123', role: 'manager' },
];

async function ensureAuthUser(u) {
  const created = await supabase.auth.admin.createUser({
    email: u.email, password: u.password, email_confirm: true, user_metadata: { name: u.name },
  });
  if (!created.error) return created.data.user;

  // Already exists – find it.
  for (let page = 1; page < 50; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const hit = data.users.find((x) => x.email === u.email);
    if (hit) return hit;
    if (data.users.length < 200) break;
  }
  throw created.error;
}

(async () => {
  for (const u of USERS) {
    const auth = await ensureAuthUser(u);
    await prisma.user.upsert({
      where: { email: u.email },
      update: { authId: auth.id, role: u.role, name: u.name },
      create: { authId: auth.id, name: u.name, email: u.email, role: u.role },
    });
    console.log(`user  ${u.role.padEnd(11)} ${u.email}`);
  }
  // Waiters have no login; the distributor registers them in the app (Waiters tab).
  // Pots are NOT seeded: the distributor registers them in the app (Pots tab),
  // which assigns each a random unique tracking number.
  await prisma.setting.upsert({ where: { id: 1 }, update: {}, create: { id: 1, smtp: {} } });
  console.log('settings row ensured');
  await prisma.$disconnect();
})().catch((e) => { console.error(e); process.exit(1); });
