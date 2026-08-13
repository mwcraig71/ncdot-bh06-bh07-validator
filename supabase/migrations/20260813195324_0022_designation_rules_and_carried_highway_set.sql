-- ============================================================================
-- The numbering rules, and the population they apply to
--
-- Two separate corrections live here.
--
-- 1. Which structures carry a highway. The ingest asked SERVICEON = '1' and
--    got 17,159 of 23,022. Measured against the whole layer, the codes that
--    mean a highway is carried are 1, 4, 5, 6, 7 and 8 - and they select
--    19,741. The 2,582 in the gap are 1,286 highway-with-pedestrian, 1,282
--    overpasses at an interchange, 12 third-level structures, one
--    highway-railroad and one fourth-level. Bridge 590819 - I-85 over I-485,
--    coded 6 - is one of them, and it had no feature at all, so its BH06 and
--    BH07 were never under test. An interchange overpass is the most
--    highway-carrying structure there is.
--
-- 2. How features are numbered. Carried features first, then the primary below
--    feature, then the remaining below features. The designation is stored
--    rather than derived at read time because NCDOT's reports print it and
--    reviewers cross-reference against them.
-- ============================================================================

create or replace function carries_highway(p_service_on text)
returns boolean
language sql immutable
set search_path = ''
as $$
  select btrim(coalesce(p_service_on,'')) in ('1','4','5','6','7','8')
      or p_service_on ~* '^(highway|overpass|third level|fourth level)'
$$;

comment on function carries_highway(text) is
  'NBI ServiceOn codes that mean a highway is carried on the structure: 1 highway, 4 highway-railroad, 5 highway-pedestrian, 6 overpass at an interchange, 7 third level, 8 fourth level. Also accepts the decoded labels, because the bridge layer publishes the code and the structures layer publishes the words, and both reach this column.';

-- ---------------------------------------------------------------------------
create or replace function snbi_designation(p_seq int)
returns text language sql immutable set search_path = '' as $$
  select 'H' || lpad(p_seq::text, 2, '0')
$$;

-- ---------------------------------------------------------------------------
-- The crosswalk order, applied to one structure. Carried features take the low
-- numbers; the primary below feature follows them; the rest follow it. Ordering
-- inside each group is stable - primary first, then whatever order the features
-- were established in - so a re-run does not shuffle designations under a
-- reviewer who has cited them.
create or replace function renumber_features(p_structure text)
returns table (feature_id uuid, old_designation text, new_designation text)
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  return query
  with ordered as (
    select f.id,
           f.designation as was,
           row_number() over (
             order by case when f.location_type = 'C' then 0 else 1 end,
                      case when f.is_primary then 0 else 1 end,
                      f.created_at,
                      f.id
           )::int as seq
    from features f
    where f.structure_number = p_structure
      and f.withdrawn_at is null
  ),
  moved as (
    update features f
       set feature_seq = o.seq,
           designation = snbi_designation(o.seq)
      from ordered o
     where f.id = o.id
       and (f.feature_seq is distinct from o.seq or f.designation is distinct from snbi_designation(o.seq))
    returning f.id, o.was, f.designation
  )
  select * from moved;
end $$;

comment on function renumber_features(text) is
  'Applies the crosswalk numbering to one structure: carried features first, then the primary below feature, then the remaining below features. Returns only the rows that actually moved, so a caller can report a renumbering rather than guess at one.';

-- ---------------------------------------------------------------------------
-- What the source document said, versus what the crosswalk requires. Both
-- checks are findings rather than corrections: the numbering in a published
-- report is evidence about that report, and rewriting it silently would destroy
-- the only record that it disagreed.
create or replace function check_designation_rules(p_structure text)
returns table (rule_id text, feature_id uuid, severity finding_severity, detail jsonb)
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  -- A carried feature numbered after a below feature.
  return query
  select 'FEATURE_ORDER'::text, f.id, 'warning'::finding_severity,
         jsonb_build_object(
           'designation', f.designation,
           'location_type', f.location_type,
           'first_below', (select min(g.designation) from features g
                            where g.structure_number = p_structure
                              and g.location_type = 'B' and g.withdrawn_at is null),
           'why', 'A carried feature is numbered after a below feature. The crosswalk numbers every carried feature before the first below feature.')
  from features f
  where f.structure_number = p_structure
    and f.withdrawn_at is null
    and f.location_type = 'C'
    and f.designation > (select min(g.designation) from features g
                          where g.structure_number = p_structure
                            and g.location_type = 'B' and g.withdrawn_at is null);

  -- Route designations that ran on across features instead of restarting.
  return query
  select 'ROUTE_DESIGNATION_CONTINUOUS'::text, f.id, 'warning'::finding_severity,
         jsonb_build_object(
           'designation', f.designation,
           'reported', r.route_designation,
           'reported_seq', r.reported_seq,
           'expected', 'R01',
           'why', 'B.RT.01 restarts at R01 within each feature. This document numbered route designations continuously across the structure, so the same number does not mean the same thing in two features.')
  from features f
  join feature_routes r on r.feature_id = f.id
  where f.structure_number = p_structure
    and f.withdrawn_at is null
    and r.reported_seq is not null
    and r.reported_seq <> (
      select count(*) from feature_routes r2
       where r2.feature_id = f.id and r2.route_designation <= r.route_designation);

  -- More than one highway record where routes are merely co-signed.
  return query
  select 'CONCURRENCY_SPLIT'::text, f.id, 'error'::finding_severity,
         jsonb_build_object(
           'designation', f.designation,
           'feature_name', f.feature_name,
           'twin', g.designation,
           'why', 'Two features on this structure share a location and a resolved LRS route. Co-signed routes on one roadway are route records under a single feature and get a single BH06/BH07 pair.')
  from features f
  join features g
    on g.structure_number = f.structure_number
   and g.id <> f.id
   and g.location_type = f.location_type
   and g.withdrawn_at is null
  where f.structure_number = p_structure
    and f.withdrawn_at is null
    and exists (
      select 1 from feature_routes a join feature_routes b
        on a.lrs_route_id = b.lrs_route_id and a.lrs_route_id is not null
       where a.feature_id = f.id and b.feature_id = g.id)
    and f.designation < g.designation;
end $$;

comment on function check_designation_rules(text) is
  'The three structural findings the feature hierarchy makes possible: a carried feature numbered after a below feature, route designations that did not restart at R01 inside their feature, and two features that resolve to the same route in the same location - which is concurrency wrongly split into separate highway records.';

revoke execute on function renumber_features(text) from anon;
revoke execute on function check_designation_rules(text) from anon;
grant execute on function renumber_features(text), check_designation_rules(text) to authenticated, service_role;
