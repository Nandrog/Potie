# Potie – shisha pot tracking

Flutter app (manager / waiter / distributor) + Node API using **Prisma** on a **Supabase** Postgres, with **Supabase Auth** for login.

```
Flutter ──(Supabase Auth: login, JWT)──▶ Supabase Auth
   │
   └──(REST + Bearer JWT)──▶ Node API ──(Prisma)──▶ Supabase Postgres
```
Prisma is server-side only, so the app talks to the API, not the database. The Supabase service-role key lives only on the server.

## Run the app instantly (demo mode, no server)
```
flutter run
```
Demo logins: `manager@potie.app / Manager@123`, `waiter1@potie.app / Waiter@123`, `distributor@potie.app / Distro@123`.

## Run against Supabase
1. Create a Supabase project. Note: Project Settings → **API** (URL, anon key, service_role key) and **Database** (connection strings).
2. Server:
   ```
   cd server
   cp .env.example .env     # fill in the values
   npm install              # also runs prisma generate
   npm run db:push          # creates tables and enables Row Level Security
   npm run seed             # Auth users + DB rows (pots are registered in the app)
   npm start
   ```
3. App (anon key only – never the service-role key):
   ```
   flutter run --dart-define=API_URL=http://<server-ip>:8080 \
               --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
               --dart-define=SUPABASE_ANON_KEY=<anon key>
   ```
   Or fill in `app.env` once and run `flutter run --dart-define-from-file=app.env`.
   Android emulator: use `http://10.0.2.2:8080`. Use HTTPS in production.

## Sign-in protection
Login goes through the API (`POST /auth/login`). 3 wrong passwords lock the account for **10 seconds**
(also applied as a 10 s ban in Supabase Auth). A successful sign-in restarts the attempt count.
A lockout raises an alert in the manager's bell icon (and emails managers if SMTP is set) until the
manager renews the user's password or dismisses it.

## Roles
* **Manager** - day overview, audit trail, enrolls managers/distributors, SMTP setup, PDF reports.
* **Distributor** - runs the floor: registers waiters and pots, issues tokens, extends time,
  records pots as returned, prints tokens.
* **Waiters do not sign in.** They are just names the distributor registers (*Waiters* tab) and then
  picks from a drop-down when issuing a token.

## Flow
0. Distributor (once, and whenever stock changes): *Waiters* tab -> **Register waiter**; *Pots* tab -> **Register pots**
   (each pot gets a random unique number, e.g. `P-4821`; print the tags and stick them on the pots).
1. Distributor: *Issue token* -> waiter, pot, time, amount, method -> **Issue pot & generate token**.
   The timer starts, a random 6-digit token number is generated and the token can be printed.
2. Distributor: *Live* tab shows every pot that is out with a live countdown and progress bar (closest to time-up first); **Extend** if the customer buys more time.
3. When time is up the distributor tells the waiter to bring the pot back, then taps **Returned**
   (recorded with the time in the audit trail and reports).
4. Manager: day overview, audit trail, PDF reports.

## Payment options
When issuing a token the distributor picks **Pay now** (method recorded at once), **Pay on return** or
**Pay later**. The two deferred options must be settled within **12 hours** of the pot going out: they show
under the *Unpaid* tab (and as UNPAID on the live card and printed slip) with a countdown, turn red past
12 h, and are collected with **Collect payment** (also offered when the pot is returned). Reports count only
money received, and list outstanding payments separately. Run `npm run db:push` after upgrading (adds columns).

## Time-up alerts and staying signed in
* When a pot's time runs out the distributor (and manager) get a sound + banner in the app, and a system
  notification: on Android/iOS it is scheduled with the OS (works with the app closed); on web/macOS it
  appears while the app is open. Tap the bell in the app bar once to allow notifications.
* Refreshing the page / restarting the app keeps you signed in. You only go back to login if the session
  was really revoked or you signed out.

## Printing
Tokens, pot tags and reports carry the **Arrows Bar** logo (`assets/images/arrows_bar_logo.png`).
The printer icon in the distributor's app bar sets up the printer:
* Desktop (Windows/macOS/Linux) and iOS: **Choose** a printer once; tokens then print straight to it.
* Android: connect the printer (Bluetooth / Wi-Fi / USB, e.g. an 80mm thermal printer with its print
  service) in the phone's print settings; the system print dialog then lets you pick it.
Token slips are laid out for 80mm paper rolls.

**Bluetooth thermal printers (Android):** pair the printer in Android's Bluetooth settings, then in the app tap the
printer icon -> *Bluetooth printer* -> **Choose**, and pick 58 mm or 80 mm paper. Tokens then print over Bluetooth
(ESC/POS printers). Reports and pot tags still use the normal print dialog. iPhones cannot use these printers.

## Upgrading from the earlier version
Waiters used to be users with a login. The schema changed (new `waiters` table, tokens now point to it,
the `waiter` user role is gone), so for a development database run `npx prisma db push --force-reset`
in `server/` and then `npm run seed` again; old tokens cannot be migrated automatically.
