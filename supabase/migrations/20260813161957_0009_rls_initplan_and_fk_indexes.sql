-- ============================================================================
-- Performance corrections, from the database linter.
-- ============================================================================

-- auth.uid() written bare in a policy is re-evaluated once per row. Wrapped in
-- a scalar subquery Postgres hoists it to an InitPlan and evaluates it once.
-- At 23,000 structures with several features each this is the difference
-- between a policy that is free and one that is not.
drop policy review_writes_reviewed_only  on feature_values;
drop policy review_updates_reviewed_only on feature_values;
drop policy review_write                 on review;
drop policy review_update                on review;
drop policy clear_write                  on cleared_findings;

create policy review_writes_reviewed_only on feature_values
  for insert to authenticated
  with check (source = 'REVIEWED' and actor = (select auth.uid()));

create policy review_updates_reviewed_only on feature_values
  for update to authenticated
  using (source = 'REVIEWED')
  with check (source = 'REVIEWED' and actor = (select auth.uid()));

create policy review_write on review
  for insert to authenticated with check (actor = (select auth.uid()));

create policy review_update on review
  for update to authenticated using (true)
  with check (actor = (select auth.uid()));

create policy clear_write on cleared_findings
  for insert to authenticated with check (actor = (select auth.uid()));

-- Covering indexes for the foreign keys. The actor ones answer "everything
-- this reviewer touched", which is a question the submittal will be asked; the
-- ingest_run ones answer "everything that came in on this load", which is what
-- a bad load has to be unwound by.
create index feature_values_actor_idx    on feature_values (actor)
  where actor is not null;
create index feature_values_run_idx      on feature_values (ingest_run_id);
create index cleared_findings_actor_idx  on cleared_findings (actor)
  where actor is not null;
create index review_actor_idx            on review (actor)
  where actor is not null;
create index hpms_routes_run_idx         on hpms_routes (ingest_run_id);
create index route_extents_run_idx       on route_extents (ingest_run_id);
create index structures_run_idx          on structures (ingest_run_id);
create index structures_county_sap_idx   on structures (county_sap);
