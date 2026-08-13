-- ============================================================================
-- Row level security
--
-- Read: open. Every input is already published by NCDOT and FHWA, and the
-- browser tool has always been public. Nothing is gained by hiding it.
--
-- Write: authenticated accounts only. This is the part that changed when the
-- data moved into a database. A shared review layer feeding a March submittal
-- is evidence, and evidence with anonymous write access is not evidence. It is
-- also what makes review_history.actor mean anything.
--
-- The service role bypasses RLS by design and is what ingest jobs use.
-- ============================================================================

alter table structures       enable row level security;
alter table features         enable row level security;
alter table feature_values   enable row level security;
alter table findings         enable row level security;
alter table cleared_findings enable row level security;
alter table review           enable row level security;
alter table review_history   enable row level security;
alter table route_extents    enable row level security;
alter table hpms_routes      enable row level security;
alter table county_codes     enable row level security;
alter table ingest_runs      enable row level security;

-- ------------------------------------------------------------------ read ---
create policy read_all on structures       for select to anon, authenticated using (true);
create policy read_all on features         for select to anon, authenticated using (true);
create policy read_all on feature_values   for select to anon, authenticated using (true);
create policy read_all on findings         for select to anon, authenticated using (true);
create policy read_all on cleared_findings for select to anon, authenticated using (true);
create policy read_all on review           for select to anon, authenticated using (true);
create policy read_all on route_extents    for select to anon, authenticated using (true);
create policy read_all on hpms_routes      for select to anon, authenticated using (true);
create policy read_all on county_codes     for select to anon, authenticated using (true);
create policy read_all on ingest_runs      for select to anon, authenticated using (true);

-- The audit trail is readable by signed-in accounts only. It carries who did
-- what, which is the one part of this database that is about people.
create policy read_history on review_history
  for select to authenticated using (true);

-- ----------------------------------------------------------------- write ---
-- Corrections. An authenticated account may write REVIEWED rows and nothing
-- else: PUBLISHED belongs to ingest and DERIVED to the derivation pass, both
-- of which run as the service role. So the hierarchy is enforced twice over —
-- by the unique key, which stops a derive reaching a review, and by these
-- policies, which stop a client writing anything but a review.
create policy review_writes_reviewed_only on feature_values
  for insert to authenticated
  with check (source = 'REVIEWED' and actor = auth.uid());

create policy review_updates_reviewed_only on feature_values
  for update to authenticated
  using (source = 'REVIEWED')
  with check (source = 'REVIEWED' and actor = auth.uid());

-- Withdrawing a correction is a delete of the REVIEWED row; the published and
-- derived rows are untouched and the feature falls back to them on its own.
create policy review_deletes_reviewed_only on feature_values
  for delete to authenticated
  using (source = 'REVIEWED');

create policy review_write on review
  for insert to authenticated with check (actor = auth.uid());
create policy review_update on review
  for update to authenticated using (true) with check (actor = auth.uid());

-- Clearing and restoring: anyone signed in may record a decision, and nobody
-- may edit or remove one. The append-only trigger enforces the second half
-- even against the service role.
create policy clear_write on cleared_findings
  for insert to authenticated with check (actor = auth.uid());

-- ------------------------------------------------------ deliberately none ---
-- structures, features, findings, route_extents, hpms_routes, county_codes and
-- ingest_runs have no client write policy at all. They are machine-produced
-- from upstream services, and RLS denies by default, so an ingest must run as
-- the service role. A reviewer cannot quietly edit the published inventory —
-- if the published value is wrong, that is a REVIEWED correction with a name
-- on it, which is exactly the record the submittal needs.

-- review_history has no write policy either. It is written only by the audit
-- trigger, which is security definer, and cannot be written directly by any
-- client.
