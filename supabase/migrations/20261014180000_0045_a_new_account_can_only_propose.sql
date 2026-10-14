-- 0045: a new account can only propose.
--
-- Sign-ups stay open, so "signed in" must mean no more than "may propose".
-- The code review of 14 October 2026 found four ways round the approval queue
-- (S2, S3, S6, S10) and one way for any account to start an ingest (S7):
--
--   S2  feature_values: any signed-in user could INSERT or UPDATE a DERIVED
--       row, and DERIVED outranks PUBLISHED, so one REST call replaced NCDOT's
--       BH06/BH07 with no approver. Any user could also edit anyone's PROPOSED
--       row or un-reject a rejected one.
--   S3  features: open INSERT/UPDATE let any user withdraw a feature, move it
--       to another bridge, flip carried/below or hide a removal request.
--   S10 feature_routes, review, cleared_findings, value_divergence: open
--       writes let any user rewrite routes or clear findings.
--   S6  approve_proposal approved whatever the PROPOSED row held at click
--       time, so a value swapped in after the approver looked was accepted.
--   S7  trigger_ingest(text, jsonb) let any user start an ingest with an
--       arbitrary cursor body.
--
-- The page never writes these tables directly: every write it makes goes
-- through a SECURITY DEFINER function (propose_value, propose_feature_removal,
-- approve_proposal, reject_proposal, decide_feature_removal, grant_approver,
-- revoke_approver, trigger_ingest). So the direct grants go, and those
-- functions remain the only way in. They run as the owner, so they keep
-- working.

------------------------------------------------------------------------------
-- 1. No direct writes from the browser roles.
------------------------------------------------------------------------------
drop policy if exists propose_or_derive  on public.feature_values;
drop policy if exists amend_own_layer    on public.feature_values;
drop policy if exists write_features     on public.features;
drop policy if exists update_features    on public.features;
drop policy if exists write_routes       on public.feature_routes;
drop policy if exists update_routes      on public.feature_routes;
drop policy if exists write_review       on public.review;
drop policy if exists update_review      on public.review;
drop policy if exists write_clear        on public.cleared_findings;
drop policy if exists resolve_divergence on public.value_divergence;

revoke insert, update, delete, truncate on
  public.feature_values, public.features, public.feature_routes,
  public.review, public.cleared_findings, public.value_divergence
  from public, anon, authenticated;

------------------------------------------------------------------------------
-- 2. propose_value may not overwrite somebody else's open proposal.
--    An approver decides it first. The proposer may still revise their own.
------------------------------------------------------------------------------
create or replace function public.propose_value(
  p_structure text, p_designation text, p_field snbi_field, p_value text,
  p_note text default null, p_location feature_location default 'B',
  p_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare fid uuid; created boolean := false; nm text; num numeric; other uuid;
begin
  if current_actor() is null then
    raise exception 'Sign in before submitting from the field.' using errcode='42501';
  end if;
  if coalesce(btrim(p_structure),'') = '' or coalesce(btrim(p_designation),'') = '' then
    raise exception 'A submission needs a structure and a feature designation.';
  end if;
  if not exists (select 1 from structures where structure_number = btrim(p_structure)) then
    raise exception 'No structure %', p_structure;
  end if;

  select id into fid from features
   where structure_number = btrim(p_structure) and designation = btrim(p_designation);

  if fid is null then
    insert into features (structure_number, designation, location_type, feature_name,
                          derivation_method, computed_at, computed_by)
    values (btrim(p_structure), btrim(p_designation), p_location, p_name,
            'added in the field', now(), 'field')
    returning id into fid;
    created := true;
  else
    -- lock the open proposal, if any, and refuse to replace another person's
    select actor into other from feature_values
     where feature_id = fid and field = p_field and source = 'PROPOSED'
       and withdrawn_at is null
     for update;
    if found and other is distinct from current_actor() and not is_approver() then
      raise exception 'Another inspector''s % proposal for this feature is waiting for an approver. It has to be accepted or rejected before a new one can be submitted.', p_field
        using errcode = '42501';
    end if;
  end if;

  select display_name into nm from reviewer_roles where actor = current_actor() and revoked_at is null;

  if p_field = 'BH07' then
    begin num := round(p_value::numeric, 3); exception when others then
      raise exception 'BH07 has to be a number. Got %', p_value; end;
    insert into feature_values (feature_id, field, source, value_num, note)
    values (fid, 'BH07', 'PROPOSED', num, p_note)
    on conflict (feature_id, field, source) do update
      set value_num = excluded.value_num, note = excluded.note,
          withdrawn_at = null, recorded_at = now();
  else
    insert into feature_values (feature_id, field, source, value_text, note)
    values (fid, 'BH06', 'PROPOSED', btrim(p_value), p_note)
    on conflict (feature_id, field, source) do update
      set value_text = excluded.value_text, note = excluded.note,
          withdrawn_at = null, recorded_at = now();
  end if;

  return jsonb_build_object('feature_id', fid, 'created_feature', created,
                            'field', p_field, 'queued', true);
end $function$;

------------------------------------------------------------------------------
-- 3. Approve and reject what the approver saw, not what is there now.
--    p_expected is the value shown on screen. It defaults to null so a copy
--    of the page from before this migration still works; the current page
--    always sends it. The row is locked while it is decided.
------------------------------------------------------------------------------
drop function if exists public.approve_proposal(uuid, snbi_field, text);
drop function if exists public.reject_proposal(uuid, snbi_field, text);

create function public.approve_proposal(
  p_feature uuid, p_field snbi_field, p_reason text default null,
  p_expected text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare p feature_values; nm text;
begin
  if not is_approver() then
    raise exception 'Only a designated approver can accept a proposal.' using errcode='42501';
  end if;
  select * into p from feature_values
   where feature_id=p_feature and field=p_field and source='PROPOSED' and withdrawn_at is null
   for update;
  if not found then raise exception 'No open proposal for that feature and field.'; end if;
  if p_expected is not null
     and btrim(p_expected) is distinct from coalesce(p.value_text, p.value_num::text) then
    raise exception 'This proposal changed after you opened it (now %). Reload the queue and check it again.',
      coalesce(p.value_text, p.value_num::text) using errcode='40001';
  end if;

  select coalesce(display_name, split_part(coalesce(current_setting('request.jwt.claim.email', true),''),'@',1))
    into nm from reviewer_roles where actor=current_actor();

  insert into feature_values (feature_id, field, source, value_text, value_num,
                              reviewer_name, note, derivation_method, confidence)
  values (p_feature, p_field, 'REVIEWED', p.value_text, p.value_num,
          p.reviewer_name, coalesce(p.note,'') ||
          case when p_reason is null then '' else E'\n[approved] '||p_reason end,
          p.derivation_method, p.confidence)
  on conflict (feature_id, field, source) do update
    set value_text=excluded.value_text, value_num=excluded.value_num,
        note=excluded.note, withdrawn_at=null, recorded_at=now();

  update feature_values set withdrawn_at=now()
   where feature_id=p_feature and field=p_field and source='PROPOSED';

  insert into proposal_decisions (feature_id, field, action, proposed_text, proposed_num, reason, actor, actor_name)
  values (p_feature, p_field, 'approve', p.value_text, p.value_num, p_reason, current_actor(), nm);

  return jsonb_build_object('approved', true, 'field', p_field,
                            'value', coalesce(p.value_text, p.value_num::text));
end $function$;

create function public.reject_proposal(
  p_feature uuid, p_field snbi_field, p_reason text,
  p_expected text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare p feature_values;
begin
  if not is_approver() then
    raise exception 'Only a designated approver can reject a proposal.' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'A rejection needs a reason. The inspector who submitted it has to be able to read why.';
  end if;
  select * into p from feature_values
   where feature_id=p_feature and field=p_field and source='PROPOSED' and withdrawn_at is null
   for update;
  if not found then raise exception 'No open proposal for that feature and field.'; end if;
  if p_expected is not null
     and btrim(p_expected) is distinct from coalesce(p.value_text, p.value_num::text) then
    raise exception 'This proposal changed after you opened it (now %). Reload the queue and check it again.',
      coalesce(p.value_text, p.value_num::text) using errcode='40001';
  end if;

  update feature_values set withdrawn_at=now(), note=coalesce(note,'')||E'\n[rejected] '||p_reason
   where feature_id=p_feature and field=p_field and source='PROPOSED';

  insert into proposal_decisions (feature_id, field, action, proposed_text, proposed_num, reason, actor)
  values (p_feature, p_field, 'reject', p.value_text, p.value_num, p_reason, current_actor());
  return jsonb_build_object('rejected', true);
end $function$;

revoke execute on function public.approve_proposal(uuid, snbi_field, text, text) from public, anon;
revoke execute on function public.reject_proposal(uuid, snbi_field, text, text)  from public, anon;
grant  execute on function public.approve_proposal(uuid, snbi_field, text, text) to authenticated, service_role;
grant  execute on function public.reject_proposal(uuid, snbi_field, text, text)  to authenticated, service_role;

------------------------------------------------------------------------------
-- 4. One trigger_ingest, and only an approver may call it from the page.
--    0040 added trigger_ingest(text, jsonb default '{}') beside the original
--    trigger_ingest(text), so a one-argument call (all seven cron jobs and the
--    Settings reload button) has two candidates and Postgres refuses it as
--    "not unique". Dropping the one-argument version leaves one function that
--    serves both. From the page (a browser JWT) it now needs an approver and
--    takes no cursor body; cron and the service role are unchanged.
------------------------------------------------------------------------------
drop function if exists public.trigger_ingest(text);

create or replace function public.trigger_ingest(p_source text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_catalog'
as $function$
declare fn text; svc text; tok text; req bigint; anon_key text; resuming boolean;
begin
  if jwt_role() in ('anon','authenticated') then
    if not is_approver() then
      raise exception 'Only an approver can reload reference data.' using errcode='42501';
    end if;
    if coalesce(p_body, '{}'::jsonb) <> '{}'::jsonb then
      raise exception 'A resume cursor can only be passed by the server, not from the page.' using errcode='42501';
    end if;
  end if;

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
end $function$;

revoke execute on function public.trigger_ingest(text, jsonb) from public, anon;
grant  execute on function public.trigger_ingest(text, jsonb) to authenticated, service_role;

------------------------------------------------------------------------------
-- 5. Self-check: after this migration no browser role can write any of the
--    six tables directly. Fails the migration if a grant survived.
------------------------------------------------------------------------------
do $$
declare t text; r text;
begin
  foreach t in array array['feature_values','features','feature_routes','review',
                           'cleared_findings','value_divergence'] loop
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r, 'public.'||t, 'INSERT')
         or has_table_privilege(r, 'public.'||t, 'UPDATE')
         or has_table_privilege(r, 'public.'||t, 'DELETE') then
        raise exception '0045: % can still write %', r, t;
      end if;
    end loop;
  end loop;
end $$;
