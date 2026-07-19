# Tailor Manager — Supabase Edition

## File structure (kept as simple as possible)

```
index.html         ← login
dashboard.html      ← urgency-grouped job overview
orders.html          ← full order list, view-only for workers
order.html            ← single order detail
new-order.html         ← admin: create + assign a job
admin.html               ← admin: staff, permissions, branding, workload
financials.html            ← income/expenses/salaries report
schema.sql                   ← run once in Supabase SQL Editor
schema-additions.sql          ← run once, after schema.sql
supabase/functions/create-staff/index.ts   ← one small server-side file (see step 5)
```

Each `.html` file is fully self-contained — its own styling and its own logic
are written directly inside that file. There's no separate `css/` or `js/`
folder to dig through. The only outside code this loads is two standard
libraries every website uses: Bootstrap (layout/styling helpers) and the
Supabase library (talks to the database) — both pulled from a CDN link in
the `<head>`, same as any normal website.

The one exception is `create-staff/index.ts` — a small piece of code that
runs on Supabase's own servers (not your phone, not GitHub Pages) so that
adding a new staff login can be done safely from inside the Admin Panel
without exposing a secret key in the browser. You paste it into Supabase's
dashboard once, and never touch it again.

## 1. Create the Supabase project

1. supabase.com → New Project (free tier). Note the **Project URL** and
   **anon public key** (Project Settings → API).
2. SQL Editor → paste and run `schema.sql`, then `schema-additions.sql`.
3. Database → Extensions → enable **pg_cron** (for the scheduled reminders).
4. Authentication → Providers → turn OFF **Confirm email**.

## 2. Deploy the staff-creation function (one-time, no CLI)

Dashboard → Edge Functions → Deploy a new function → name it `create-staff`
→ paste in the contents of `supabase/functions/create-staff/index.ts` →
Deploy. That's it — the "Add Staff" button in the Admin Panel calls this
function automatically from now on.

## 3. Fill in the frontend config

Every `.html` file has these two lines near the top of its `<script>` block:
```js
const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";
```
Update them in **all 7 files** (find-and-replace across the folder is
fastest). This is the one trade-off of keeping everything self-contained —
one value repeated in a few places instead of one shared config file.

## 4. Create the first admin login

Authentication → Users → Add user:
- Email: `2547XXXXXXXX@tailor.local` (real phone digits, no +)
- Password: whatever he'll use to log in
- Copy the **User UID**.

SQL Editor:
```sql
insert into staff (id, name, phone, role)
values ('paste-the-uid-here', 'Admin Name', '0712345678', 'admin');
```
He logs in at the site with `0712345678` + that password. Every staff
member added after this one goes through the in-app **Add Staff** form —
no dashboard trips needed.

## 5. Host it (free)

Push this folder to GitHub → Settings → Pages → deploy from main branch.
Same approach as your other static projects.

## Look & feel

Custom theme, not default Bootstrap: warm paper background, deep oxblood
accent, brass-gold highlights, a serif (Fraunces) for headings paired with
a clean sans (Work Sans), and a dashed "stitch line" motif used as borders
and dividers throughout — a nod to actual tailoring.

## How the roles work

- **Admin**: logs every order (customer, garment type — picked from a
  dropdown that swaps in the right measurement fields for that garment —
  material, measurements, total, deposit, due date), assigns it to a
  worker, records payments, marks jobs complete, adds staff, and controls
  every permission below.
- **Workers**: log in with their own phone + password, view-only dashboard
  and order list, and get notified on: new task assigned to them (with
  their name/number, assign date, completion date), payments received,
  jobs completed, and the daily work-status summary — each individually
  toggleable per worker from the Admin page.

## Permissions admin controls

- Whether workers can see payment amounts/balances (off by default)
- Whether workers can see the Financials section (off by default)
- What time the daily work-status reminder fires
- What time and how often (daily/monthly/yearly) the financial report
  notification fires — sent to admin only

## Not yet included

Till/Paystack for remote customer payments — still on hold. `payments.method`
already has a slot for it whenever you're ready.
