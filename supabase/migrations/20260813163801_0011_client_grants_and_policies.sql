-- ============================================================================
-- Client grants and the policy set
--
-- Two layers, because they fail differently. Table GRANTS are coarse and refuse
-- loudly — a revoked DELETE raises "permission denied", which a client cannot
-- mistake for success. RLS is fine-grained and refuses quietly — a denied
-- UPDATE affects zero rows and reports OK. So the blunt rules ("no client ever
-- deletes", "anon never writes") are grants, and the conditional ones ("only a
-- REVIEWED row", "only your own account") are policies.
--
-- Stated once, plainly:
--   anon           SELECT, everywhere, nothing else
--   authenticated  SELECT everywhere; INSERT/UPDATE on the review surface and
--                  on features and DERIVED values; never PUBLISHED; never DELETE
--   service_role   everything, bypassing RLS — ingest and back-end jobs
-- ============================================================================

-- --------------------------------------------------------------- grants ----
-- Start from nothing rather than from whatever Supabase's defaults granted, so
-- what follows is the complete statement of client access.
revoke all on all tables in schema public from anon, authenticated;

grant select on all tables in schema public to anon, authenticated;

-- The review surface. No DELETE anywhere below: corrections supersede, and a
-- withdrawal is an UPDATE that sets withdrawn_at.
grant insert, update on feature_values   to authenticated;
grant insert, update on review           to authenticated;
grant insert         on cleared_findings to authenticated;
grant insert, update on features         to authenticated;

-- Future tables inherit the same shape, so a later migration cannot quietly
-- hand anon a write by forgetting to revoke one.
alter default privileges in schema public
  revoke all on tables from anon, authenticated;
alter default privileges in schema public
  grant select on tables to anon, authenticated;

-- ------------------------------------------------------------- policies ----
drop policy if exists read_all      on structures;
drop policy if exists read_all      on features;
drop policy if exists read_all      on feature_values;
drop policy if exists read_all      on findings;
drop policy if exists read_all      on cleared_findings;
drop policy if exists read_all      on review;
drop policy if exists read_all      on route_extents;
drop policy if exists read_all      on hpms_routes;
drop policy if exists read_all      on county_codes;
drop policy if exists read_all      on ingest_runs;
drop policy if exists read_history  on review_history;
drop policy if exists review_writes_reviewed_only  on feature_values;
drop policy if exists review_updates_reviewed_only on feature_values;
drop policy if exists review_deletes_reviewed_only on feature_values;
drop policy if exists review_write   on review;
drop policy if exists review_update  on review;
drop policy if exists clear_write    on cleared_findings;

-- ------------------------------------------------------------------ read ---
-- Everything is readable by anyone. Every input is already published by NCDOT
-- and FHWA, and the tool being useful without a login is the point of it.
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
create policy read_all on review_history   for select to anon, authenticated using (true);

comment on table review_history is
  'Append-only record of every change to feature_values, review and cleared_findings, with before/after and actor. Readable by anyone: this is the provenance of a public submittal, and a trail nobody can inspect is worth less than one they can. reviewer_name is a display name, never an email — see auth_display_name().';

-- ----------------------------------------------------------------- write ---
-- A reviewer may write a correction, and may run the derivation pass — that is
-- Fill missing, and it runs in the browser. Both are values with a source on
-- them. PUBLISHED is not in the list and cannot be added by a client, because
-- it is what NCDOT says and no reviewer speaks for NCDOT.
create policy write_review_and_derived on feature_values
  for insert to authenticated
  with check (source in ('REVIEWED','DERIVED'));

-- USING decides which existing rows are reachable; WITH CHECK decides what they
-- may become. Both exclude PUBLISHED, so a PUBLISHED row is not merely
-- protected from becoming something else — it is invisible to UPDATE entirely.
create policy update_review_and_derived on feature_values
  for update to authenticated
  using       (source in ('REVIEWED','DERIVED'))
  with check  (source in ('REVIEWED','DERIVED'));

create policy write_review  on review for insert to authenticated with check (true);
create policy update_review on review for update to authenticated using (true) with check (true);

create policy write_clear on cleared_findings
  for insert to authenticated with check (true);

-- Fill missing creates the highway feature it derives values for, so a reviewer
-- needs to be able to upsert one. It cannot delete one: features cascade to
-- values, findings and review, and a client able to drop a feature could erase
-- a reviewed correction sideways without ever touching feature_values.
create policy write_features  on features for insert to authenticated with check (true);
create policy update_features on features for update to authenticated using (true) with check (true);

-- The actor = auth.uid() checks that used to be here are gone on purpose. They
-- are now enforced by stamp_identity(), which overwrites the columns instead of
-- validating them — a check can only reject a wrong name, whereas overwriting
-- means a wrong one cannot be submitted at all.

-- ------------------------------------------------------ deliberately none ---
-- structures, findings, route_extents, hpms_routes, county_codes, ingest_runs
-- and review_history: no client write grant and no write policy. They are
-- machine-produced, and RLS plus the revoked grant means an ingest or a
-- validation pass has to run as the service role.
--
-- DELETE: not granted to anon or authenticated on any table in this schema.
-- Withdrawing a correction sets withdrawn_at; superseding a derived value
-- overwrites it in place; a cleared finding is restored by a later event. There
-- is no client path that removes a row, which is what makes the audit trail
-- complete rather than merely well-intentioned.
