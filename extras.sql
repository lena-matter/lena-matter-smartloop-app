-- ============================================================================
-- SmartLoop · extras.sql
-- Adds the remaining gameplay surfaces ported into the dashboard:
--   Rewards Shop, Riplet Clubs, School Exchange, and the Recycling Game
--   write-back path.
-- Run AFTER schema.sql. (If you've also run auth_rls.sql, run the clearly
-- marked "AUTH-SCOPED" block at the bottom afterwards to lock these down.)
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. REWARDS SHOP
-- ----------------------------------------------------------------------------
create table if not exists rewards (
  code  text primary key,
  kind  text not null check (kind in ('real','virtual')),
  emoji text not null,
  name  text not null,
  descr text,
  cost  int  not null
);
create table if not exists reward_redemptions (
  id          uuid primary key default gen_random_uuid(),
  eco_hero_id uuid not null references eco_heroes(id) on delete cascade,
  reward_code text not null references rewards(code),
  redeemed_at timestamptz not null default now()
);
create index if not exists redemptions_hero_idx on reward_redemptions(eco_hero_id);

-- ----------------------------------------------------------------------------
-- 2. RIPLET CLUBS
-- ----------------------------------------------------------------------------
create table if not exists clubs (
  code   text primary key,
  emoji  text not null,
  name   text not null,
  price  int  not null default 0,
  perk   text,
  bg     text,
  border text
);
create table if not exists hero_clubs (
  eco_hero_id uuid not null references eco_heroes(id) on delete cascade,
  club_code   text not null references clubs(code),
  joined_at   timestamptz not null default now(),
  primary key (eco_hero_id, club_code)
);

-- ----------------------------------------------------------------------------
-- 3. SCHOOL EXCHANGE  (school-level, NON-personal — keeps the residency model
--    intact: no student PII crosses borders, only school-authored notes)
-- ----------------------------------------------------------------------------
create table if not exists exchange_messages (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references schools(id) on delete cascade,
  partner_country text references countries(code),
  author          text not null,           -- a class or school alias, not a student's legal name
  body            text not null,
  created_at      timestamptz not null default now()
);
create index if not exists exch_school_idx on exchange_messages(school_id);

create table if not exists cultural_quests (
  code         text primary key,
  country_code text references countries(code),
  emoji        text not null,
  title        text not null,
  descr        text
);
create table if not exists class_quest_progress (
  class_id   uuid not null references classes(id) on delete cascade,
  quest_code text not null references cultural_quests(code),
  done       boolean not null default false,
  primary key (class_id, quest_code)
);

-- ----------------------------------------------------------------------------
-- 4. RECYCLING GAME write-back
--    Game winnings are logged as activity_logs rows with code 'game'
--    (zero impact coefficients, so they add Riplets/XP but no fake CO2/waste).
-- ----------------------------------------------------------------------------
insert into activities (code, emoji, name, riplets, xp, category, waste_kg, co2_kg, water_l)
values ('game','🎮','Recycling Game — Sort It Out!',0,0,'play',0,0,0)
on conflict (code) do nothing;

-- ============================================================================
-- RLS — demo-grade (matches schema.sql baseline; anon may read + write).
-- ============================================================================
alter table rewards              enable row level security;
alter table reward_redemptions   enable row level security;
alter table clubs                enable row level security;
alter table hero_clubs           enable row level security;
alter table exchange_messages    enable row level security;
alter table cultural_quests      enable row level security;
alter table class_quest_progress enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'rewards','reward_redemptions','clubs','hero_clubs',
    'exchange_messages','cultural_quests','class_quest_progress'
  ] loop
    execute format('drop policy if exists %I on %I;', 'read_'||t, t);
    execute format('create policy %I on %I for select to anon, authenticated using (true);', 'read_'||t, t);
  end loop;
end;
$$;
create policy ins_redemptions on reward_redemptions   for insert to anon, authenticated with check (true);
create policy ins_heroclubs   on hero_clubs           for insert to anon, authenticated with check (true);
create policy del_heroclubs   on hero_clubs           for delete to anon, authenticated using (true);
create policy ins_exchange    on exchange_messages    for insert to anon, authenticated with check (true);
create policy upd_quest       on class_quest_progress for all    to anon, authenticated using (true) with check (true);

-- ============================================================================
-- SEED
-- ============================================================================
insert into rewards (code, kind, emoji, name, descr, cost) values
 ('bottle','real','🧴','Bamboo Water Bottle','Eco-friendly hydration',500),
 ('voucher','real','🏷️','Eco Store Voucher','$10 store credit',750),
 ('tree','real','🌳','Tree Planting Credit','Plant a real tree!',300),
 ('wraps','real','🍱','Reusable Food Wraps','Beeswax wrap set',400),
 ('course','real','📚','Sustainability Course','Online learning access',600),
 ('avatar','virtual','🎨','Avatar: Ocean Explorer','Exclusive character skin',150),
 ('frame','virtual','✨','Animated Badge Frame','Sparkle effect for badges',200),
 ('garden','virtual','🏡','Garden Expansion','Unlock tropical zone',350),
 ('sounds','virtual','🎵','Nature Sounds Pack','Rainforest & ocean sounds',100)
on conflict (code) do nothing;

insert into clubs (code, emoji, name, price, perk, bg, border) values
 ('zero','🏆','Zero Waste Champions',50,'2x Riplets on weekends','linear-gradient(135deg,#E0FAF5,#B2F5EA)','#40E0D0'),
 ('plastic','🚫','Plastic-Free Pioneers',75,'Exclusive challenges + 15% store discount','linear-gradient(135deg,#DCEEFB,#EDE0FF)','#64B5F6'),
 ('upcycle','♻️','Upcycling Masters',40,'DIY tutorials + community marketplace','linear-gradient(135deg,#D5F0D5,#FFF4C8)','#4CAF50')
on conflict (code) do nothing;

insert into exchange_messages (school_id, partner_country, author, body) values
 ('11111111-1111-1111-1111-111111111111','SG','Class 5B','Kia ora from Perth! We diverted 48kg this week — how is Tampines Green going? 🌊'),
 ('11111111-1111-1111-1111-111111111111','NZ','Eco Club','Loved your harbour clean-up photos. We are trying the same at City Beach! 🐚'),
 ('11111111-1111-1111-1111-111111111111','SE','Class 4C','Your compost system is amazing. Sharing our worm-farm tips back 🪱')
on conflict do nothing;

insert into cultural_quests (code, country_code, emoji, title, descr) values
 ('sg_hawker','SG','🥡','Hawker Zero-Waste','Learn how Singapore hawker centres cut single-use plastic.'),
 ('nz_kaitiaki','NZ','🌿','Kaitiakitanga','Explore the Māori principle of guardianship of nature.'),
 ('se_pant','SE','♻️','Pant Deposit Return','How Sweden recycles ~85% of bottles via deposit return.'),
 ('in_ragpicker','IN','🤝','Waste-Picker Heroes','Recognise India''s informal recyclers and their impact.'),
 ('ca_terracycle','CA','📦','Hard-to-Recycle Drive','Run a TerraCycle-style collection for tricky items.')
on conflict (code) do nothing;

-- ============================================================================
-- ▼▼▼  AUTH-SCOPED POLICIES — run ONLY if you have applied auth_rls.sql  ▼▼▼
-- Removes the demo-open policies above and scopes these tables by school/role.
-- (Catalogs rewards/clubs/cultural_quests stay public-readable — non-personal.)
-- ----------------------------------------------------------------------------
-- do $$
-- declare t text;
-- begin
--   foreach t in array array['rewards','reward_redemptions','clubs','hero_clubs',
--     'exchange_messages','cultural_quests','class_quest_progress'] loop
--     execute format('drop policy if exists %I on %I;', 'read_'||t, t);
--   end loop;
-- end$$;
-- drop policy if exists ins_redemptions on reward_redemptions;
-- drop policy if exists ins_heroclubs   on hero_clubs;
-- drop policy if exists del_heroclubs   on hero_clubs;
-- drop policy if exists ins_exchange    on exchange_messages;
-- drop policy if exists upd_quest       on class_quest_progress;
--
-- -- public catalogs
-- create policy pub_rewards on rewards          for select to anon, authenticated using (true);
-- create policy pub_clubs   on clubs            for select to anon, authenticated using (true);
-- create policy pub_quests  on cultural_quests  for select to anon, authenticated using (true);
--
-- -- redemptions scoped via the hero's school
-- create policy red_read on reward_redemptions for select to authenticated
--   using (exists (select 1 from eco_heroes h where h.id=reward_redemptions.eco_hero_id and public.can_access_school(h.school_id)));
-- create policy red_ins on reward_redemptions for insert to authenticated
--   with check (exists (select 1 from eco_heroes h where h.id=reward_redemptions.eco_hero_id and public.can_access_school(h.school_id)));
--
-- -- hero_clubs scoped via the hero's school
-- create policy hc_read on hero_clubs for select to authenticated
--   using (exists (select 1 from eco_heroes h where h.id=hero_clubs.eco_hero_id and public.can_access_school(h.school_id)));
-- create policy hc_write on hero_clubs for all to authenticated
--   using (exists (select 1 from eco_heroes h where h.id=hero_clubs.eco_hero_id and public.can_access_school(h.school_id)))
--   with check (exists (select 1 from eco_heroes h where h.id=hero_clubs.eco_hero_id and public.can_access_school(h.school_id)));
--
-- -- exchange messages scoped by the owning school
-- create policy exch_read on exchange_messages for select to authenticated
--   using (public.can_access_school(school_id));
-- create policy exch_write on exchange_messages for insert to authenticated
--   with check (public.can_access_school(school_id));
--
-- -- quest progress scoped via the class's school
-- create policy qp_read on class_quest_progress for select to authenticated
--   using (exists (select 1 from classes c where c.id=class_quest_progress.class_id and public.can_access_school(c.school_id)));
-- create policy qp_write on class_quest_progress for all to authenticated
--   using (exists (select 1 from classes c where c.id=class_quest_progress.class_id and public.can_access_school(c.school_id)))
--   with check (exists (select 1 from classes c where c.id=class_quest_progress.class_id and public.can_access_school(c.school_id)));
-- ============================================================================
