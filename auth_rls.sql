-- ============================================================================
-- SmartLoop · Auth-gated RLS layer
-- Run this AFTER schema.sql. It replaces the demo-grade open policies with
-- role-based, school-scoped policies backed by Supabase Auth.
--
-- ROLES (stored on public.profiles.role):
--   teacher       — read + log activity for their OWN school
--   school_admin  — teacher rights + manage bins/devices/heroes for their school
--   super_admin   — full access across all schools (Matter IO staff)
--
-- WHAT STAYS PUBLIC (anon-readable): non-personal reference + aggregate data
--   regions, countries, activities, badges, curriculum_weeks,
--   global_challenges, country_scores
-- WHAT BECOMES PRIVATE (auth + school scope): everything with student or
--   campus data — schools, classes, eco_heroes, activity_logs, bins,
--   bin_readings, hero_badges, curriculum_progress, devices
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. PROFILES — links a Supabase Auth user to a school + role
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  role       text not null default 'teacher'
             check (role in ('teacher','school_admin','super_admin')),
  school_id  uuid references public.schools(id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.profiles is
  'Staff/teacher accounts. role + school_id drive all RLS. Students remain pseudonymous in eco_heroes and never get auth accounts.';

alter table public.profiles enable row level security;

-- ----------------------------------------------------------------------------
-- 2. HELPER FUNCTIONS (SECURITY DEFINER => read profiles without RLS recursion)
-- ----------------------------------------------------------------------------
create or replace function public.current_role_name() returns text
  language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.current_school_id() returns uuid
  language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_super() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'super_admin' from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_admin_of(p_school uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select public.is_super()
      or coalesce((select role in ('school_admin') and school_id = p_school
                   from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.can_access_school(p_school uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select public.is_super()
      or coalesce((select school_id = p_school from public.profiles where id = auth.uid()), false);
$$;

-- ----------------------------------------------------------------------------
-- 3. AUTO-CREATE A PROFILE ON SIGNUP (school assigned later by an admin)
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, 'teacher')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 4. PROFILES POLICIES
-- ----------------------------------------------------------------------------
drop policy if exists profiles_self_read   on public.profiles;
drop policy if exists profiles_self_update on public.profiles;
drop policy if exists profiles_admin_all   on public.profiles;

create policy profiles_self_read on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_super());
create policy profiles_self_update on public.profiles  -- may edit own name, NOT own role/school
  for update to authenticated using (id = auth.uid())
  with check (id = auth.uid() and role = public.current_role_name() and school_id is not distinct from public.current_school_id());
create policy profiles_admin_all on public.profiles
  for all to authenticated using (public.is_super()) with check (public.is_super());

-- ============================================================================
-- 5. DROP the demo-grade open policies from schema.sql
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'regions','countries','schools','classes','eco_heroes','activities',
    'activity_logs','bins','bin_readings','badges','hero_badges',
    'global_challenges','country_scores','curriculum_weeks','curriculum_progress'
  ] loop
    execute format('drop policy if exists %I on %I;', 'read_'||t, t);
  end loop;
end;
$$;
drop policy if exists ins_activity_logs on activity_logs;
drop policy if exists ins_bin_readings  on bin_readings;
drop policy if exists upd_eco_heroes    on eco_heroes;

-- ============================================================================
-- 6. PUBLIC reference + aggregate data (anon + authenticated may READ)
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'regions','countries','activities','badges','curriculum_weeks',
    'global_challenges','country_scores'
  ] loop
    execute format('create policy %I on %I for select to anon, authenticated using (true);', 'pub_read_'||t, t);
  end loop;
end;
$$;

-- ============================================================================
-- 7. PRIVATE, SCHOOL-SCOPED data (authenticated only)
-- ============================================================================

-- schools: read your own; super sees all. Admin may update own school row.
create policy schools_read on schools for select to authenticated
  using (public.can_access_school(id));
create policy schools_admin_write on schools for update to authenticated
  using (public.is_admin_of(id)) with check (public.is_admin_of(id));

-- classes
create policy classes_read on classes for select to authenticated
  using (public.can_access_school(school_id));
create policy classes_admin_write on classes for all to authenticated
  using (public.is_admin_of(school_id)) with check (public.is_admin_of(school_id));

-- eco_heroes (pseudonymous): read + update for own school; admin may insert/delete
create policy heroes_read on eco_heroes for select to authenticated
  using (public.can_access_school(school_id));
create policy heroes_update on eco_heroes for update to authenticated
  using (public.can_access_school(school_id)) with check (public.can_access_school(school_id));
create policy heroes_admin_write on eco_heroes for all to authenticated
  using (public.is_admin_of(school_id)) with check (public.is_admin_of(school_id));

-- activity_logs: scope via the hero's school. Teachers may read + insert.
create policy logs_read on activity_logs for select to authenticated
  using (exists (select 1 from eco_heroes h
                 where h.id = activity_logs.eco_hero_id
                   and public.can_access_school(h.school_id)));
create policy logs_insert on activity_logs for insert to authenticated
  with check (exists (select 1 from eco_heroes h
                      where h.id = activity_logs.eco_hero_id
                        and public.can_access_school(h.school_id)));

-- bins: read for own school; admin manages
create policy bins_read on bins for select to authenticated
  using (public.can_access_school(school_id));
create policy bins_admin_write on bins for all to authenticated
  using (public.is_admin_of(school_id)) with check (public.is_admin_of(school_id));

-- bin_readings: READ scoped via the bin's school. NO insert policy here on
-- purpose — sensor readings are written ONLY by the ingestion Edge Function
-- using the service_role key, which bypasses RLS. (Realtime SELECT still
-- respects these policies, so a teacher only streams their own school's bins.)
create policy readings_read on bin_readings for select to authenticated
  using (exists (select 1 from bins b
                 where b.id = bin_readings.bin_id
                   and public.can_access_school(b.school_id)));

-- hero_badges: scope via the hero's school
create policy hbadges_read on hero_badges for select to authenticated
  using (exists (select 1 from eco_heroes h
                 where h.id = hero_badges.eco_hero_id
                   and public.can_access_school(h.school_id)));
create policy hadges_admin_write on hero_badges for all to authenticated
  using (exists (select 1 from eco_heroes h
                 where h.id = hero_badges.eco_hero_id and public.is_admin_of(h.school_id)))
  with check (exists (select 1 from eco_heroes h
                 where h.id = hero_badges.eco_hero_id and public.is_admin_of(h.school_id)));

-- curriculum_progress: scope via the class's school
create policy currprog_read on curriculum_progress for select to authenticated
  using (exists (select 1 from classes c
                 where c.id = curriculum_progress.class_id
                   and public.can_access_school(c.school_id)));
create policy currprog_write on curriculum_progress for all to authenticated
  using (exists (select 1 from classes c
                 where c.id = curriculum_progress.class_id
                   and public.can_access_school(c.school_id)))
  with check (exists (select 1 from classes c
                 where c.id = curriculum_progress.class_id
                   and public.can_access_school(c.school_id)));

-- ============================================================================
-- 8. DEVICE REGISTRY (ThinkLid lids) + key issuance
-- ============================================================================
create table if not exists public.devices (
  id              uuid primary key default gen_random_uuid(),
  thinklid_serial text unique not null,
  bin_id          uuid references public.bins(id) on delete set null,
  school_id       uuid references public.schools(id) on delete cascade,
  api_key_hash    text not null,                  -- sha256 hex of the device key (plaintext never stored)
  is_active       boolean not null default true,
  last_seen_at    timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists devices_keyhash_idx on public.devices(api_key_hash);
alter table public.devices enable row level security;

-- Only admins of the device's school (or super) may VIEW device rows.
-- The api_key_hash is non-reversible; the plaintext key is shown once at issue.
create policy devices_read on public.devices for select to authenticated
  using (public.is_admin_of(school_id));
create policy devices_admin_write on public.devices for all to authenticated
  using (public.is_admin_of(school_id)) with check (public.is_admin_of(school_id));

-- Issue (or rotate) a device key. Returns the PLAINTEXT key ONCE — store it on
-- the lid/gateway now; only its hash is persisted. Call via RPC as an admin.
create or replace function public.register_thinklid(
  p_serial text, p_bin uuid, p_school uuid
) returns text
  language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if not public.is_admin_of(p_school) then
    raise exception 'not authorized to register devices for this school';
  end if;
  k := encode(gen_random_bytes(24), 'hex');           -- 48-char secret
  insert into public.devices (thinklid_serial, bin_id, school_id, api_key_hash)
  values (p_serial, p_bin, p_school, encode(digest(k, 'sha256'), 'hex'))
  on conflict (thinklid_serial) do update
     set bin_id = excluded.bin_id,
         school_id = excluded.school_id,
         api_key_hash = excluded.api_key_hash,
         is_active = true;
  return k;
end;
$$;
revoke all on function public.register_thinklid(text, uuid, uuid) from anon;

-- ============================================================================
-- 9. (Optional) make an existing user a super_admin / assign a school
--    Run these manually once after creating users in the Supabase Auth UI.
-- ----------------------------------------------------------------------------
-- update public.profiles set role='super_admin'
--   where email='len@matter.city';
-- update public.profiles set role='school_admin',
--   school_id='11111111-1111-1111-1111-111111111111'
--   where email='teacher@citybeachps.wa.edu.au';
-- ============================================================================
