const nodemailer = require('nodemailer');
const { prisma } = require('./clients');

// SMTP comes from the manager's "Email setup" screen; if that is empty, fall back
// to SMTP_* values in server/.env so login emails work without any in-app setup.
function envSmtp() {
  if (!process.env.SMTP_HOST) return {};
  return {
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT) || 587,
    secure: process.env.SMTP_SECURE === 'true',
    username: process.env.SMTP_USER || '',
    password: process.env.SMTP_PASS || '',
    from_name: process.env.SMTP_FROM_NAME || process.env.APP_NAME || 'Arrows Bar',
    from_email: process.env.SMTP_FROM_EMAIL || process.env.SMTP_USER || '',
  };
}

async function getSmtp() {
  const row = await prisma.setting.findUnique({ where: { id: 1 } });
  const saved = row?.smtp || {};
  return saved.host ? saved : envSmtp();
}

async function send({ to, subject, text, html }) {
  const s = await getSmtp();
  if (!s.host) {
    const e = new Error('SMTP is not configured. Set it up under Email setup.');
    e.status = 400;
    throw e;
  }
  const transport = nodemailer.createTransport({
    host: s.host,
    port: s.port || 587,
    secure: !!s.secure,
    auth: s.username ? { user: s.username, pass: s.password } : undefined,
    // Fail fast: some hosts silently block outgoing mail ports, which otherwise hangs for minutes.
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000,
  });
  try {
    await transport.sendMail({
      from: `"${s.from_name || 'Arrows Bar'}" <${s.from_email || s.username}>`,
      to, subject, text, html,
    });
  } catch (err) {
    const blocked = ['ETIMEDOUT', 'ESOCKET', 'ECONNECTION', 'ECONNREFUSED'].includes(err.code);
    const e = new Error(blocked
      ? `Could not reach the email server ${s.host}:${s.port || 587}. The hosting may block this port - try port 2525 with a provider such as Brevo.`
      : `Email failed: ${err.message}`);
    e.status = 502;
    throw e;
  }
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function inviteMail({ name, email, role, password }) {
  const app = process.env.APP_NAME || 'Arrows Bar';
  const text =
    `Hi ${name},\n\nYou have been enrolled on ${app} as ${role}.\n\n` +
    `Email: ${email}\nTemporary password: ${password}\n\n` +
    `Sign in with these details, then change your password under Profile.\n`;
  const html =
    `<p>Hi ${esc(name)},</p><p>You have been enrolled on <b>${esc(app)}</b> as <b>${esc(role)}</b>.</p>` +
    `<p>Email: <b>${esc(email)}</b><br>Temporary password: <b>${esc(password)}</b></p>` +
    `<p>Sign in with these details, then change your password under Profile.</p>`;
  return { subject: `Your ${app} login details`, text, html };
}

module.exports = { send, inviteMail, getSmtp };
