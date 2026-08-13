-- ============================================================================
-- Scheduling
--
-- NCDOT republishes quarterly, and the services say so about themselves: the
-- bridge layer reports a Latest Publication Date, Road Characteristics is
-- literally named "Qtr". So the schedule is quarterly, a fortnight into the
-- month after each quarter ends, which is late enough that a republication due
-- in that quarter has normally landed.
--
-- The cadence is not the whole answer though. A quarterly job that can only run
-- quarterly means a reviewer who KNOWS a republish happened has to wait, so
-- there is a manual trigger beside it, and it is the same call.
-- ============================================================================

create extension if not exists pg_cron  with schema extensions;
create extension if not exists pg_net   with schema extensions;

-- ---------------------------------------------------------------------------
create or replace function trigger_ingest(p_source text)
returns bigint
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare fn text; tok text; req bigint; anon_key text;
begin
  fn := case p_source
          when 'counties'   then 'ingest-counties'
          when 'bridges'    then 'ingest-bridges'
          when 'structures' then 'ingest-structures'
          when 'extents'    then 'ingest-route-extents'
          when 'hpms'       then 'ingest-hpms'
          else null end;
  if fn is null then
    raise exception 'Unknown source %. One of: counties, bridges, structures, extents, hpms.', p_source;
  end if;

  -- Refuse to pile a second run on top of one still going. These walk millions
  -- of rows upstream; two at once is not twice as fast.
  if exists (
    select 1 from ingest_runs
    where status = 'running'
      and source_service = case p_source
            when 'counties'   then 'NCDOT_CountyBdy_Poly'
            when 'bridges'    then 'NCDOT_Bridges'
            when 'structures' then 'NCDOT_DynamicStructures'
            when 'extents'    then 'NCDOT_RoadCharacteristicsQtr'
            when 'hpms'       then 'FHWA_HPMS' end
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
  'Starts one ingest. Used by the quarterly schedule and available by hand: select trigger_ingest(''bridges''). Refuses to start a second run of the same source while one is still going.';

-- A reviewer who knows NCDOT has republished should not have to wait for a
-- quarter boundary. Reading the ingest token still is not possible for them —
-- this runs as definer and never returns it.
revoke execute on function trigger_ingest(text) from public, anon;
grant  execute on function trigger_ingest(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Quarterly, staggered so they do not contend for the same upstream service.
-- Counties first (extents depends on it), then bridges, then the rest.
select cron.schedule('ingest-counties-quarterly',   '0 6 15 1,4,7,10 *',
                     $$select trigger_ingest('counties')$$);
select cron.schedule('ingest-bridges-quarterly',    '20 6 15 1,4,7,10 *',
                     $$select trigger_ingest('bridges')$$);
select cron.schedule('ingest-structures-quarterly', '40 6 15 1,4,7,10 *',
                     $$select trigger_ingest('structures')$$);
select cron.schedule('ingest-extents-quarterly',    '0 7 15 1,4,7,10 *',
                     $$select trigger_ingest('extents')$$);
select cron.schedule('ingest-hpms-annual',          '0 8 15 6 *',
                     $$select trigger_ingest('hpms')$$);

comment on function parse_publication_date(text) is
  'Best effort at a timestamp from the free text a service reports as its vintage. Returns null rather than guessing; publication_label always keeps the original words. HPMS is annual, not quarterly, and reports no date at all — its schedule and its label both say so.';
