-- ============================================================================
-- Row-level security, definer views, and turning a signup into an athlete
--
-- Excerpt from a youth athletic training platform.
--
-- Principle: the account belongs to the PARENT. A child is a row, never a user.
-- ============================================================================

create table athlete_profiles (
  id             bigserial primary key,
  parent_user_id uuid not null references auth.users(id) on delete cascade,
  first_name     text not null,        -- first name only; no surname is stored
  birth_year     integer not null,     -- YEAR, not a date of birth
  sport          text not null default 'other',
  band           age_band not null,
  level          integer not null default 1,

  -- Consent is two separate permissions, never bundled. Media consent is
  -- optional and withdrawable; participation is required.
  consent_participation_at timestamptz,
  consent_media_at         timestamptz,

  -- Which version of the waiver, agreed when. For a minors product this IS
  -- the evidence, and it cannot be reconstructed after the fact.
  consent_waiver_version   text,
  consent_agreed_at        timestamptz
);

alter table athlete_profiles enable row level security;

create policy athlete_own on athlete_profiles
  for all using (auth.uid() = parent_user_id)
       with check (auth.uid() = parent_user_id);

-- Entitlements are SELECT-only to the user. Nobody grants themselves access;
-- writes come from the payment webhook running as service_role.
alter table entitlements enable row level security;
create policy entitlement_read on entitlements
  for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- The bug worth keeping: this view used to be security_invoker.
--
-- The join to `exercises` then ran as the athlete, who has no policy on that
-- table. A LEFT JOIN against rows you cannot see does not error — it returns
-- NULL. Every coaching cue and every video URL came back empty, silently.
--
-- Definer, still pinned to auth.uid(): the filter does the security, the join
-- is allowed to complete.
-- ---------------------------------------------------------------------------
create or replace view my_workouts with (security_invoker = false) as
select
  aw.assigned_program_id, ap.athlete_id,
  aw.week, aw.day, aw.slot_order, aw.tag,
  aw.exercise_name as exercise,
  e.cues, e.video_url,
  aw.sets, aw.reps
from assigned_workouts aw
join assigned_programs ap on ap.id = aw.assigned_program_id
left join exercises e     on e.id = aw.exercise_id
where aw.user_id = auth.uid()
  and ap.completed_at is null
order by aw.week, aw.day, aw.slot_order;

grant select on my_workouts to authenticated;

-- ---------------------------------------------------------------------------
-- Turning a confirmed signup into an athlete.
--
-- The signup data rides in the user's own auth metadata, which the user can
-- edit. So this trusts none of it: band is derived from birth year here,
-- level is clamped, and anyone outside 7-18 is refused. Idempotent, because a
-- refresh mid-request must not produce two children on one account.
-- ---------------------------------------------------------------------------
create or replace function claim_signup(
  p_first_name text, p_birth_year integer, p_sport text, p_level integer,
  p_consent_participation boolean, p_consent_media boolean,
  p_waiver_version text default null, p_agreed_at timestamptz default null)
returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); existing athlete_profiles;
        age integer; b age_band; lvl integer; aid bigint;
begin
  if uid is null then raise exception 'not signed in'; end if;

  select * into existing from athlete_profiles
   where parent_user_id = uid order by id limit 1;
  if found then
    return json_build_object('status','already','athlete_id',existing.id);
  end if;

  if p_consent_participation is not true then
    raise exception 'participation consent is required';
  end if;

  age := extract(year from current_date)::int - p_birth_year;
  if age < 7 or age > 18 then
    raise exception 'ages 7 to 18 only (got %)', age;
  end if;

  b := case when age between 7  and 11 then 'spark'
            when age between 12 and 15 then 'forge'
            else 'elite' end::age_band;

  lvl := least(greatest(coalesce(p_level, 1), 1), 3);

  insert into athlete_profiles
    (parent_user_id, first_name, birth_year, sport, band, level,
     consent_participation_at, consent_media_at,
     consent_waiver_version, consent_agreed_at)
  values
    (uid, btrim(p_first_name), p_birth_year,
     coalesce(nullif(btrim(p_sport),''),'other'), b, lvl,
     now(),
     case when p_consent_media then now() else null end,
     p_waiver_version, coalesce(p_agreed_at, now()))
  returning id into aid;

  -- Assignment is allowed to fail without losing the athlete: if no approved
  -- template matches yet, the family still has an account and a human can
  -- sort the programme out. Throwing here would leave them with nothing.
  begin
    perform assign_program(aid);
  exception when others then
    return json_build_object('status','profile_only','athlete_id',aid,
                             'error',sqlerrm);
  end;

  return json_build_object('status','created','athlete_id',aid,
                           'band',b,'level',lvl);
end; $$;

revoke all on function claim_signup(text,integer,text,integer,boolean,boolean,text,timestamptz) from public;
grant execute on function claim_signup(text,integer,text,integer,boolean,boolean,text,timestamptz) to authenticated;
