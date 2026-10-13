-- ============================================================================
-- The detour write path closes after the load.
--
-- ingest_detour (0042) had to be callable through the API because the
-- measurement runs outside the database. The statewide run of 13 October
-- loaded 32,021 rows for 14,262 structures, verified against the source by
-- mode and verdict. Nothing should write to the table until the next run, so
-- the grant goes until then. The token check inside the function stays; this
-- removes the role grant as well, so neither factor alone admits a caller.
--
-- To re-open for a re-run:
--   grant execute on function ingest_detour(jsonb, text) to anon, authenticated;
-- and apply this file's statement again afterwards.
-- ============================================================================

revoke execute on function ingest_detour(jsonb, text) from anon, authenticated;
