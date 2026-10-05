-- ============================================================================
-- Programme engine — templates, slots, assignment, and the snapshot
--
-- Excerpt from a youth athletic training platform. Structure only; the
-- client's coaching content is not included.
--
-- The engine never invents a workout. It selects an approved template for the
-- athlete's band / season / level, then copies it. See README for why.
-- ============================================================================

create type age_band      as enum ('spark', 'forge', 'elite');   -- 7-11 / 12-15 / 16-18
create type season_state  as enum ('in_season', 'off_season');

-- ---------------------------------------------------------------- the library
create table exercises (
  id        bigserial primary key,
  slug      text unique not null,
  name      text not null,
  pattern   text not null,              -- squat | hinge | push | pull | ... | protocol
  equipment text not null default 'none',
  min_age   integer not null default 7, -- a floor, enforced by the chain below
  cues      text,                       -- the one thing to watch for
  video_url text,
  active    boolean not null default true
);

-- Regression chains: Box Squat -> Goblet -> Front -> Back.
-- The engine picks the link matching the athlete's LEVEL, never an exercise
-- directly, so "harder" is always a deliberate step a coach defined.
create table exercise_variants (
  exercise_id bigint not null references exercises(id) on delete cascade,
  pattern     text not null,
  band        age_band not null,
  level       integer not null check (level between 1 and 3),
  primary key (pattern, band, level)
);

-- -------------------------------------------------------------- the templates
-- 3 bands x 2 seasons x 3 levels = 18. Bounded on purpose: a finite set a
-- human can actually read and sign off.
create table program_templates (
  id          bigserial primary key,
  slug        text unique not null,
  name        text not null,
  band        age_band not null,
  season      season_state not null,
  level       integer not null check (level between 1 and 3),
  week_count  integer not null default 12,
  approved_by text,                        -- a person, not a process
  approved_at timestamptz,
  active      boolean not null default false,   -- nothing is live until signed off
  unique (band, season, level)
);

create table template_slots (
  id          bigserial primary key,
  template_id bigint not null references program_templates(id) on delete cascade,
  week        integer not null,
  day         integer not null,
  slot_order  integer not null,
  tag         text default '',          -- 'A', 'B1', 'C2' — superset lettering
  exercise_id bigint references exercises(id),  -- pinned, or
  pattern     text,                             -- resolved through the chain
  sets        integer,                  -- null for protocols (warm-ups etc.)
  reps        text,                     -- TEXT: '10', '8 e/s', '30s', '20m', '4:00'
  unique (template_id, week, day, slot_order)
);

-- ------------------------------------------------------------- season by sport
-- Hockey, baseball and basketball do not share a calendar, so "in season"
-- is computed per sport, with a parent override for kids on select teams.
create table sport_seasons (
  sport        text primary key,
  start_month  integer not null,
  end_month    integer not null
);

create or replace function current_season(a athlete_profiles)
returns season_state language plpgsql stable as $$
declare s sport_seasons; m integer := extract(month from current_date);
begin
  if a.season_override is not null then return a.season_override; end if;
  select * into s from sport_seasons where sport = a.sport;
  if not found then return 'off_season'; end if;
  if s.start_month <= s.end_month then
    return case when m between s.start_month and s.end_month
                then 'in_season' else 'off_season' end::season_state;
  else  -- season wraps the new year, e.g. hockey Sep-Mar
    return case when m >= s.start_month or m <= s.end_month
                then 'in_season' else 'off_season' end::season_state;
  end if;
end; $$;

-- ------------------------------------------------------------- the assignment
create table assigned_programs (
  id             bigserial primary key,
  athlete_id     bigint not null references athlete_profiles(id) on delete cascade,
  user_id        uuid not null default auth.uid(),
  template_id    bigint not null references program_templates(id),
  level_at_start integer not null,
  current_week   integer not null default 1,
  started_at     timestamptz not null default now(),
  completed_at   timestamptz
);

-- THE SNAPSHOT.
-- exercise_name is COPIED, not joined. Editing a template cannot rewrite a
-- programme an athlete is already partway through. exercise_id is kept only
-- so the video can be looked up later.
create table assigned_workouts (
  id                  bigserial primary key,
  assigned_program_id bigint not null references assigned_programs(id) on delete cascade,
  user_id             uuid not null default auth.uid(),
  week                integer not null,
  day                 integer not null,
  slot_order          integer not null,
  tag                 text default '',
  exercise_id         bigint references exercises(id),
  exercise_name       text not null,
  sets                integer,
  reps                text,
  unique (assigned_program_id, week, day, slot_order)
);

-- Assign: pick the template, resolve every slot, freeze it.
-- Raises rather than guessing if no APPROVED template matches — an athlete
-- with no programme is a support ticket; an athlete with the wrong programme
-- is an injury.
create or replace function assign_program(p_athlete_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare a athlete_profiles; t bigint; new_ap bigint;
begin
  select * into a from athlete_profiles where id = p_athlete_id;
  if not found then raise exception 'no athlete %', p_athlete_id; end if;

  select id into t from program_templates
   where band = a.band and season = current_season(a)
     and level = a.level and active limit 1;
  if t is null then
    raise exception 'no approved template for band=% season=% level=%',
      a.band, current_season(a), a.level;
  end if;

  insert into assigned_programs (athlete_id, user_id, template_id, level_at_start)
  values (p_athlete_id, a.parent_user_id, t, a.level)
  returning id into new_ap;

  insert into assigned_workouts
    (assigned_program_id, user_id, week, day, slot_order, tag,
     exercise_id, exercise_name, sets, reps)
  select new_ap, a.parent_user_id, r.week, r.day, r.slot_order, r.tag,
         r.exercise_id, r.exercise_name, r.sets, r.reps
  from resolve_slots(t, a.band, a.level) r;

  return new_ap;
end; $$;

-- Progression parses the SHAPE of a rep string rather than assuming a number.
--   '10'      -> '12'          plain reps climb
--   '8 e/s'   -> '10 e/s'      per-side reps climb, suffix preserved
--   '20s'     -> '30s'         holds grow 5s a step, capped at 60s
--   '20m', '4:00'              distances and clock times never change
create or replace function progress_reps(p_reps text, p_add int)
returns text language plpgsql immutable as $$
declare n int;
begin
  if p_add = 0 or p_reps is null then return p_reps; end if;
  if p_reps ~ '^\d+$'       then return (p_reps::int + p_add)::text; end if;
  if p_reps ~ '^\d+ e/s$'   then
    n := (regexp_match(p_reps, '^(\d+)'))[1]::int;
    return (n + p_add)::text || ' e/s';
  end if;
  if p_reps ~ '^\d+s$'      then
    n := (regexp_match(p_reps, '^(\d+)'))[1]::int;
    return least(n + p_add * 5, 60)::text || 's';
  end if;
  return p_reps;   -- distances, times, anything unrecognised: leave it alone
end; $$;
