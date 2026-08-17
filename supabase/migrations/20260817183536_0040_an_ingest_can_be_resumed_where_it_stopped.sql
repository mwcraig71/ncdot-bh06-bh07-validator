-- ============================================================================
-- A big load has to be resumable, not just restartable.
--
-- Continuation between invocations is a fire-and-forget fetch — the function
-- hands its cursor to a fresh copy of itself and returns without waiting,
-- because waiting would mean holding one invocation open for the length of the
-- whole job. If that hand-off does not land, the chain stops silently: the
-- probe load stalled at 302,000 of 1,210,860 rows with the run still marked
-- running and no error to read.
--
-- Restarting from zero is not an answer for a load that takes half an hour.
-- So the trigger takes a body, and the body is the cursor: a stalled load is
-- picked up where it stopped.
--
--   select trigger_ingest('probe', '{"off": 302000, "rows": 302000}'::jsonb);
--
-- The run guard is relaxed for exactly this case: passing a cursor is a
-- deliberate resume of the run that is already open, so it is not the "do not
-- pile a second run on top of one still going" case the guard exists for.
-- ============================================================================

create or replace function trigger_ingest(p_source text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare fn text; svc text; tok text; req bigint; anon_key text; resuming boolean;
begin
  fn := case p_source
          when 'counties'   then 'ingest-counties'
          when 'bridges'    then 'ingest-bridges'
          when 'structures' then 'ingest-structures'
          when 'extents'    then 'ingest-route-extents'
          when 'hpms'       then 'ingest-hpms'
          when 'traffic'    then 'ingest-traffic'
          when 'probe'      then 'ingest-traffic-probe'
          else null end;
  if fn is null then
    raise exception 'Unknown source %. One of: counties, bridges, structures, extents, hpms, traffic, probe.', p_source;
  end if;

  svc := case p_source
           when 'counties'   then 'NCDOT_CountyBdy_Poly'
           when 'bridges'    then 'NCDOT_Bridges'
           when 'structures' then 'NCDOT_DynamicStructures'
           when 'extents'    then 'NCDOT_RoadCharacteristicsQtr'
           when 'hpms'       then 'FHWA_HPMS'
           when 'traffic'    then 'NCDOT_TrafficSurvey_AADT'
           when 'probe'      then 'NCDOT_AADT_ProbeEstimated' end;

  resuming := coalesce(p_body ? 'off', false) or coalesce(p_body ? 'run', false);

  if not resuming and exists (
    select 1 from ingest_runs
    where status = 'running' and source_service = svc
      and started_at > now() - interval '2 hours')
  then
    raise exception 'An ingest of % is already running. Wait for it, mark it failed if it is stuck, or resume it by passing a cursor.', p_source;
  end if;

  select token into tok from ingest_secret where id = 1;
  select decrypted_secret into anon_key from vault.decrypted_secrets where name = 'anon_key';

  select net.http_post(
    url     := 'https://drstmntdbmacdplhjvmx.supabase.co/functions/v1/' || fn,
    headers := jsonb_build_object(
                 'Content-Type',    'application/json',
                 'Authorization',   'Bearer ' || anon_key,
                 'x-ingest-token',  tok),
    body    := coalesce(p_body, '{}'::jsonb),
    timeout_milliseconds := 120000
  ) into req;

  return req;
end $$;

comment on function trigger_ingest(text, jsonb) is
  'Starts one ingest, or resumes a stalled one by passing its cursor as the body. Refuses to start a second fresh run of the same source while one is still going; a resume is allowed, because that is the run that is already open.';

revoke execute on function trigger_ingest(text, jsonb) from public, anon;
grant  execute on function trigger_ingest(text, jsonb) to authenticated, service_role;
