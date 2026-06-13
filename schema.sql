-- ============================================================================
-- SmartLoop · Supabase schema
-- Matter IO Pty Ltd — schools ocean-plastic platform
-- ----------------------------------------------------------------------------
-- DESIGN PRINCIPLES (read the SETUP.md for the full rationale)
--
-- 1. DATA RESIDENCY / SOVEREIGNTY ("residency-ready, single region")
--    This single project is intended to run in ONE physical region to start
--    (recommend an APAC region — Singapore ap-southeast-1 or Sydney
--    ap-southeast-2 — to cover the AU pilot + Singapore + NZ launch markets).
--    Every school carries an explicit `data_region` and `country_code`, and a
--    `regions` registry maps each jurisdiction to the Supabase region it must
--    ultimately live in. When a market (EU, India, US/Canada) reaches the
--    threshold where its data must be stored in-jurisdiction, that region's
--    rows are migrated to a SEPARATE regional Supabase project with the SAME
--    schema, and the dashboard's region-router points that country's traffic
--    at the new endpoint. No schema rework required — only data movement.
--
-- 2. PII MINIMISATION (children's data)
--    Students are PSEUDONYMOUS. `eco_heroes` stores a handle + avatar only —
--    NO real names, emails, or dates of birth. Teachers hold the handle->student
--    mapping offline. This keeps the platform out of scope for the heaviest
--    consent/child-data obligations (GDPR-K, COPPA, India DPDP minors rules)
--    in this first build. Do NOT add name/email/dob columns to eco_heroes.
--
-- 3. RLS is ON everywhere. The demo policies below allow the public (anon key)
--    to READ aggregate/gameplay data and INSERT activity logs + bin readings,
--    which is what the in-browser dashboard needs. Tighten these with Supabase
--    Auth (teacher/admin roles) before any production rollout — see SETUP.md.
-- ============================================================================

-- Run this whole file in the Supabase SQL editor (or `supabase db push`).

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 0. REGION REGISTRY — the heart of the residency model
-- ----------------------------------------------------------------------------
create table if not exists regions (
  code              text primary key,              -- e.g. 'OCEANIA', 'APAC_SE', 'EU', 'INDIA', 'NA'
  name              text not null,
  supabase_region   text not null,                 -- physical region this jurisdiction's data must live in
  privacy_regime    text not null,                 -- governing law(s)
  residency_required boolean not null default false,-- true => data MUST be stored in-region (own project)
  status            text not null default 'planned',-- 'live' | 'planned'
  notes             text
);

comment on table regions is 'Maps a jurisdiction grouping to the physical Supabase region its data must live in. Drives the dashboard region-router and the future multi-project split.';

-- ----------------------------------------------------------------------------
-- 1. COUNTRIES — each maps to exactly one region
-- ----------------------------------------------------------------------------
create table if not exists countries (
  code         text primary key,                   -- ISO-3166 alpha-2: 'AU','NZ','SG','US','CA','IN','SE','DE'
  name         text not null,
  flag_emoji   text not null,
  region_code  text not null references regions(code),
  launch_phase int  not null default 99            -- 1 = pilot (AU), 2 = SG/NZ, 3 = US/CA/IN/EU
);

-- ----------------------------------------------------------------------------
-- 2. SCHOOLS — carry explicit residency tagging
-- ----------------------------------------------------------------------------
create table if not exists schools (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  city          text,
  country_code  text not null references countries(code),
  data_region   text not null references regions(code),  -- where this school's data must live
  timezone      text not null default 'UTC',
  is_pilot      boolean not null default false,
  partner_slug  text,                                     -- used by the "partner schools" global view
  created_at    timestamptz not null default now()
);
create index if not exists schools_country_idx on schools(country_code);
create index if not exists schools_region_idx  on schools(data_region);

-- ----------------------------------------------------------------------------
-- 3. CLASSES
-- ----------------------------------------------------------------------------
create table if not exists classes (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references schools(id) on delete cascade,
  name       text not null,                          -- '5B', '2A'
  year_level int                                     -- 3..6 (ACARA Years 3-6)
);
create index if not exists classes_school_idx on classes(school_id);

-- ----------------------------------------------------------------------------
-- 4. ECO-HEROES — PSEUDONYMOUS students. NO real PII. See design note 2.
-- ----------------------------------------------------------------------------
create table if not exists eco_heroes (
  id          uuid primary key default gen_random_uuid(),
  handle      text not null,                         -- display handle e.g. 'Rory' (chosen nickname, not legal name)
  emoji       text not null default '🌊',
  avatar_bg   text not null default 'linear-gradient(135deg,#64B5F6,#17B5B5)',
  eco_title   text not null default 'Eco Explorer',  -- 'Reef Ranger', 'Garden Guardian'
  class_id    uuid references classes(id) on delete set null,
  school_id   uuid not null references schools(id) on delete cascade,
  level       int  not null default 1,
  xp          int  not null default 0,
  xp_to_next  int  not null default 500,
  riplets     int  not null default 0,
  streak_days int  not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists heroes_school_idx on eco_heroes(school_id);
create index if not exists heroes_class_idx  on eco_heroes(class_id);
comment on table eco_heroes is 'Pseudonymous student records. Do NOT add legal name / email / DOB columns. Handle is a chosen nickname; teacher holds the handle->student map offline.';

-- ----------------------------------------------------------------------------
-- 5. ACTIVITY CATALOG + LOGS
-- ----------------------------------------------------------------------------
create table if not exists activities (
  code      text primary key,                        -- 'cup','bag','compost'...
  emoji     text not null,
  name      text not null,
  riplets   int  not null,
  xp        int  not null,
  category  text not null default 'reduce',
  -- impact coefficients let us derive trees/CO2/water/waste from a logged action
  waste_kg  numeric not null default 0,
  co2_kg    numeric not null default 0,
  water_l   numeric not null default 0
);

create table if not exists activity_logs (
  id            uuid primary key default gen_random_uuid(),
  eco_hero_id   uuid not null references eco_heroes(id) on delete cascade,
  activity_code text not null references activities(code),
  riplets_awarded int not null default 0,
  xp_awarded      int not null default 0,
  logged_at     timestamptz not null default now()
);
create index if not exists logs_hero_idx on activity_logs(eco_hero_id);
create index if not exists logs_time_idx on activity_logs(logged_at);

-- ----------------------------------------------------------------------------
-- 6. THINKLID BINS + LIVE SENSOR READINGS (realtime surface)
-- ----------------------------------------------------------------------------
create table if not exists bins (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references schools(id) on delete cascade,
  code            text not null,                     -- 'BIN-A1'
  name            text not null,                     -- 'Canteen Recycling'
  location        text,                              -- 'Canteen', 'Library'
  stream          text not null default 'recycling', -- 'landfill'|'recycling'|'compost'|'paper'
  thinklid_serial text,                              -- QR-traceable lid serial
  capacity_l      int not null default 120,
  created_at      timestamptz not null default now()
);
create index if not exists bins_school_idx on bins(school_id);

create table if not exists bin_readings (
  id          uuid primary key default gen_random_uuid(),
  bin_id      uuid not null references bins(id) on delete cascade,
  fill_pct    int  not null check (fill_pct between 0 and 100),
  weight_kg   numeric,
  recorded_at timestamptz not null default now()
);
create index if not exists readings_bin_time_idx on bin_readings(bin_id, recorded_at desc);

-- Convenience view: latest reading per bin (what the Live Bin Status cards show)
create or replace view bin_status as
select distinct on (b.id)
  b.id, b.school_id, b.code, b.name, b.location, b.stream, b.capacity_l,
  r.fill_pct, r.weight_kg, r.recorded_at
from bins b
left join bin_readings r on r.bin_id = b.id
order by b.id, r.recorded_at desc;

-- ----------------------------------------------------------------------------
-- 7. BADGES
-- ----------------------------------------------------------------------------
create table if not exists badges (
  code            text primary key,
  name            text not null,
  icon            text not null,
  points          int  not null default 0,
  threshold_label text                               -- '50 items sorted'
);
create table if not exists hero_badges (
  eco_hero_id uuid not null references eco_heroes(id) on delete cascade,
  badge_code  text not null references badges(code),
  progress    int  not null default 0,               -- 0..100 (%)
  earned_at   timestamptz,
  primary key (eco_hero_id, badge_code)
);

-- ----------------------------------------------------------------------------
-- 8. GLOBAL ECOCHALLENGE
-- ----------------------------------------------------------------------------
create table if not exists global_challenges (
  id            uuid primary key default gen_random_uuid(),
  season        text not null,                       -- 'Season 3'
  name          text not null,                       -- 'Global EcoChallenge 2026'
  goal_label    text not null,                       -- 'Plant 10,000 Trees'
  goal_value    numeric not null,
  current_value numeric not null default 0,
  ends_at       timestamptz,
  status        text not null default 'active'
);
create table if not exists country_scores (
  challenge_id uuid not null references global_challenges(id) on delete cascade,
  country_code text not null references countries(code),
  eco_points   bigint not null default 0,
  co2_kg       numeric not null default 0,
  schools_n    int not null default 0,
  students_n   int not null default 0,
  primary key (challenge_id, country_code)
);

-- ----------------------------------------------------------------------------
-- 9. CURRICULUM (ACARA-aligned 8-week program)
-- ----------------------------------------------------------------------------
create table if not exists curriculum_weeks (
  week_no  int primary key,
  title    text not null,
  theme    text not null,
  strands  text[] not null default '{}',
  status   text not null default 'upcoming'          -- 'done'|'active'|'upcoming'
);
create table if not exists curriculum_progress (
  class_id  uuid not null references classes(id) on delete cascade,
  week_no   int  not null references curriculum_weeks(week_no),
  completed boolean not null default false,
  primary key (class_id, week_no)
);

-- ----------------------------------------------------------------------------
-- 10. HERO IMPACT SUMMARY — derived metrics for the student dashboard
-- ----------------------------------------------------------------------------
create or replace view hero_impact as
select
  h.id as eco_hero_id,
  coalesce(sum(a.waste_kg),0)::numeric(10,1) as waste_kg,
  coalesce(sum(a.co2_kg),0)::numeric(10,1)   as co2_kg,
  coalesce(sum(a.water_l),0)::numeric(10,0)  as water_l,
  floor(coalesce(sum(a.co2_kg),0) / 21.0)::int as trees_saved  -- ~21kg CO2 ≈ 1 tree-year
from eco_heroes h
left join activity_logs l on l.eco_hero_id = h.id
left join activities a on a.code = l.activity_code
group by h.id;

-- School leaderboard (rank heroes within their school by xp)
create or replace view school_leaderboard as
select
  h.id as eco_hero_id, h.handle, h.emoji, h.eco_title, h.school_id,
  c.name as class_name, h.xp, h.riplets, h.level,
  rank() over (partition by h.school_id order by h.xp desc) as school_rank
from eco_heroes h
left join classes c on c.id = h.class_id;

-- ============================================================================
-- ROW LEVEL SECURITY  (demo-grade — tighten with Auth for production)
-- ============================================================================
alter table regions             enable row level security;
alter table countries           enable row level security;
alter table schools             enable row level security;
alter table classes             enable row level security;
alter table eco_heroes          enable row level security;
alter table activities          enable row level security;
alter table activity_logs       enable row level security;
alter table bins                enable row level security;
alter table bin_readings        enable row level security;
alter table badges              enable row level security;
alter table hero_badges         enable row level security;
alter table global_challenges   enable row level security;
alter table country_scores      enable row level security;
alter table curriculum_weeks    enable row level security;
alter table curriculum_progress enable row level security;

-- Public READ on reference + gameplay data (no PII is stored, by design).
do $$
declare t text;
begin
  foreach t in array array[
    'regions','countries','schools','classes','eco_heroes','activities',
    'activity_logs','bins','bin_readings','badges','hero_badges',
    'global_challenges','country_scores','curriculum_weeks','curriculum_progress'
  ] loop
    execute format(
      'create policy %I on %I for select to anon, authenticated using (true);',
      'read_'||t, t);
  end loop;
end;
$$;

-- Public INSERT on the two append-only event streams the dashboard writes to.
create policy ins_activity_logs on activity_logs
  for insert to anon, authenticated with check (true);
create policy ins_bin_readings on bin_readings
  for insert to anon, authenticated with check (true);

-- Allow the dashboard to bump a hero's running totals after logging.
create policy upd_eco_heroes on eco_heroes
  for update to anon, authenticated using (true) with check (true);

-- Realtime for live bin status
alter publication supabase_realtime add table bin_readings;

-- ============================================================================
-- SEED DATA
-- ============================================================================

insert into regions (code, name, supabase_region, privacy_regime, residency_required, status, notes) values
 ('OCEANIA','Australia & New Zealand','ap-southeast-2 (Sydney)','Australian Privacy Act 1988; NZ Privacy Act 2020', false,'live','Pilot home region. AU + NZ co-located in Sydney to start.'),
 ('APAC_SE','Singapore & SE Asia','ap-southeast-1 (Singapore)','Singapore PDPA', false,'live','Second launch market. Can share the Sydney/Singapore project initially.'),
 ('NA','United States & Canada','us-east-1','US COPPA (under-13); Canada PIPEDA / Law 25 (Quebec)', true,'planned','COPPA + provincial law => own US/CA project when launched.'),
 ('INDIA','India','ap-south-1 (Mumbai)','India DPDP Act 2023', true,'planned','DPDP data-localisation pressure => own Mumbai project.'),
 ('EU','European Union','eu-central-1 (Frankfurt)','EU GDPR (incl. Art.8 child consent)', true,'planned','GDPR => EU-resident project, no transfer outside EEA.')
on conflict (code) do nothing;

insert into countries (code, name, flag_emoji, region_code, launch_phase) values
 ('AU','Australia','🇦🇺','OCEANIA',1),
 ('NZ','New Zealand','🇳🇿','OCEANIA',2),
 ('SG','Singapore','🇸🇬','APAC_SE',2),
 ('US','United States','🇺🇸','NA',3),
 ('CA','Canada','🇨🇦','NA',3),
 ('IN','India','🇮🇳','INDIA',3),
 ('SE','Sweden','🇸🇪','EU',3),
 ('DE','Germany','🇩🇪','EU',3)
on conflict (code) do nothing;

-- Pilot school (WA) + launch-market schools + one partner per country for the global view
insert into schools (id, name, city, country_code, data_region, timezone, is_pilot, partner_slug) values
 ('11111111-1111-1111-1111-111111111111','City Beach Primary School','Perth','AU','OCEANIA','Australia/Perth', true, 'au'),
 ('22222222-2222-2222-2222-222222222222','Tampines Green Primary','Singapore','SG','APAC_SE','Asia/Singapore', false,'sg'),
 ('33333333-3333-3333-3333-333333333333','Wellington Harbour School','Wellington','NZ','OCEANIA','Pacific/Auckland', false,'nz'),
 ('44444444-4444-4444-4444-444444444444','Vancouver Inlet Elementary','Vancouver','CA','NA','America/Vancouver', false,'ca'),
 ('55555555-5555-5555-5555-555555555555','Mumbai Coastal Vidyalaya','Mumbai','IN','INDIA','Asia/Kolkata', false,'in'),
 ('66666666-6666-6666-6666-666666666666','Stockholm Skärgård Skola','Stockholm','SE','EU','Europe/Stockholm', false,'se'),
 ('77777777-7777-7777-7777-777777777777','San Diego Tide Academy','San Diego','US','NA','America/Los_Angeles', false,'us')
on conflict (id) do nothing;

insert into classes (id, school_id, name, year_level) values
 ('c1a55001-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','5B',5),
 ('c1a55001-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','2A',2),
 ('c1a55001-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','4C',4)
on conflict (id) do nothing;

-- Pseudonymous heroes (handles only). Rory/Kelly were the demo handles.
insert into eco_heroes (id, handle, emoji, avatar_bg, eco_title, class_id, school_id, level, xp, xp_to_next, riplets, streak_days) values
 ('a0000000-0000-0000-0000-000000000001','Rory','🌊','linear-gradient(135deg,#64B5F6,#17B5B5)','Reef Ranger','c1a55001-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',12,3680,4500,1240,14),
 ('a0000000-0000-0000-0000-000000000002','Kelly','🌸','linear-gradient(135deg,#B388FF,#FF7F7F)','Garden Guardian','c1a55001-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111',7,1860,2200,620,6),
 ('a0000000-0000-0000-0000-000000000003','Tane','🌿','linear-gradient(135deg,#4CAF50,#2DD4BF)','Compost Captain','c1a55001-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',11,3210,3800,990,9),
 ('a0000000-0000-0000-0000-000000000004','Mira','💧','linear-gradient(135deg,#40E0D0,#0B8A8A)','Water Watcher','c1a55001-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111',10,2890,3500,870,5),
 ('a0000000-0000-0000-0000-000000000005','Eli','⚡','linear-gradient(135deg,#FFD93D,#FF9800)','Energy Saver','c1a55001-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',9,2540,3000,710,7)
on conflict (id) do nothing;

insert into activities (code, emoji, name, riplets, xp, category, waste_kg, co2_kg, water_l) values
 ('cup','☕','Skip single-use cup',15,10,'reduce',0.02,0.05,20),
 ('bag','🛍️','Bring reusable bag',25,15,'reduce',0.01,0.03,5),
 ('compost','🥬','Compost food scraps',30,20,'compost',0.30,0.20,0),
 ('repair','🔧','Repair instead of replace',50,35,'reuse',0.50,1.20,40),
 ('bulk','🧴','Buy bulk / refill',40,25,'reduce',0.15,0.30,10),
 ('share','🤝','Share / donate item',35,22,'reuse',0.40,0.80,15)
on conflict (code) do nothing;

-- Backfill some logged history so the impact tiles & charts have data on first load.
insert into activity_logs (eco_hero_id, activity_code, riplets_awarded, xp_awarded, logged_at)
select h.id, a.code, a.riplets, a.xp, now() - (g||' hours')::interval
from eco_heroes h
cross join lateral (select code, riplets, xp from activities order by random() limit 8) a
cross join generate_series(1,8) g
where h.school_id = '11111111-1111-1111-1111-111111111111';

insert into bins (id, school_id, code, name, location, stream, thinklid_serial, capacity_l) values
 ('b0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','BIN-A1','Canteen Recycling','Canteen','recycling','TL-AU-0001',120),
 ('b0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','BIN-A2','Canteen Landfill','Canteen','landfill','TL-AU-0002',120),
 ('b0000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','BIN-B1','Library Paper','Library','paper','TL-AU-0003',80),
 ('b0000000-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','BIN-C1','Playground Compost','Playground','compost','TL-AU-0004',60),
 ('b0000000-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','BIN-C2','Oval Recycling','Oval','recycling','TL-AU-0005',120)
on conflict (id) do nothing;

-- Seed a reading per bin + a day of trend history (hourly) for the chart.
insert into bin_readings (bin_id, fill_pct, weight_kg, recorded_at)
select b.id,
       least(100, greatest(0, (20 + 70*((extract(hour from ts)::int)/23.0))::int + (random()*12-6)::int)),
       round((random()*8+1)::numeric,1),
       ts
from bins b
cross join generate_series(now() - interval '23 hours', now(), interval '1 hour') ts
where b.school_id = '11111111-1111-1111-1111-111111111111';

insert into badges (code, name, icon, points, threshold_label) values
 ('sort_star','Sorting Superstar','⚔️',150,'50 items sorted'),
 ('carbon_warrior','Carbon Warrior','🌿',200,'25 kg CO₂ saved'),
 ('forest_guardian','Forest Guardian','🌲',250,'5 trees equivalent'),
 ('waste_wizard','Waste Wizard','🧙',180,'40 kg waste rescued'),
 ('streak_master','Streak Master','🔥',120,'14 day streak')
on conflict (code) do nothing;

insert into hero_badges (eco_hero_id, badge_code, progress, earned_at) values
 ('a0000000-0000-0000-0000-000000000001','sort_star',84,null),
 ('a0000000-0000-0000-0000-000000000001','carbon_warrior',72,null),
 ('a0000000-0000-0000-0000-000000000001','forest_guardian',60,null),
 ('a0000000-0000-0000-0000-000000000001','streak_master',100,now())
on conflict do nothing;

insert into global_challenges (id, season, name, goal_label, goal_value, current_value, ends_at, status) values
 ('99999999-9999-9999-9999-999999999999','Season 3','Global EcoChallenge 2026','Plant 10,000 Trees',10000,7340, now() + interval '42 days','active')
on conflict (id) do nothing;

insert into country_scores (challenge_id, country_code, eco_points, co2_kg, schools_n, students_n) values
 ('99999999-9999-9999-9999-999999999999','SE',185840,2910,21,3680),
 ('99999999-9999-9999-9999-999999999999','AU',184600,2840,18,3200),
 ('99999999-9999-9999-9999-999999999999','SG',171200,2610,16,2950),
 ('99999999-9999-9999-9999-999999999999','NZ',142300,2180,12,2010),
 ('99999999-9999-9999-9999-999999999999','CA',138900,2090,14,2240),
 ('99999999-9999-9999-9999-999999999999','US',129400,1980,15,2480),
 ('99999999-9999-9999-9999-999999999999','IN',118700,1820,22,4100),
 ('99999999-9999-9999-9999-999999999999','DE',110500,1700,18,2900)
on conflict do nothing;

insert into curriculum_weeks (week_no, title, theme, strands, status) values
 (1,'Waste Detectives','Explore — where does our waste go?','{Science,HASS}','done'),
 (2,'The Plastic Problem','Explore — oceans & rivers','{Science,English}','done'),
 (3,'Sorting Science','Engage — materials & streams','{Science,Mathematics}','done'),
 (4,'Reuse & Repair','Engage — creative reuse & upcycling','{Technologies,Arts}','active'),
 (5,'Measuring Our Impact','Empower — data from our bins','{Mathematics,Science}','upcoming'),
 (6,'Designing Solutions','Empower — design thinking','{Technologies,Arts}','upcoming'),
 (7,'Our Campus Campaign','Execute — whole-school action','{HASS,English}','upcoming'),
 (8,'Sharing With the World','Execute — global exchange','{HASS,English}','upcoming')
on conflict (week_no) do nothing;

insert into curriculum_progress (class_id, week_no, completed)
select 'c1a55001-0000-0000-0000-000000000001', w, w <= 3
from generate_series(1,8) w
on conflict do nothing;

-- ============================================================================
-- END
-- ============================================================================
