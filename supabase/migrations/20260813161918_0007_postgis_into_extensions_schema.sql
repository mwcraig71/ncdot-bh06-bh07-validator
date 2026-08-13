-- ============================================================================
-- Move PostGIS out of `public`.
--
-- 0001 created it without naming a schema, so it landed in public alongside
-- the application tables. That exposes spatial_ref_sys and every ST_ function
-- through PostgREST, and spatial_ref_sys is extension-owned so RLS cannot be
-- enabled on it — the linter reports that as an error and it cannot be fixed
-- in place. PostGIS does not support ALTER EXTENSION ... SET SCHEMA, so the
-- only route is drop and recreate.
--
-- Free to do here: there is no data yet. Replaying the migrations in order
-- reaches this same end state, which is what matters for reproducibility.
-- pgcrypto and uuid-ossp were already in `extensions`; this puts postgis where
-- it should have been from the start.
-- ============================================================================

-- Views read structures.location, so they go first and come back at the end
-- unchanged.
drop view if exists structure_status;
drop view if exists feature_resolved;

alter table structures drop column location;   -- takes the GIST index with it

drop extension postgis;
create extension postgis with schema extensions;

-- Fully qualified from here on, so the column's type does not depend on
-- whatever search_path the session happens to carry.
alter table structures
  add column location extensions.geography(Point,4326);

comment on column structures.location is
  'Published coordinates. geography so that distance to a milepoint comes back in metres without a projection step.';

create index structures_location_gix on structures using gist (location);

-- ---------------------------------------------------------------------------
-- Views restored verbatim.
create view feature_resolved
with (security_invoker = true) as
select
  f.id                       as feature_id,
  f.structure_number,
  f.designation,
  f.location_type,
  f.feature_name,
  s.county_name,
  s.county_sap,
  s.division,
  s.feature_carried,
  s.feature_intersected,
  s.service_on,
  s.structure_type,
  s.location,

  r6.value_text              as bh06,
  r6.source                  as bh06_source,
  r6.confidence              as bh06_confidence,
  r6.recorded_at             as bh06_recorded_at,
  r6.reviewer_name           as bh06_reviewer,

  r7.value_num               as bh07,
  r7.source                  as bh07_source,
  r7.confidence              as bh07_confidence,
  r7.recorded_at             as bh07_recorded_at,
  r7.reviewer_name           as bh07_reviewer,

  p6.value_text              as bh06_published,
  p7.value_num               as bh07_published,

  (coalesce(r6.source,'PUBLISHED') <> 'PUBLISHED'
   or coalesce(r7.source,'PUBLISHED') <> 'PUBLISHED')  as is_overridden,
  (r6.source = 'REVIEWED' or r7.source = 'REVIEWED')   as has_reviewed_value,

  re.min_mp                  as route_min_mp,
  re.max_mp                  as route_max_mp
from features f
join structures s on s.structure_number = f.structure_number
left join feature_value_resolved r6 on r6.feature_id = f.id and r6.field = 'BH06'
left join feature_value_resolved r7 on r7.feature_id = f.id and r7.field = 'BH07'
left join feature_values p6
       on p6.feature_id = f.id and p6.field = 'BH06' and p6.source = 'PUBLISHED'
left join feature_values p7
       on p7.feature_id = f.id and p7.field = 'BH07' and p7.source = 'PUBLISHED'
left join route_extents re on re.route_id = r6.value_text;

comment on view feature_resolved is
  'The object the application reads: one row per feature with the BH06/BH07 under test, the source that won, and NCDOT''s published values alongside. Nothing downstream should re-implement precedence.';

create view structure_status
with (security_invoker = true) as
select
  s.structure_number,
  s.county_name,
  s.division,
  s.structure_type,
  s.location,
  count(distinct f.id) filter (where f.designation like 'H%'
                                 and f.location_type = 'C') as highway_features,
  count(*) filter (where fc.severity = 'error'   and not coalesce(fc.is_cleared,false)) as errors,
  count(*) filter (where fc.severity = 'warning' and not coalesce(fc.is_cleared,false)) as warnings,
  count(*) filter (where fc.severity = 'note'    and not coalesce(fc.is_cleared,false)) as notes,
  count(*) filter (where coalesce(fc.is_cleared,false))                                  as cleared,
  bool_or(fr.has_reviewed_value)                                                         as has_reviewed_value,
  max(fc.computed_at)                                                                    as last_validated_at
from structures s
left join features f          on f.structure_number = s.structure_number
left join finding_current fc  on fc.feature_id = f.id
left join feature_resolved fr on fr.feature_id = f.id
group by s.structure_number, s.county_name, s.division, s.structure_type, s.location;

comment on view structure_status is
  'Per-structure rollup with cleared findings excluded from the counts, which is what the summary tiles and map colours read.';
