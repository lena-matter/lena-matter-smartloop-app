# SmartLoop Dashboard — Setup & Data‑Sovereignty Guide

A fully wired SmartLoop dashboard for Matter IO's schools ocean‑plastic platform. It connects to **Supabase** for live data (students, ThinkLid bin sensors, leaderboards, global challenge, ACARA curriculum) and is built around a **data‑residency model** for the planned rollout: Australia pilot → Singapore & New Zealand → US/Canada, India, Europe.

## What's in the box

| File | Purpose |
|---|---|
| `index.html` | The dashboard. Reuses your existing SmartLoop UI framework, wired to Supabase via `supabase-js`. Runs on bundled demo data out of the box; goes live when you add credentials. |
| `schema.sql` | One‑shot Supabase migration: tables, views, Row‑Level Security, realtime, and seed data (AU pilot + SG/NZ + partner schools). |
| `SETUP.md` | This file. |

---

## Quick start (≈10 minutes)

### 1. Try it immediately (no account needed)
Open `index.html` in a browser. It runs in **demo mode** on bundled data so you can see every screen working. The amber banner up top confirms you're on demo data.

### 2. Create a Supabase project — choose the region deliberately
This is a **data‑residency decision**, not a default. For the AU pilot + Singapore + NZ launch, pick an APAC region:

- **Southeast Asia (Singapore) `ap‑southeast‑1`** — closest to Singapore; fine for AU/NZ too, or
- **Sydney `ap‑southeast‑2`** — keeps Australian student data on Australian soil (cleanest story for the WA education department).

Either covers Phase 1–2. You split out other regions later (see *Data sovereignty* below).

### 3. Load the schema
In the Supabase dashboard → **SQL Editor** → paste the contents of `schema.sql` → **Run**. This creates everything and seeds demo content. (Or `supabase db push` if you use the CLI.)

### 4. Wire up the dashboard
In Supabase → **Project Settings → API**, copy the **Project URL** and the **`anon` / public** key. Open `index.html`, find the `CONFIG` block near the top of the `<script>`, and paste them in:

```js
const CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi...",   // the ANON / public key ONLY
};
```

> ⚠️ **Only ever use the `anon` (public) key in the browser.** Never paste the `service_role` / secret key into `index.html` — it bypasses all security. Keep it server‑side only.

Reload the page. The banner turns green: **Connected to your Supabase project — showing live data.** Logging an activity now writes to `activity_logs`; the Live Bin Status page subscribes to realtime `bin_readings` and updates the moment a ThinkLid sensor reports.

### 5. Deploy
It's a single static file — host it anywhere (GitHub Pages, Netlify, Cloudflare Pages, your existing ThinkOS site). No build step.

---

## How it maps to the business plan

| Business‑plan element | Where it lives |
|---|---|
| Student "My Earth‑Saving Journey" dashboard | `eco_heroes` + `hero_impact` view (trees / waste / CO₂ / water derived from logged actions) |
| Live Bin Status — real‑time ThinkLid data | `bins` + `bin_readings` (+ realtime) → `bin_status` view |
| Leaderboard & class challenge | `school_leaderboard` view |
| ACARA‑aligned 8‑week curriculum | `curriculum_weeks` + `curriculum_progress` |
| Global EcoChallenge (8 countries) | `global_challenges` + `country_scores` |
| QR‑traceable lid provenance | `bins.thinklid_serial` (ready to resolve to GRS/OBP batch records) |

### Feeding real ThinkLid sensor data
Each lid POSTs a reading into `bin_readings` (`bin_id`, `fill_pct`, optional `weight_kg`). Options: have the firmware/gateway call Supabase's auto‑generated REST endpoint with the `anon` key, or (preferred for fleet hardware) post to a small Edge Function / ingest service holding the `service_role` key. The dashboard's realtime subscription renders new readings live — no polling.

---

## Data sovereignty & residency — the design

You're putting **children's data across multiple jurisdictions** (AU, NZ, SG, then US/CA, IN, EU), so this is built in from day one rather than bolted on.

### Principle 1 — Pseudonymous by design (PII minimisation)
`eco_heroes` stores a **handle + avatar only** — *no* legal names, emails, or dates of birth. Teachers keep the handle→student mapping offline. This deliberately keeps the platform out of scope for the heaviest child‑data consent regimes in this first build:

- **EU GDPR Art. 8** (parental consent for under‑16s)
- **US COPPA** (under‑13)
- **India DPDP Act 2023** (verifiable parental consent for minors)

The schema carries a comment forbidding name/email/DOB columns on `eco_heroes`. Keep it that way until you have a consent + verification flow.

### Principle 2 — Residency‑ready, single region now
One Supabase project in an APAC region serves Phase 1–2. But every row is **already tagged for where it must eventually live**:

- `regions` — a registry mapping each jurisdiction to its required physical Supabase region, its governing privacy law, and whether residency is *mandatory*.
- `schools.data_region` + `schools.country_code` — every school knows its jurisdiction and target region.

The dashboard's region pill (top‑right) reads this registry and shows which Supabase region each school's data lives in — so residency is visible, not buried.

| Region | Physical Supabase region | Privacy regime | Residency required? |
|---|---|---|---|
| OCEANIA (AU, NZ) | Sydney `ap‑southeast‑2` | AU Privacy Act 1988 · NZ Privacy Act 2020 | No (co‑locate to start) |
| APAC_SE (SG) | Singapore `ap‑southeast‑1` | Singapore PDPA | No |
| NA (US, CA) | `us‑east‑1` | COPPA · PIPEDA / Québec Law 25 | **Yes** |
| INDIA (IN) | Mumbai `ap‑south‑1` | India DPDP Act 2023 | **Yes** |
| EU (SE, DE…) | Frankfurt `eu‑central‑1` | EU GDPR | **Yes** |

### Principle 3 — Split to multi‑region without rework
When a market with `residency_required = true` (EU, India, US/Canada) reaches the threshold where its data must be stored in‑jurisdiction, you:

1. Spin up a **second Supabase project in that region** using the *same* `schema.sql`.
2. Migrate that region's rows (filter by `data_region`).
3. Point the dashboard's region‑router at the new endpoint for that country. The `DB` data layer in `index.html` is already a single abstraction, so this becomes a per‑region `{ url, anonKey }` lookup keyed off the school's `data_region` — **no schema or query changes**.

Cross‑region **aggregates** (the Global EcoChallenge country leaderboard) should be computed from *non‑personal, pre‑aggregated* `country_scores` totals pushed up from each regional project — never by moving student‑level rows across borders.

---

## Security checklist before any real student data

The shipped RLS policies are **demo‑grade**: they let the public `anon` key read gameplay data and append activity logs / bin readings, which is what an unauthenticated demo needs. Before a real pilot:

- [ ] Add **Supabase Auth** with `teacher` / `school_admin` roles; scope reads/writes to a teacher's own `school_id` via RLS.
- [ ] Remove the broad `anon` read/insert/update policies; replace with role‑based ones.
- [ ] Move ThinkLid ingestion behind an **Edge Function** holding the `service_role` key, not the browser.
- [ ] Keep `eco_heroes` pseudonymous; if real rosters are ever needed, gate them behind consent and store them in a separate, access‑controlled table — not in `eco_heroes`.
- [ ] Turn on Supabase **Point‑in‑Time Recovery** and review log retention per region.

---

*Matter IO Pty Ltd — closing the loop on plastic. SmartLoop connects schools around the world on the ocean‑plastic mission.*
