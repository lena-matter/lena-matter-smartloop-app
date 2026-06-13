# SmartLoop

**SmartLoop** is the schools engagement and data layer for [Matter IO](mailto:len@matter.city)'s closed-loop ocean‑plastic program. It turns an ordinary school bin into a daily, measurable learning tool: recovered‑plastic **ThinkLid** sensors report real‑time fill data, students earn recognition for sorting and logging eco‑actions, and teachers run an ACARA‑aligned curriculum — all in one dashboard.

This repo contains a fully working dashboard wired to **Supabase**, built to connect schools around the world on the ocean‑plastic mission. Australia is the flagship pilot, with Singapore and New Zealand as the initial international markets and planned expansion to the US/Canada, India and Europe — so **data residency and sovereignty are designed in from day one**.

---

## Quick start

1. **Try it now** — open `index.html` in a browser. It runs on bundled demo data (no account needed); every screen works.
2. **Go live** — create a Supabase project, run `schema.sql` in the SQL editor, then paste your project URL + `anon` key into the `CONFIG` block near the top of `index.html`'s script. Reload — the banner turns green.

Full instructions, including the recommended region choice, are in **[SETUP.md](SETUP.md)**.

---

## What's in the dashboard

| Area | Backed by |
|---|---|
| Student "My Earth‑Saving Journey" (trees / waste / CO₂ / water) | `eco_heroes` + `hero_impact` |
| Log Activity (writes back, updates impact live) | `activities` + `activity_logs` |
| **Live Bin Status** — realtime ThinkLid fill data | `bins` + `bin_readings` (Supabase Realtime) |
| School leaderboard | `school_leaderboard` |
| Global EcoChallenge (8 countries) | `global_challenges` + `country_scores` |
| ACARA 8‑week curriculum | `curriculum_weeks` + `curriculum_progress` |
| Rewards Shop · Riplet Clubs · School Exchange | `rewards` · `clubs` · `exchange_messages` (`extras.sql`) |
| Recycling Game "Sort It Out!" (winnings write back) | `activity_logs` (`game`) |
| Admin: register/rotate lids, assign user roles & schools | `devices` · `profiles` |

---

## Files

| File | Purpose |
|---|---|
| `index.html` | The dashboard — single self‑contained file. Demo‑data fallback + live Supabase mode + sign‑in. |
| `schema.sql` | Core database: tables, views, RLS, realtime, seed data. Residency‑ready. |
| `auth_rls.sql` | Supabase Auth + teacher/school_admin/super_admin roles, school‑scoped RLS, device registry. |
| `extras.sql` | Rewards, Clubs, School Exchange, cultural quests, and the game write‑back. |
| `supabase/functions/thinklid-ingest/index.ts` | Edge Function: authenticates a lid by device key, writes readings via `service_role`. |
| `supabase/functions/thinklid-ingest/simulate_thinklid.py` | Posts fake readings to watch the dashboard update live with no hardware. |
| `SETUP.md` | Setup + the data‑sovereignty / residency architecture. |
| `AUTH_AND_INGESTION.md` | Deploying auth roles and the ThinkLid ingestion endpoint. |

---

## Data sovereignty & residency

Because this handles **children's data across multiple jurisdictions**, three principles are built in:

- **Pseudonymous students** — `eco_heroes` stores a handle + avatar only, no names/emails/DOB. This keeps the platform out of scope for the heaviest child‑data consent regimes (GDPR Art. 8, COPPA, India DPDP). Only staff get accounts.
- **Residency‑ready, single region now** — one Supabase project (recommended APAC region) serves the AU pilot + Singapore + NZ, but every school is tagged with its `country_code` and `data_region`, and a `regions` registry maps each jurisdiction to the physical region its data must live in.
- **Split without rework** — when a residency‑required market (EU, India, US/Canada) reaches scale, stand up a regional Supabase project with the same schema, migrate that region's rows, and point the dashboard's region‑router at it.

Details and the multi‑region roadmap are in **[SETUP.md](SETUP.md)**.

---

## Security

The base `schema.sql` ships demo‑grade open RLS so the dashboard runs unauthenticated. Before any real pilot, apply **`auth_rls.sql`** to switch to role‑based, school‑scoped policies, and route ThinkLid ingestion through the Edge Function (which holds the `service_role` key server‑side — never the browser). See **[AUTH_AND_INGESTION.md](AUTH_AND_INGESTION.md)**.

---

*Matter IO Pty Ltd — closing the loop on plastic.*
