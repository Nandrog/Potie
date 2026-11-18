const crypto = require('crypto');
const express = require('express');
const cors = require('cors');
const { prisma, supabase, signInWithPassword, passwordIsValid } = require('./clients');
const { send, inviteMail, getSmtp } = require('./mailer');

const app = express();
app.use(cors());
app.use(express.json());

const httpError = (status, message) => Object.assign(new Error(message), { status });
const wrap = (fn) => (req, res, next) => fn(req, res).catch(next);

// ---------------------------------------------------------------- auth
async function authenticate(req, _res, next) {
  try {
    const h = req.headers.authorization || '';
    if (!h.startsWith('Bearer ')) throw httpError(401, 'Missing token');
    const { data, error } = await supabase.auth.getUser(h.slice(7));
    if (error || !data.user) throw httpError(401, 'Invalid or expired session');
    const u = await prisma.user.findUnique({ where: { authId: data.user.id } });
    if (!u) throw httpError(403, 'Your account is not enrolled.');
    if (!u.active) throw httpError(403, 'This account has been disabled.');
    req.user = u;
    next();
  } catch (e) {
    next(e);
  }
}
const allow = (...roles) => (req, _res, next) =>
  roles.includes(req.user.role) ? next() : next(httpError(403, 'Not allowed for your role.'));

const publicUser = (u) => ({ id: u.id, name: u.name, email: u.email, role: u.role, active: u.active });

// ---------------------------------------------------------------- helpers
const TOKEN_INCLUDE = {
  waiter: true,
  distributor: true,
  pot: true,
  extensions: { orderBy: { at: 'asc' } },
};

// Decimal -> number so JSON carries numbers, snake_case for the Flutter client.
function tokenJson(t) {
  return {
    id: t.id,
    code: t.code,
    waiter_id: t.waiterId,
    waiter_name: t.waiter.name,
    minutes: t.minutes,
    amount: Number(t.amount),
    method: t.method,
    status: t.status,
    issued_at: t.issuedAt,
    distributor_id: t.distributorId,
    distributor_name: t.distributor?.name ?? null,
    pot_label: t.pot?.label ?? null,
    cleared_at: t.clearedAt,
    returned_at: t.returnedAt,
    payment_confirmed: t.paymentConfirmed,
    pay_timing: t.payTiming,
    paid_at: t.paidAt,
    pay_due_at: t.payDueAt,
    extensions: t.extensions.map((e) => ({
      id: e.id, minutes: e.minutes, fee: Number(e.fee), method: e.method, at: e.at, confirmed: e.confirmed,
    })),
  };
}

const audit = (db, actorId, action, detail, tokenId = null) =>
  db.auditLog.create({ data: { actorId, action, detail, tokenId } });

const lockToken = async (tx, id) => {
  // Row lock so two distributors can't clear the same token.
  const rows = await tx.$queryRaw`SELECT id FROM tokens WHERE id = ${id}::uuid FOR UPDATE`;
  if (!rows.length) throw httpError(404, 'Token not found.');
  return tx.token.findUnique({ where: { id } });
};

const findToken = async (db, id) => {
  const t = await db.token.findUnique({ where: { id }, include: TOKEN_INCLUDE });
  if (!t) throw httpError(404, 'Token not found.');
  return tokenJson(t);
};

const fmt = (n) => Number(n).toLocaleString('en-US', { maximumFractionDigits: 0 });
const METHODS = { mobile_money: 'Mobile Money', cash: 'Cash', visa: 'Visa' };
const TIMINGS = { immediate: 'paid now', on_return: 'pay on return', later: 'pay later' };
const PAY_WINDOW_MS = 12 * 3_600_000; // unpaid tokens must be settled within 12 hours
const isUuid = (s) => /^[0-9a-f-]{36}$/i.test(String(s));
const uuidParam = (req, _res, next) =>
  Object.values(req.params).every(isUuid) ? next() : next(httpError(400, 'Bad id.'));

// Sends login details by email if SMTP is set up; failures are only logged.
function emailInBackground(to, mail) {
  getSmtp()
    .then((smtp) => (smtp.host ? send({ to, ...mail }) : null))
    .catch((e) => console.error('login email not sent:', e.message));
}

const randomCode = () => String(crypto.randomInt(100000, 1000000));

// ---------------------------------------------------------------- routes
app.get('/health', (_req, res) => res.json({ ok: true }));

// ---- sign-in with lockout
// The app signs in through here (not straight to Supabase) so failures can be counted.
// 3 wrong passwords -> locked 10 seconds. The lock is also applied as a 10 s ban in
// Supabase Auth, so it holds even for someone calling Supabase directly.
// A successful sign-in restarts the attempt count.
const MAX_ATTEMPTS = 3;
const LOCK_SECONDS = 10;

const lockedError = (until) => {
  const secs = Math.max(1, Math.ceil((until - Date.now()) / 1000));
  return Object.assign(
    httpError(423, `Too many failed attempts. Try again in ${secs} second${secs === 1 ? '' : 's'}.`),
    { extra: { retry_after_seconds: secs } });
};

async function notifyManagers(user, message) {
  try {
    const managers = await prisma.user.findMany({ where: { role: 'manager', active: true } });
    await Promise.all(managers.map((m) =>
      send({
        to: m.email,
        subject: `Arrows Bar alert: ${user.name} is locked out`,
        text: `${message}\n\nOpen the app > Alerts and email them a new password.`,
      }).catch(() => {}))); // email is best-effort; the in-app alert is the record
  } catch (e) {
    console.error('notifyManagers failed', e.message);
  }
}

async function lockAccount(u) {
  const until = new Date(Date.now() + LOCK_SECONDS * 1000);
  const message = `${u.name} (${u.role}) was locked out for ${LOCK_SECONDS} seconds after ${MAX_ATTEMPTS} failed sign-in attempts. If it was not them, renew their password.`;
  await prisma.$transaction(async (tx) => {
    await tx.user.update({ where: { id: u.id }, data: { lockedUntil: until, failedAttempts: 0 } });
    const open = await tx.alert.findFirst({ where: { userId: u.id, type: 'LOCKOUT', resolvedAt: null } });
    if (open) await tx.alert.update({ where: { id: open.id }, data: { message, createdAt: new Date() } });
    else await tx.alert.create({ data: { userId: u.id, message } });
    await audit(tx, u.id, 'ACCOUNT_LOCKED', `${u.name} locked for ${LOCK_SECONDS} s after ${MAX_ATTEMPTS} failed sign-ins`);
  });
  if (u.active) {
    const { error } = await supabase.auth.admin.updateUserById(u.authId, { ban_duration: `${LOCK_SECONDS}s` });
    if (error) console.error('lock ban failed', error.message);
  }
  notifyManagers(u, message); // not awaited: don't slow the response
  return until;
}

app.post('/auth/login', wrap(async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const password = String(req.body.password || '');
  if (!email || !password) throw httpError(400, 'Enter your email and password.');

  const u = await prisma.user.findUnique({ where: { email } });
  if (!u) throw httpError(401, 'Wrong email or password.');
  if (u.lockedUntil && u.lockedUntil > new Date()) throw lockedError(u.lockedUntil);
  if (!u.active) throw httpError(403, 'This account has been disabled.');

  const { session, error } = await signInWithPassword(email, password);
  if (session) {
    if (u.failedAttempts || u.lockedUntil) {
      await prisma.user.update({ where: { id: u.id }, data: { failedAttempts: 0, lockedUntil: null } });
    }
    return res.json({
      access_token: session.access_token,
      refresh_token: session.refresh_token,
    });
  }
  // Our lock just lapsed but Supabase's ban is still a few seconds from clearing.
  if (error?.code === 'user_banned') throw httpError(429, 'Please try again in a moment.');
  if (error?.status >= 500) throw httpError(502, 'Sign-in service is unavailable. Try again shortly.');

  // Wrong password. Old failures (>1h) don't count toward the limit.
  const stale = u.lastFailedAt && Date.now() - u.lastFailedAt.getTime() > 3_600_000;
  const updated = await prisma.user.update({
    where: { id: u.id },
    data: { failedAttempts: stale ? 1 : { increment: 1 }, lastFailedAt: new Date() },
  });
  if (updated.failedAttempts >= MAX_ATTEMPTS) throw lockedError(await lockAccount(updated));
  const left = MAX_ATTEMPTS - updated.failedAttempts;
  throw httpError(401, `Wrong email or password. ${left} attempt${left === 1 ? '' : 's'} left.`);
}));

app.get('/me', authenticate, (req, res) => res.json(publicUser(req.user)));

/** Change name and/or login email in both Supabase Auth and our users table. */
async function changeDetails(target, actor, body, auditAction) {
  const name = String(body.name ?? target.name).trim();
  const email = String(body.email ?? target.email).trim().toLowerCase();
  if (!name) throw httpError(400, 'Name is required.');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw httpError(400, 'Enter a valid email.');
  if (email !== target.email && (await prisma.user.findUnique({ where: { email } })))
    throw httpError(409, 'A user with that email already exists.');
  if (name === target.name && email === target.email) return target;

  if (email !== target.email) {
    // email_confirm: true applies the change immediately (the manager vouches for it).
    const { error } = await supabase.auth.admin.updateUserById(target.authId, {
      email, email_confirm: true, user_metadata: { name },
    });
    if (error) throw httpError(400, error.message);
  }
  const detail = actor.id === target.id
    ? 'Updated own name/email'
    : `Updated details for ${target.name}` + (email !== target.email ? ` (email → ${email})` : '');
  return prisma.$transaction(async (tx) => {
    const u = await tx.user.update({ where: { id: target.id }, data: { name, email } });
    await audit(tx, actor.id, auditAction, detail);
    return u;
  });
}

// Any signed-in user edits their own login details.
app.patch('/me', authenticate, wrap(async (req, res) => {
  res.json(publicUser(await changeDetails(req.user, req.user, req.body, 'PROFILE_UPDATED')));
}));

app.post('/me/password', authenticate, wrap(async (req, res) => {
  const { current_password: cur, new_password: next } = req.body;
  if (typeof next !== 'string' || next.length < 8)
    throw httpError(400, 'New password must be at least 8 characters.');
  if (!(await passwordIsValid(req.user.email, String(cur ?? ''))))
    throw httpError(400, 'Current password is incorrect.');
  const { error } = await supabase.auth.admin.updateUserById(req.user.authId, { password: next });
  if (error) throw httpError(400, error.message);
  await audit(prisma, req.user.id, 'PASSWORD_CHANGED', 'Changed own password');
  res.json({ ok: true });
}));

// ---- waiters: registered by the distributor, no login
const waiterJson = (w) => ({ id: w.id, name: w.name, active: w.active });

app.get('/waiters', authenticate, allow('distributor', 'manager'), wrap(async (req, res) => {
  const rows = await prisma.waiter.findMany({
    where: req.query.all === '1' ? {} : { active: true },
    orderBy: { name: 'asc' },
  });
  res.json(rows.map(waiterJson));
}));

app.post('/waiters', authenticate, allow('distributor'), wrap(async (req, res) => {
  const name = String(req.body.name || '').trim();
  if (!name) throw httpError(400, "Enter the waiter's name.");
  const w = await prisma.$transaction(async (tx) => {
    const created = await tx.waiter.create({ data: { name } });
    await audit(tx, req.user.id, 'WAITER_REGISTERED', `${name} registered as a waiter`);
    return created;
  });
  res.status(201).json(waiterJson(w));
}));

app.patch('/waiters/:id', authenticate, allow('distributor'), uuidParam, wrap(async (req, res) => {
  const data = {};
  if (typeof req.body.name === 'string') {
    data.name = req.body.name.trim();
    if (!data.name) throw httpError(400, 'Name is required.');
  }
  if (typeof req.body.active === 'boolean') data.active = req.body.active;
  if (!Object.keys(data).length) throw httpError(400, 'Nothing to change.');
  const w = await prisma.$transaction(async (tx) => {
    const cur = await tx.waiter.findUnique({ where: { id: req.params.id } });
    if (!cur) throw httpError(404, 'Waiter not found.');
    if (data.active === false && (await tx.token.findFirst({ where: { waiterId: cur.id, status: 'out' } })))
      throw httpError(409, `${cur.name} still has a pot out. Retire them after it is returned.`);
    const updated = await tx.waiter.update({ where: { id: cur.id }, data });
    const what = data.name && data.name !== cur.name ? `${cur.name} renamed to ${data.name}`
      : data.active === false ? `${cur.name} retired`
      : data.active === true ? `${cur.name} restored` : `${cur.name} updated`;
    await audit(tx, req.user.id, 'WAITER_UPDATED', what);
    return updated;
  });
  res.json(waiterJson(w));
}));

// ---- distributor: issue a token (pot + waiter + time + payment) in one step
app.post('/tokens', authenticate, allow('distributor'), wrap(async (req, res) => {
  const { waiter_id, pot_id, minutes, amount } = req.body;
  const timing = req.body.pay_timing || 'immediate';
  if (!TIMINGS[timing]) throw httpError(400, 'Invalid payment option.');
  const paidNow = timing === 'immediate';
  // The method is only known now when the customer pays now; otherwise it is set when they pay.
  const method = paidNow ? req.body.method : (METHODS[req.body.method] ? req.body.method : 'cash');
  if (!(minutes > 0) || !(amount > 0) || !METHODS[method]) throw httpError(400, 'Invalid time, amount or method.');
  if (!isUuid(pot_id) || !isUuid(waiter_id)) throw httpError(400, 'Choose a pot and a waiter.');

  for (let attempt = 0; attempt < 10; attempt++) {
    try {
      const t = await prisma.$transaction(async (tx) => {
        // Lock the pot row so it cannot be handed out twice concurrently.
        await tx.$queryRaw`SELECT id FROM pots WHERE id = ${pot_id}::uuid FOR UPDATE`;
        const pot = await tx.pot.findFirst({ where: { id: pot_id, active: true } });
        if (!pot) throw httpError(400, 'Unknown pot.');
        if (await tx.token.findFirst({ where: { potId: pot.id, status: 'out' } }))
          throw httpError(409, `${pot.label} is already out.`);
        const waiter = await tx.waiter.findFirst({ where: { id: waiter_id, active: true } });
        if (!waiter) throw httpError(400, 'Unknown waiter.');

        const now = new Date();
        const created = await tx.token.create({
          data: {
            code: randomCode(), waiterId: waiter.id, minutes: Math.round(minutes), amount, method,
            status: 'out', distributorId: req.user.id, potId: pot.id, clearedAt: now,
            payTiming: timing,
            paymentConfirmed: paidNow,
            paidAt: paidNow ? now : null,
            payDueAt: paidNow ? null : new Date(now.getTime() + PAY_WINDOW_MS),
          },
        });
        await audit(tx, req.user.id, 'POT_OUT',
          `${pot.label} to ${waiter.name} · ${minutes} min · ${fmt(amount)} · ` +
          (paidNow ? METHODS[method] : `UNPAID (${TIMINGS[timing]}, within 12 h)`),
          created.id);
        return findToken(tx, created.id);
      });
      return res.status(201).json(t);
    } catch (e) {
      if (e.code === 'P2002') continue; // random code collided - retry
      throw e;
    }
  }
  throw httpError(500, 'Could not generate a unique token number.');
}));

// Extra time bought by the customer; the distributor takes the payment, so it is confirmed at once.
app.post('/tokens/:id/extend', authenticate, allow('distributor'), uuidParam, wrap(async (req, res) => {
  const { minutes, fee, method } = req.body;
  if (!(minutes > 0) || !(fee > 0) || !METHODS[method]) throw httpError(400, 'Invalid time, fee or method.');
  const t = await prisma.$transaction(async (tx) => {
    const tok = await lockToken(tx, req.params.id);
    if (tok.status !== 'out') throw httpError(409, 'Only pots that are out can be extended.');
    await tx.extension.create({
      data: {
        tokenId: tok.id, minutes: Math.round(minutes), fee, method, byUserId: req.user.id,
        confirmed: true, confirmedById: req.user.id,
      },
    });
    const full = await findToken(tx, tok.id);
    await audit(tx, req.user.id, 'EXTENDED',
      `${full.pot_label} +${minutes} min · ${fmt(fee)} · ${METHODS[method]}`, tok.id);
    return full;
  });
  res.json(t);
}));

// Collect the payment for a token that was not paid when the pot went out.
app.post('/tokens/:id/pay', authenticate, allow('distributor'), uuidParam, wrap(async (req, res) => {
  const { method } = req.body;
  if (!METHODS[method]) throw httpError(400, 'Choose how it was paid.');
  const t = await prisma.$transaction(async (tx) => {
    const tok = await lockToken(tx, req.params.id);
    if (tok.paymentConfirmed) throw httpError(409, 'This token is already paid.');
    const now = new Date();
    await tx.token.update({ where: { id: tok.id }, data: { method, paymentConfirmed: true, paidAt: now } });
    const full = await findToken(tx, tok.id);
    const late = tok.payDueAt && now > tok.payDueAt ? ' (after the 12 h limit)' : '';
    await audit(tx, req.user.id, 'PAYMENT_RECEIVED',
      `${full.pot_label} · ${full.waiter_name} paid ${fmt(full.amount)} by ${METHODS[method]}${late}`, tok.id);
    return full;
  });
  res.json(t);
}));

app.get('/tokens/unpaid', authenticate, allow('distributor', 'manager'), wrap(async (_req, res) => {
  const rows = await prisma.token.findMany({
    where: { paymentConfirmed: false }, include: TOKEN_INCLUDE, orderBy: { payDueAt: 'asc' },
  });
  res.json(rows.map(tokenJson));
}));

app.get('/pots/available', authenticate, allow('distributor'), wrap(async (_req, res) => {
  const pots = await prisma.pot.findMany({
    where: { active: true, tokens: { none: { status: 'out' } } },
    orderBy: { label: 'asc' },
    select: { id: true, label: true },
  });
  res.json(pots);
}));

// Inventory: every pot with whether it is currently out.
app.get('/pots', authenticate, allow('distributor', 'manager'), wrap(async (_req, res) => {
  const pots = await prisma.pot.findMany({
    orderBy: { label: 'asc' },
    include: { tokens: { where: { status: 'out' }, select: { id: true }, take: 1 } },
  });
  res.json(pots.map((p) => ({ id: p.id, label: p.label, active: p.active, out: p.tokens.length > 0 })));
}));

// Register N pots; each gets a random, never-reused tracking number (P-1000..P-9999).
app.post('/pots/register', authenticate, allow('distributor'), wrap(async (req, res) => {
  const count = Number(req.body.count);
  if (!Number.isInteger(count) || count < 1 || count > 100)
    throw httpError(400, 'Register between 1 and 100 pots at a time.');

  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const made = await prisma.$transaction(async (tx) => {
        const taken = new Set((await tx.pot.findMany({ select: { label: true } })).map((p) => p.label));
        if (taken.size + count > 9000) throw httpError(409, 'Not enough unique pot numbers left.');
        const labels = [];
        while (labels.length < count) {
          const l = `P-${crypto.randomInt(1000, 10000)}`;
          if (!taken.has(l)) { taken.add(l); labels.push(l); }
        }
        await tx.pot.createMany({ data: labels.map((label) => ({ label })) });
        await audit(tx, req.user.id, 'POTS_REGISTERED',
          `${count} pot(s) registered: ${labels.join(', ')}`);
        return tx.pot.findMany({ where: { label: { in: labels } }, orderBy: { label: 'asc' } });
      });
      return res.status(201).json(made.map((p) => ({ id: p.id, label: p.label, active: p.active, out: false })));
    } catch (e) {
      if (e.code === 'P2002') continue; // another distributor took a number at the same moment
      throw e;
    }
  }
  throw httpError(500, 'Could not generate unique pot numbers. Try again.');
}));

app.patch('/pots/:id', authenticate, allow('distributor'), uuidParam, wrap(async (req, res) => {
  if (typeof req.body.active !== 'boolean') throw httpError(400, '`active` is required.');
  const active = req.body.active;
  await prisma.$transaction(async (tx) => {
    await tx.$queryRaw`SELECT id FROM pots WHERE id = ${req.params.id}::uuid FOR UPDATE`;
    const pot = await tx.pot.findUnique({ where: { id: req.params.id } });
    if (!pot) throw httpError(404, 'Pot not found.');
    if (!active && (await tx.token.findFirst({ where: { potId: pot.id, status: 'out' } })))
      throw httpError(409, `${pot.label} is out. Retire it after it is returned.`);
    await tx.pot.update({ where: { id: pot.id }, data: { active } });
    await audit(tx, req.user.id, active ? 'POT_RESTORED' : 'POT_RETIRED', pot.label);
  });
  res.json({ ok: true });
}));

app.post('/tokens/:id/return', authenticate, allow('distributor'), uuidParam, wrap(async (req, res) => {
  const t = await prisma.$transaction(async (tx) => {
    const tok = await lockToken(tx, req.params.id);
    if (tok.status !== 'out') throw httpError(409, 'This pot is not out.');
    await tx.token.update({ where: { id: tok.id }, data: { status: 'returned', returnedAt: new Date() } });
    const full = await findToken(tx, tok.id);
    await audit(tx, req.user.id, 'POT_RETURNED', `${full.pot_label} returned by ${full.waiter_name}`, tok.id);
    return full;
  });
  res.json(t);
}));

app.get('/tokens/active', authenticate, allow('distributor', 'manager'), wrap(async (_req, res) => {
  const rows = await prisma.token.findMany({
    where: { status: 'out' }, include: TOKEN_INCLUDE, orderBy: { clearedAt: 'asc' },
  });
  res.json(rows.map(tokenJson));
}));

// ---- users (staff who sign in; waiters are in /waiters)
app.get('/users', authenticate, allow('manager'), wrap(async (req, res) => {
  const role = req.query.role;
  if (role && !['manager', 'distributor'].includes(role)) throw httpError(400, 'Bad role.');
  const rows = await prisma.user.findMany({
    where: role ? { role } : {},
    orderBy: [{ role: 'asc' }, { name: 'asc' }],
  });
  res.json(rows.map(publicUser));
}));

// ---- manager
const mgr = [authenticate, allow('manager')];

function range(req) {
  const from = new Date(req.query.from), to = new Date(req.query.to);
  if (isNaN(from) || isNaN(to)) throw httpError(400, 'from/to must be ISO dates.');
  return { gte: from, lt: to };
}

app.get('/manager/tokens', ...mgr, wrap(async (req, res) => {
  const rows = await prisma.token.findMany({
    where: { issuedAt: range(req) }, include: TOKEN_INCLUDE, orderBy: { issuedAt: 'asc' },
  });
  res.json(rows.map(tokenJson));
}));

app.get('/manager/audit', ...mgr, wrap(async (req, res) => {
  const rows = await prisma.auditLog.findMany({
    where: { at: range(req) }, include: { actor: true }, orderBy: { at: 'desc' },
  });
  res.json(rows.map((a) => ({
    id: a.id.toString(), at: a.at, actor_name: a.actor.name, actor_role: a.actor.role,
    action: a.action, detail: a.detail,
  })));
}));

function tempPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let p = '';
  for (let i = 0; i < 10; i++) p += alphabet[crypto.randomInt(alphabet.length)];
  return `${p}#7`;
}

app.post('/manager/users', ...mgr, wrap(async (req, res) => {
  const name = String(req.body.name || '').trim();
  const email = String(req.body.email || '').trim().toLowerCase();
  const role = req.body.role;
  if (!name || !email.includes('@') || !['manager', 'distributor'].includes(role))
    throw httpError(400, 'Name, valid email and role are required.');
  if (await prisma.user.findUnique({ where: { email } }))
    throw httpError(409, 'A user with that email already exists.');
  const password = tempPassword();
  const { data, error } = await supabase.auth.admin.createUser({
    email, password, email_confirm: true, user_metadata: { name },
  });
  if (error) throw httpError(400, error.message);

  let user;
  try {
    user = await prisma.$transaction(async (tx) => {
      const u = await tx.user.create({ data: { authId: data.user.id, name, email, role } });
      await audit(tx, req.user.id, 'USER_ENROLLED', `${name} (${role}) enrolled`);
      return u;
    });
  } catch (e) {
    await supabase.auth.admin.deleteUser(data.user.id).catch(() => {});
    throw e;
  }
  // Email is a bonus, never a requirement: the manager's app also receives the temporary
  // password and can hand it over by email app, WhatsApp, SMS, etc. Not awaited, so a
  // blocked mail port can never slow down or fail enrolment.
  emailInBackground(email, inviteMail({ name, email, role, password }));
  res.status(201).json({ ...publicUser(user), temp_password: password });
}));

app.patch('/manager/users/:id', ...mgr, uuidParam, wrap(async (req, res) => {
  const u = await prisma.user.findUnique({ where: { id: req.params.id } });
  if (!u) throw httpError(404, 'User not found.');

  // Body with name/email (and no `active`) edits login details.
  if (typeof req.body.active !== 'boolean') {
    return res.json(publicUser(await changeDetails(u, req.user, req.body, 'USER_EDITED')));
  }

  const active = req.body.active;
  if (req.params.id === req.user.id) throw httpError(400, 'You cannot disable yourself.');
  // Ban in Auth so existing sessions stop refreshing; `active` blocks API use immediately.
  const { error } = await supabase.auth.admin.updateUserById(u.authId, { ban_duration: active ? 'none' : '876000h' });
  if (error) throw httpError(502, error.message);
  await prisma.$transaction(async (tx) => {
    await tx.user.update({
      where: { id: u.id },
      data: active ? { active, failedAttempts: 0, lockedUntil: null } : { active },
    });
    await audit(tx, req.user.id, active ? 'USER_ENABLED' : 'USER_DISABLED', u.name);
  });
  res.json({ ok: true });
}));

app.post('/manager/users/:id/resend', ...mgr, uuidParam, wrap(async (req, res) => {
  const u = await prisma.user.findUnique({ where: { id: req.params.id } });
  if (!u) throw httpError(404, 'User not found.');
  const password = tempPassword();
  // Also lifts any lockout ban (but never un-bans a manager-disabled account).
  const { error } = await supabase.auth.admin.updateUserById(u.authId,
    u.active ? { password, ban_duration: 'none' } : { password });
  if (error) throw httpError(502, error.message);
  await prisma.$transaction(async (tx) => {
    await tx.user.update({ where: { id: u.id }, data: { failedAttempts: 0, lockedUntil: null } });
    await tx.alert.updateMany({ where: { userId: u.id, resolvedAt: null }, data: { resolvedAt: new Date() } });
    await audit(tx, req.user.id, 'CREDENTIALS_SENT', `New login details emailed to ${u.name}`);
  });
  emailInBackground(u.email, inviteMail({ name: u.name, email: u.email, role: u.role, password }));
  res.json({ ok: true, temp_password: password });
}));

app.get('/manager/alerts', ...mgr, wrap(async (_req, res) => {
  const rows = await prisma.alert.findMany({
    where: { resolvedAt: null }, include: { user: true }, orderBy: { createdAt: 'desc' },
  });
  res.json(rows.map((a) => ({
    id: a.id, user_id: a.userId, user_name: a.user.name, user_email: a.user.email,
    user_role: a.user.role, message: a.message, at: a.createdAt,
  })));
}));

app.post('/manager/alerts/:id/dismiss', ...mgr, uuidParam, wrap(async (req, res) => {
  const { count } = await prisma.alert.updateMany({
    where: { id: req.params.id, resolvedAt: null }, data: { resolvedAt: new Date() },
  });
  if (!count) throw httpError(404, 'Alert not found.');
  res.json({ ok: true });
}));

app.get('/manager/smtp', ...mgr, wrap(async (_req, res) => {
  const s = await getSmtp();
  res.json({ host: '', port: 587, secure: false, username: '', password: '', from_name: 'Arrows Bar', from_email: '', ...s });
}));

app.put('/manager/smtp', ...mgr, wrap(async (req, res) => {
  const b = req.body;
  const smtp = {
    host: String(b.host || '').trim(), port: Number(b.port) || 587, secure: !!b.secure,
    username: String(b.username || ''), password: String(b.password || ''),
    from_name: String(b.from_name || 'Potie'), from_email: String(b.from_email || ''),
  };
  await prisma.$transaction(async (tx) => {
    await tx.setting.upsert({ where: { id: 1 }, update: { smtp }, create: { id: 1, smtp } });
    await audit(tx, req.user.id, 'SMTP_UPDATED', `SMTP host ${smtp.host}:${smtp.port}`);
  });
  res.json({ ok: true });
}));

app.post('/manager/smtp/test', ...mgr, wrap(async (req, res) => {
  await send({ to: req.body.to || req.user.email, subject: 'Potie SMTP test', text: 'SMTP is working.' });
  res.json({ ok: true });
}));

// ---------------------------------------------------------------- errors
app.use((_req, _res, next) => next(httpError(404, 'Not found')));
app.use((err, _req, res, _next) => {
  if (!err.status) console.error(err);
  res.status(err.status || 500).json({
    error: err.status ? err.message : 'Server error',
    ...(err.extra || {}),
  });
});

const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`Potie API listening on :${port}`));
