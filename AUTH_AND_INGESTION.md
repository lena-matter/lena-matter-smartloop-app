# SmartLoop — Auth-gated RLS & ThinkLid Ingestion

This adds production security on top of the base build: real teacher/admin sign-in with school-scoped access, and a hardware ingestion endpoint for ThinkLid sensors. Apply it after `schema.sql`.

## Files

| File | What it does |
|---|---|
| `auth_rls.sql` | `profiles` table (Auth user → school + role), helper functions, drops the demo-open policies, and installs role/school-scoped RLS on every table. Adds the `devices` registry + `register_thinklid()` key issuer. |
| `supabase/functions/thinklid-ingest/index.ts` | Edge Function: authenticates a lid by its device key, writes to `bin_readings` via the `service_role` key (bypassing RLS). |
| `supabase/functions/thinklid-ingest/simulate_thinklid.py` | Posts fake readings so you can watch the dashboard update live without hardware. |
| `index.html` | Now shows a sign-in overlay in **live mode** (demo mode is unchanged). |

---

## Part A — Auth-gated RLS

### Roles
| Role | Can do |
|---|---|
| `teacher` | Read their **own school's** heroes, bins, readings, leaderboard, curriculum; log activities. |
| `school_admin` | Teacher rights **+** manage bins, devices, classes, heroes, curriculum progress for their school. |
| `super_admin` | Everything, all schools (Matter IO staff). |

Reference/aggregate data (`regions`, `countries`, `activities`, `badges`, `curriculum_weeks`, `global_challenges`, `country_scores`) stays **public-readable** — it carries no student or campus data, so a public landing page or the global leaderboard can still render without login.

### Deploy
1. Run `schema.sql` first (if you haven't), then run **`auth_rls.sql`** in the Supabase SQL Editor.
2. In **Authentication → Providers**, keep **Email** enabled. For staff-only signup, turn **off** public sign-ups (Authentication → Settings) and invite users instead.
3. Create your first users (**Authentication → Users → Add user**). A `profiles` row is auto-created by trigger (role `teacher`, no school).
4. Assign roles/schools (SQL Editor), e.g.:
   ```sql
   update public.profiles set role='super_admin' where email='len@matter.city';
   update public.profiles set role='school_admin',
     school_id='11111111-1111-1111-1111-111111111111'
     where email='teacher@citybeachps.wa.edu.au';
   ```
5. Open `index.html` with your `CONFIG` filled in → you'll get the sign-in overlay → log in. A teacher only ever sees their own school; RLS does the filtering, so no client-side trust is involved.

### Why this is safe
- Students stay **pseudonymous** — they never get auth accounts; only staff do.
- The browser only ever holds the **anon** key; every row it can see is enforced by Postgres RLS, not by the dashboard.
- Helper functions are `SECURITY DEFINER` with a pinned `search_path`, so policy checks can read `profiles` without recursive RLS.
- A user with no `school_id` sees **nothing** until an admin assigns one (the dashboard shows a "not linked to a school yet" banner).

---

## Part B — ThinkLid sensor ingestion

Sensors are not logged-in users, so they don't use the anon key or RLS. Each lid gets its **own device key**; it posts to the Edge Function, which validates the key and writes the reading with the `service_role` key server-side.

### 1. Deploy the function
```bash
supabase functions deploy thinklid-ingest --no-verify-jwt
```
`--no-verify-jwt` is required: devices present a **device key**, not a Supabase JWT. `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically in the Supabase runtime — never put the service_role key anywhere client-side.

### 2. Register a lid → get its key (shown once)
As a `school_admin`/`super_admin`, call the RPC (SQL Editor, or `sb.rpc(...)` while signed in):
```sql
select public.register_thinklid(
  'TL-AU-0001',                                  -- ThinkLid serial (QR-traceable)
  'b0000000-0000-0000-0000-000000000001',        -- bin_id it reports for
  '11111111-1111-1111-1111-111111111111'         -- school_id
);
-- returns e.g. 'a1b2c3...'  ← store this on the lid/gateway NOW; only its hash is kept
```
Re-running for the same serial **rotates** the key.

### 3. Post a reading
```bash
curl -X POST "https://<project>.functions.supabase.co/thinklid-ingest" \
  -H "Authorization: Bearer <device_key>" \
  -H "Content-Type: application/json" \
  -d '{"serial":"TL-AU-0001","fill_pct":73,"weight_kg":4.2}'
# -> 201 {"ok":true,"ingested":1,"bin_id":"b0000000-..."}
```
Batch form (a gateway serving several lids):
```json
{ "readings": [ {"serial":"TL-AU-0001","fill_pct":73}, {"serial":"TL-AU-0005","fill_pct":41} ] }
```
`fill_pct` (0–100) is required; `weight_kg`, `serial`, and `recorded_at` (ISO-8601) are optional. Validation rejects out-of-range values, bad JSON, inactive/unknown keys, serial mismatches, and unlinked devices.

### 4. See it live
The dashboard's **Live Bin Status** page subscribes to `bin_readings` via Supabase Realtime — a successful POST appears within ~1s, no refresh. To demo without hardware:
```bash
export FN_URL="https://<project>.functions.supabase.co/thinklid-ingest"
export DEVICE_KEY="<key from register_thinklid>"
python3 supabase/functions/thinklid-ingest/simulate_thinklid.py --serial TL-AU-0001 --interval 5
```

### Data flow
```
ThinkLid lid ──Bearer device key──▶ Edge Function (service_role) ──INSERT──▶ bin_readings
                                                                                  │ Realtime (RLS-filtered)
                                                            teacher's browser ◀───┘  (own school only)
```

### Hardening for fleet scale (next steps when you're ready)
- Rotate device keys on a schedule; set `is_active=false` to decommission a lid instantly.
- Add a rate limit / dedupe window per device (e.g. reject >1 reading / 10s) if firmware is chatty.
- Consider HMAC-signed payloads (key + body) instead of a bearer key if you need replay protection.
- Resolve `thinklid_serial` to its GRS / Ocean-Bound-Plastic batch record for the QR provenance claim in the business plan.
