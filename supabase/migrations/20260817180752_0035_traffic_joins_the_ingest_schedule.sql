-- ============================================================================
-- Traffic joins the schedule, on its own cadence.
--
-- Not quarterly. NCDOT's Traffic Survey publishes once a year and late - the
-- 2024 counts appeared in September 2025 - so a quarterly job would spend three
-- runs out of four re-reading a file that had not changed. It runs in November,
-- after the autumn release has landed, and by hand whenever somebody knows a
-- new one has.
--
-- The probe layer is separate and yearly for the same reason, and separate for
-- one more: at 1.2 million segments it is twenty-five times the size of
-- everything else here, and a load that big should be startable on its own
-- rather than as a side effect of wanting fresh counts.
-- ============================================================================

create or replace function trigger_ingest(p_source text)
returns bigint
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare fn text; svc text; tok text; req bigint; anon_key text;
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

  -- Refuse to pile a second run on top of one still going. These walk millions
  -- of rows upstream; two at once is not twice as fast.
  if exists (
    select 1 from ingest_runs
    where status = 'running' and source_service = svc
      and started_at > now() - interval '2 hours')
  then
    raise exception 'An ingest of % is already running. Wait for it, or mark it failed if it is stuck.', p_source;
  end if;

  select token into tok from ingest_secret where id = 1;
  select decrypted_secret into anon_key from vault.decrypted_secrets where name = 'anon_key';

  select net.http_post(
    url     := 'https://drstmntdbmacdplhjvmx.supabase.co/functions/v1/' || fn,
    headers := jsonb_build_object(
                 'Content-Type',    'application/json',
                 'Authorization',   'Bearer ' || anon_key,
                 'x-ingest-token',  tok),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000
  ) into req;

  return req;
end $$;

comment on function trigger_ingest(text) is
  'Starts one ingest. Used by the schedules and available by hand: select trigger_ingest(''traffic''). Refuses to start a second run of the same source while one is still going.';

revoke execute on function trigger_ingest(text) from public, anon;
grant  execute on function trigger_ingest(text) to authenticated, service_role;

select cron.schedule('ingest-traffic-annual', '0 9 20 11 *',
                     $$select trigger_ingest('traffic')$$);
select cron.schedule('ingest-probe-annual',   '0 10 21 11 *',
                     $$select trigger_ingest('probe')$$);
