# Youth Training Platform — architecture notes

A multi-tenant strength and conditioning platform for athletes aged 7–18. Parents hold the
account, children never do. This repository documents the design decisions and the database
patterns behind it, with the schema excerpts that carry them.

It is a write-up, not the deployed application — the client's production code and their
coaching content stay private. Everything here is structure and reasoning.

**Stack** — PostgreSQL (Supabase) · Next.js · Vercel · PWA

---

## The problem

Prescribing exercise to children, unsupervised, over the internet. Three constraints shaped
everything:

1. **A nine-year-old and a seventeen-year-old need different programmes**, and so do an
   in-season hockey player and an off-season one.
2. **Nobody is watching.** No coach can correct form in the moment, so whatever the app says
   has to be right before it is shown.
3. **The user is a minor.** In Ontario a parent cannot waive a child's own right to sue, and
   the limitation clock does not start until the child turns eighteen. A seven-year-old today
   could bring a claim in 2039. That changes what you store and for how long.

---

## Decision 1 — select templates, don't generate workouts

The obvious design is to have software compose a workout from an exercise library each week.
I decided against it.

Generating exercise prescriptions for children means no qualified human has seen what a child
is being told to do, and there is no answer to *"who decided my kid should do that?"* The
engine therefore does exactly two things: **select** an approved template, and **substitute**
the right regression of each movement for the athlete's level.

- Every movement shown to a child was written by a qualified coach
- Both operations are deterministic and reviewable — no black box
- The set is bounded: 3 age bands × 2 seasons × 3 levels = 18 templates

The cost is flexibility. The benefit is that every prescription traces to a named human who
approved it, which is the only version of this I was willing to ship.

```sql
-- Templates carry an approver and are inactive until signed off.
create table program_templates (
  id          bigserial primary key,
  slug        text unique not null,
  band        age_band not null,        -- spark 7-11 | forge 12-15 | elite 16-18
  season      season_state not null,    -- in_season | off_season
  level       integer not null,         -- 1-3, experience not age
  week_count  integer not null default 12,
  approved_by text,
  approved_at timestamptz,
  active      boolean not null default false
);
```

---

## Decision 2 — freeze the prescription at assignment

A template is a living document. Coaches revise them. But an athlete who is seven weeks into
a twelve-week block should not have week eight quietly change underneath them because someone
fixed a typo in the source.

So assignment **copies** rather than joins. `assigned_workouts` stores the exercise name, sets
and reps as they were the day the athlete started. The template can be edited freely; nobody
mid-block is affected. Pushing a correction to a live athlete is a separate, deliberate call
that rebuilds only from their current week forward and leaves completed weeks untouched.

```sql
create table assigned_workouts (
  id                  bigserial primary key,
  assigned_program_id bigint not null references assigned_programs(id) on delete cascade,
  user_id             uuid not null default auth.uid(),
  week                integer not null,
  day                 integer not null,
  slot_order          integer not null,
  exercise_id         bigint references exercises(id),  -- for video lookup only
  exercise_name       text not null,                    -- COPIED, not joined
  sets                integer,
  reps                text,
  unique (assigned_program_id, week, day, slot_order)
);
```

`reps` is `text`, not `integer`. Real programmes say `8 e/s`, `30s`, `20m`, `4:00`. Forcing
that into a number loses the meaning, so progression logic parses the shape instead:

```sql
-- '10' -> '12' · '8 e/s' -> '10 e/s' · '20s' -> '30s' capped at 60s
-- distances and clock times are left alone: 20m does not become 22m
```

---

## Decision 3 — the account belongs to the parent

There is no child login. `athlete_profiles.parent_user_id` points at the authenticated adult,
and row-level security keys off it. A child is a row, never a user.

```sql
alter table athlete_profiles enable row level security;

create policy athlete_own on athlete_profiles
  for all using (auth.uid() = parent_user_id)
       with check (auth.uid() = parent_user_id);
```

Signup data arrives in the user's own auth metadata, which the user can edit. So the function
that turns a signup into an athlete trusts none of it — it derives the age band from birth
year server-side, clamps the level, and refuses anyone outside 7–18:

```sql
create or replace function claim_signup(...)
returns json language plpgsql security definer set search_path = public as $$
begin
  -- idempotent: a refresh mid-request must not create two children
  select * into existing from athlete_profiles where parent_user_id = auth.uid() limit 1;
  if found then return json_build_object('status','already','athlete_id',existing.id); end if;

  age := extract(year from current_date)::int - p_birth_year;
  if age < 7 or age > 18 then
    raise exception 'ages 7 to 18 only (got %)', age;
  end if;

  band := case when age between 7 and 11 then 'spark'
               when age between 12 and 15 then 'forge'
               else 'elite' end::age_band;
  ...
end; $$;
```

The client can lie. The function does not listen.

---

## A bug worth writing down

Coaching cues and video URLs silently returned `NULL` for every exercise, on every row.

The view joining workouts to the exercise library was declared `security_invoker`, so the join
ran as the athlete — who has no RLS policy on that table. A `LEFT JOIN` against rows you
cannot see does not error. It returns nulls.

The fix was a definer view still pinned to `auth.uid()`:

```sql
create view my_workouts with (security_invoker = false) as
select aw.week, aw.day, aw.exercise_name, e.cues, e.video_url, aw.sets, aw.reps
from assigned_workouts aw
join assigned_programs ap on ap.id = aw.assigned_program_id
left join exercises e on e.id = aw.exercise_id
where aw.user_id = auth.uid()          -- the filter stays
  and ap.completed_at is null;
```

The lesson I took: **`security_invoker` turns a permissions problem into a data problem.**
A blocked read errors and you find it in a minute. A silently empty join ships.

A related one cost me 15% of the dataset. Loading programme content by joining on exercise
*name*, the source document used an em dash (`Warm-Up — Youth`) where the library had a
hyphen. An inner join dropped every warm-up, stretch and cool-down without a word. Caught it
because a row count came back 120 instead of 144. Now I verify counts after every bulk load.

---

## Also built

- **Installable PWA** — service worker, network-first for HTML so a deploy is never masked by
  cache, cache-first for assets, offline fallback. Gyms have no signal.
- **Auth and email** — confirmation and reset flows, custom SMTP, SPF/DKIM/DMARC on a custom
  domain.
- **Protocol expansion** — warm-ups and cool-downs were single rows reading "Dynamic Warm-Up",
  which is unfollowable for a nine-year-old. They became 29 protocols of 159 ordered steps,
  each with its own dose, coaching cue and video slot, resolved by band and level.

## Files

| | |
|---|---|
| [`schema/programme-engine.sql`](schema/programme-engine.sql) | Templates, slots, assignment and the snapshot |
| [`schema/rls-and-access.sql`](schema/rls-and-access.sql) | Row-level security, definer views, `claim_signup` |

---

Built by [Josh Duchesne](https://github.com/JD31998) · joshduchesne@outlook.com
