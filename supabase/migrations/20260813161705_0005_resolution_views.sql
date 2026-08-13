-- ============================================================================
-- Resolution
--
-- Precedence exists exactly once, here. The application reads these views and
-- never re-derives "which value wins" for itself — that is how the browser
-- tool ended up validating one number while exporting another.
--
-- The rule is the enum ordering: PUBLISHED < DERIVED < REVIEWED, so the winner
-- is simply the highest source present. Changing the order of value_source
-- changes the precedence of the whole system; there is nowhere else to look.
--
-- security_invoker on every view, so RLS is evaluated as the caller and a view
-- can never be a way around a policy.
-- ============================================================================

create view feature_value_resolved
with (security_invoker = true) as
select distinct on (fv.feature_id, fv.field)
  fv.feature_id,
  fv.field,
  fv.source,
  fv.value_text,
  fv.value_num,
  fv.confidence,
  fv.derivation_method,
  fv.offset_ft,
  fv.reviewer_name,
  fv.actor,
  fv.note,
  fv.ingest_run_id,
  fv.recorded_at
from feature_values fv
order by fv.feature_id, fv.field, fv.source desc;

comment on view feature_value_resolved is
  'The winning row per (feature, field). DISTINCT ON with source DESC: the enum is declared weakest-first, so the highest source present wins.';

-- ------------------------------------------------------------------------
-- One row per feature, both fields resolved, with the published values kept
-- alongside so a caller can show "tested X, NCDOT publishes Y" without a
-- second query — the panel needs both, and asking twice invites them to drift.
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

  -- true when what is being validated is not what NCDOT publishes
  (coalesce(r6.source,'PUBLISHED') <> 'PUBLISHED'
   or coalesce(r7.source,'PUBLISHED') <> 'PUBLISHED')  as is_overridden,
  (r6.source = 'REVIEWED' or r7.source = 'REVIEWED')   as has_reviewed_value,

  -- the extent of the route actually under test, which is what a milepoint
  -- has to fall inside
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

-- ------------------------------------------------------------------------
-- Findings with their current cleared state. Clearing is an event log, so
-- "is it cleared" is the latest event, not a column someone flipped.
create view finding_current
with (security_invoker = true) as
select
  fd.id,
  fd.feature_id,
  fd.rule_id,
  fd.rule_code,
  fd.severity,
  fd.evaluated_source,
  fd.detail,
  fd.computed_at,
  (c.action = 'clear')       as is_cleared,
  c.reason                   as cleared_reason,
  c.reviewer_name            as cleared_by,
  c.actor                    as cleared_actor,
  c.created_at               as cleared_at
from findings fd
left join lateral (
  select cf.action, cf.reason, cf.reviewer_name, cf.actor, cf.created_at
  from cleared_findings cf
  where cf.feature_id = fd.feature_id and cf.rule_id = fd.rule_id
  order by cf.created_at desc, cf.id desc
  limit 1
) c on true;

comment on view finding_current is
  'Findings with the latest clear/restore decision applied. A restore is a later event, never a deletion, so the sequence of decisions stays readable.';

-- ------------------------------------------------------------------------
-- Structure-level rollup for the map and the results table.
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

-- ------------------------------------------------------------------------
-- What an export cites for its own vintage.
create view data_vintage
with (security_invoker = true) as
select distinct on (source_service)
  source_service,
  published_at,
  publication_label,
  completed_at,
  row_count
from ingest_runs
where status = 'ok'
order by source_service, completed_at desc;

comment on view data_vintage is
  'Latest successful load per upstream service. An export states this so the reader knows what it was built from.';
