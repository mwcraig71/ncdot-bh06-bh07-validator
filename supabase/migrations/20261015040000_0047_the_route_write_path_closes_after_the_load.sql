-- ============================================================================
-- The detour route write path closes after the load.
--
-- ingest_detour_route (0046) had to be callable through the API because the
-- routes are computed outside the database. Once the statewide load is in and
-- verified, nothing writes to detour_route until the next run. The token check
-- inside the function stays; this also removes the role grant, so neither
-- alone admits a caller. Direct table writes were never allowed (row level
-- security has only a read policy); the table grants go as well, so that
-- holds even if a policy is added by mistake later.
--
-- To re-open for a re-run:
--   grant execute on function ingest_detour_route(jsonb, text) to anon, authenticated;
-- and apply this file again afterwards.
-- ============================================================================

revoke execute on function ingest_detour_route(jsonb, text) from public, anon, authenticated;
revoke insert, update, delete, truncate on detour_route from anon, authenticated;
