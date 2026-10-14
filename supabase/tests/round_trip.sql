-- ============================================================================
-- Round-trip verification.
--
-- Each block ends by raising an exception carrying its results, which both
-- prints the outcome and rolls the whole thing back. Nothing persists, so this
-- is safe to run against the live project.
--
--   psql "$DATABASE_URL" -f supabase/tests/round_trip.sql
--
-- Everything in block 1 runs as the table owner, which bypasses RLS. Block 2
-- switches roles so the policies are actually exercised — a test that runs as
-- the owner proves nothing about what anon can do.
-- ============================================================================

-- ---------------------------------------------------------------- block 1 --
-- Resolution hierarchy, constraints, audit trail, clearing as an event.
do $$
declare
  r text[] := '{}'; fid uuid; v text; n numeric; s value_source; cnt int; ok boolean;
begin
  insert into county_codes (sap_code, county_name, fips_code, dot_division)
  values ('060','MECKLENBURG',119,10);

  insert into ingest_runs (id, source_service, published_at, publication_label, status, completed_at, row_count)
  overriding system value
  values (9001,'NCDOT_Bridges','2026-07-01','2026 Q3','ok',now(),23022);

  insert into structures (structure_number, county_name, county_sap, division,
                          feature_carried, feature_intersected, service_on, structure_type,
                          structure_length, bridge_deck_width, fed_skew, location, ingest_run_id)
  values ('TEST01','MECKLENBURG','060',10,'SR1138 WBL','SUGAR CREEK','Highway','Bridge',
          142.5, 38.2, 15,
          extensions.st_setsrid(extensions.st_makepoint(-80.91094924, 35.13946875),4326)::extensions.geography,
          9001);

  insert into features (structure_number, designation, location_type, feature_name)
  values ('TEST01','H01','C','SR1138 WBL') returning id into fid;

  insert into route_extents (route_id, min_mp, max_mp) values ('40401138060', 0.000, 3.210);

  -- published alone
  insert into feature_values (feature_id, field, source, value_text, ingest_run_id)
  values (fid,'BH06','PUBLISHED','40401138060',9001);
  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  values (fid,'BH07','PUBLISHED',0.227,9001);
  select bh06, bh06_source, bh07, is_overridden into v, s, n, ok
  from feature_resolved where feature_id = fid;
  r := r || format('%s  published alone resolves: %s @ %s from %s, is_overridden=%s',
        case when v='40401138060' and s='PUBLISHED' and n=0.227 and ok=false then 'PASS' else 'FAIL' end, v, n, s, ok);

  -- derived beats published
  insert into feature_values (feature_id, field, source, value_text, derivation_method, confidence, offset_ft)
  values (fid,'BH06','DERIVED','40401138060','nearest carried route','high',3.2);
  insert into feature_values (feature_id, field, source, value_num, derivation_method, confidence, offset_ft)
  values (fid,'BH07','DERIVED',0.231,'measured along route geometry','high',3.2);
  select bh07, bh07_source into n, s from feature_resolved where feature_id = fid;
  r := r || format('%s  derived beats published: %s from %s',
        case when n=0.231 and s='DERIVED' then 'PASS' else 'FAIL' end, n, s);

  -- reviewed beats derived
  insert into feature_values (feature_id, field, source, value_num, reviewer_name, note)
  values (fid,'BH07','REVIEWED',0.240,'M. Craig','Div 10 confirmed');
  select bh07, bh07_source, has_reviewed_value into n, s, ok from feature_resolved where feature_id = fid;
  r := r || format('%s  reviewed beats derived: %s from %s, has_reviewed_value=%s',
        case when n=0.240 and s='REVIEWED' and ok then 'PASS' else 'FAIL' end, n, s, ok);

  select bh06_source into s from feature_resolved where feature_id = fid;
  r := r || format('%s  fields resolve independently: BH06 still from %s',
        case when s='DERIVED' then 'PASS' else 'FAIL' end, s);

  -- THE point of the arrangement: a re-derive cannot reach the review
  insert into feature_values (feature_id, field, source, value_num, derivation_method, confidence)
  values (fid,'BH07','DERIVED',9.999,'second derivation pass','low')
  on conflict (feature_id, field, source)
  do update set value_num=excluded.value_num, derivation_method=excluded.derivation_method,
                confidence=excluded.confidence;
  select bh07, bh07_source into n, s from feature_resolved where feature_id = fid;
  r := r || format('%s  re-derive left the review standing: still %s from %s',
        case when n=0.240 and s='REVIEWED' then 'PASS' else 'FAIL' end, n, s);
  select value_num into n from feature_values where feature_id=fid and field='BH07' and source='DERIVED';
  r := r || format('%s  ...and it did land on its own row: DERIVED=%s',
        case when n=9.999 then 'PASS' else 'FAIL' end, n);

  begin
    update feature_values set source='REVIEWED'
     where feature_id=fid and field='BH07' and source='DERIVED';
    r := r || 'FAIL  relabel DERIVED->REVIEWED was allowed'::text;
  exception when others then
    r := r || 'PASS  relabel DERIVED->REVIEWED refused'::text;
  end;

  -- withdrawal, not deletion: no client role may delete anything
  update feature_values set withdrawn_at=now()
   where feature_id=fid and field='BH07' and source='REVIEWED';
  select bh07, bh07_source into n, s from feature_resolved where feature_id = fid;
  r := r || format('%s  withdrawing the review falls back to derived: %s from %s',
        case when n=9.999 and s='DERIVED' then 'PASS' else 'FAIL' end, n, s);
  select count(*) into cnt from feature_values
   where feature_id=fid and field='BH07' and source='REVIEWED';
  r := r || format('%s  and the withdrawn correction is still on the record: %s row',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);

  begin
    insert into feature_values (feature_id, field, source, value_num) values (fid,'BH06','REVIEWED',1.234);
    r := r || 'FAIL  BH06 accepted a numeric value'::text;
  exception when check_violation then
    r := r || 'PASS  BH06 refused a numeric value (typed check)'::text;
  end;

  begin
    insert into feature_values (feature_id, field, source, value_text) values (fid,'BH06','DERIVED','99999999999');
    r := r || 'FAIL  duplicate (feature, field, source) accepted'::text;
  exception when unique_violation then
    r := r || 'PASS  duplicate (feature, field, source) refused'::text;
  end;

  -- Audit trail. Five inserts and two updates reached the table, but the two
  -- PUBLISHED inserts are not changes to anything -- their provenance is
  -- ingest_run_id and their arrival is the ingest_runs row -- so three inserts
  -- and two updates are recorded. Every REVIEWED and DERIVED write still is.
  select count(*) into cnt from review_history where feature_id=fid and table_name='feature_values';
  r := r || format('%s  history holds one row per change: %s',
        case when cnt=5 then 'PASS' else 'FAIL' end, cnt);
  select count(*) into cnt from review_history
   where feature_id=fid and table_name='feature_values'
     and operation='INSERT' and (after->>'source')='PUBLISHED';
  r := r || format('%s  a first-time published value is not audited as a change: %s',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);
  select count(*) into cnt from review_history
   where feature_id=fid and operation='UPDATE' and changed @> array['withdrawn_at'];
  r := r || format('%s  the withdrawal itself is recorded as a change: %s',
        case when cnt = 1 then 'PASS' else 'FAIL' end, cnt);
  select (before->>'value_num')::numeric into n from review_history
   where feature_id=fid and operation='UPDATE' and table_name='feature_values' order by id limit 1;
  r := r || format('%s  before-image holds the superseded value: %s',
        case when n = 0.231 then 'PASS' else 'FAIL' end, n);
  begin
    update review_history set actor_role='forged' where feature_id=fid;
    r := r || 'FAIL  review_history accepted an UPDATE'::text;
  exception when others then
    r := r || 'PASS  review_history refused an UPDATE'::text;
  end;

  -- clearing is an event
  insert into findings (feature_id, rule_id, severity, rule_code, evaluated_source)
  values (fid,'BH06_3_HPMS','error','BH06-3','DERIVED');
  select is_cleared into ok from finding_current where feature_id=fid and rule_id='BH06_3_HPMS';
  r := r || format('%s  a new finding is not cleared: is_cleared=%s',
        case when ok is not true then 'PASS' else 'FAIL' end, coalesce(ok::text,'null'));

  insert into cleared_findings (feature_id, rule_id, action, reason, reviewer_name)
  values (fid,'BH06_3_HPMS','clear','Ramp - HPMS carries none. Confirmed with Div 10.','M. Craig');
  select is_cleared into ok from finding_current where feature_id=fid and rule_id='BH06_3_HPMS';
  r := r || format('%s  clear event takes effect: is_cleared=%s',
        case when ok then 'PASS' else 'FAIL' end, ok);

  insert into cleared_findings (feature_id, rule_id, action, reason, reviewer_name, created_at)
  values (fid,'BH06_3_HPMS','restore','Reopened after FHWA guidance','M. Craig', now()+interval '1 second');
  select is_cleared into ok from finding_current where feature_id=fid and rule_id='BH06_3_HPMS';
  select count(*) into cnt from cleared_findings where feature_id=fid;
  r := r || format('%s  restore is a later event, not a deletion: is_cleared=%s, %s events kept',
        case when ok=false and cnt=2 then 'PASS' else 'FAIL' end, ok, cnt);

  begin
    delete from cleared_findings where feature_id=fid;
    r := r || 'FAIL  a clearing decision could be deleted'::text;
  exception when others then
    r := r || 'PASS  clearing decisions cannot be deleted'::text;
  end;

  insert into cleared_findings (feature_id, rule_id, action, reason, reviewer_name, created_at)
  values (fid,'BH06_3_HPMS','clear','Cleared again','M. Craig', now()+interval '2 seconds');
  select errors, cleared>0 into cnt, ok from structure_status where structure_number='TEST01';
  r := r || format('%s  cleared findings drop out of the rollup: errors=%s, cleared=%s',
        case when cnt=0 and ok then 'PASS' else 'FAIL' end, cnt, ok);

  select count(*) into cnt from structures
   where extensions.st_dwithin(location,
     extensions.st_setsrid(extensions.st_makepoint(-80.911, 35.1395),4326)::extensions.geography, 50);
  r := r || format('%s  geography answers in metres: %s structure within 50 m',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);

  begin
    insert into features (structure_number, designation, location_type) values ('TEST01','H01','C');
    r := r || 'FAIL  duplicate designation accepted'::text;
  exception when unique_violation then
    r := r || 'PASS  one H01 per structure enforced'::text;
  end;
  begin
    insert into features (structure_number, designation, location_type) values ('TEST01','h1','C');
    r := r || 'FAIL  malformed designation accepted'::text;
  exception when check_violation then
    r := r || 'PASS  malformed designation refused'::text;
  end;

  select publication_label into v from data_vintage where source_service='NCDOT_Bridges';
  r := r || format('%s  export can state its vintage: %s',
        case when v='2026 Q3' then 'PASS' else 'FAIL' end, v);

  raise exception E'BLOCK 1 - RESOLUTION, CONSTRAINTS, AUDIT (rolled back)\n%',
    array_to_string(r, E'\n');
end $$;

-- ---------------------------------------------------------------- block 2 --
-- Grants and RLS, with the Postgres role actually switched. Everything above
-- ran as the table owner, which bypasses RLS entirely and proves nothing about
-- it.
--
-- Note that the two layers fail differently, and both matter. A revoked GRANT
-- raises "permission denied" — loud, and a client cannot mistake it for
-- success. RLS FILTERS: a denied UPDATE affects zero rows and reports OK. So
-- anything written against this database must check the affected row count,
-- not just the absence of an error.
--
-- The strongest version of the anon half of this runs over HTTP with the
-- publishable key rather than SET ROLE, because that exercises PostgREST too:
-- see tests/anon_api_test.sh.
do $$
declare
  r text[] := '{}'; fid uuid; n numeric; s value_source; t text; got uuid;
  owner_n int; anon_n int; auth_n int; hit int; cnt int;
  uid  uuid := '11111111-2222-3333-4444-555555555555';
  uid2 uuid := '22222222-3333-4444-5555-666666666666';
begin
  insert into county_codes (sap_code, county_name) values ('060','MECKLENBURG');
  insert into structures (structure_number, county_name, county_sap) values ('TEST01','MECKLENBURG','060');
  insert into features (structure_number, designation, location_type)
  values ('TEST01','H01','C') returning id into fid;
  insert into feature_values (feature_id,field,source,value_text) values (fid,'BH06','PUBLISHED','40401138060');
  insert into feature_values (feature_id,field,source,value_num)  values (fid,'BH07','PUBLISHED',0.227);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values (uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'michael.craig@strinteg.test','x',now(),now(),now(),'{"full_name":"M. Craig"}'::jsonb),
         (uid2,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'jsmith@ncdot.gov','x',now(),now(),now(),'{}'::jsonb);

  -- ------------------------------------------------------------ anon reads --
  select count(*) into owner_n from review_history;
  execute 'set local role anon'; select count(*) into anon_n from review_history; execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',uid,'role','authenticated')::text, true);
  execute 'set local role authenticated'; select count(*) into auth_n from review_history; execute 'reset role';
  -- The audit trail is public: it is the provenance of a public submittal, and
  -- a trail nobody can inspect is worth less than one they can. reviewer_name is
  -- a display name, never an address, which is what makes that safe.
  r := r || format('%s  the audit trail is readable by everyone: owner %s, anon %s, signed-in %s',
        case when owner_n=2 and anon_n=2 and auth_n=2 then 'PASS' else 'FAIL' end, owner_n, anon_n, auth_n);

  execute 'set local role anon'; select count(*) into anon_n from feature_values; execute 'reset role';
  r := r || format('%s  reference data is public: anon sees %s feature_values rows',
        case when anon_n=2 then 'PASS' else 'FAIL' end, anon_n);

  -- ----------------------------------------------------------- anon writes --
  execute 'set local role anon';
  begin
    insert into structures (structure_number) values ('HACK01');
    r := r || 'FAIL  anon wrote to the published inventory'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  anon has no INSERT grant on structures'::text;
  when others then r := r || ('PASS  anon insert refused: '||sqlerrm)::text; end;
  begin
    insert into feature_values (feature_id,field,source,value_text)
    values (fid,'BH06','REVIEWED','99999999999');
    r := r || 'FAIL  anon wrote a correction'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  anon has no INSERT grant on feature_values'::text;
  when others then r := r || ('PASS  anon correction refused: '||sqlerrm)::text; end;
  begin
    update feature_values set value_num=1.0 where feature_id=fid;
    r := r || 'FAIL  anon updated a value'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  anon has no UPDATE grant'::text;
  when others then r := r || ('PASS  anon update refused: '||sqlerrm)::text; end;
  begin
    delete from feature_values where feature_id=fid;
    r := r || 'FAIL  anon deleted a value'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  anon has no DELETE grant'::text;
  when others then r := r || ('PASS  anon delete refused: '||sqlerrm)::text; end;
  execute 'reset role';

  -- -------------------------------------------------- authenticated writes --
  -- 0045: sign-ups are open, so a signed-in account may PROPOSE and nothing
  -- else. Every direct write is refused by the grant, loudly; the only way in
  -- is through the functions, which check who is calling.
  perform set_config('request.jwt.claims',
    json_build_object('sub',uid,'role','authenticated','email','michael.craig@strinteg.test',
                      'user_metadata', json_build_object('full_name','M. Craig'))::text, true);
  execute 'set local role authenticated';

  declare stmt text; what text;
  begin
    foreach stmt in array array[
      format('insert into feature_values (feature_id,field,source,value_text) values (%L,''BH06'',''DERIVED'',''20000074060'')', fid),
      format('insert into feature_values (feature_id,field,source,value_num) values (%L,''BH07'',''REVIEWED'',0.240)', fid),
      format('insert into feature_values (feature_id,field,source,value_num) values (%L,''BH07'',''PROPOSED'',0.240)', fid),
      format('update feature_values set value_num=9 where feature_id=%L', fid),
      'insert into features (structure_number,designation,location_type) values (''TEST01'',''H02'',''C'')',
      format('update features set withdrawn_at=now() where id=%L', fid),
      format('update features set structure_number=''TEST99'' where id=%L', fid),
      format('insert into review (feature_id,status,note) values (%L,''progress'',''x'')', fid),
      format('insert into cleared_findings (feature_id,rule_id,action,reason) values (%L,''BH06_3_HPMS'',''clear'',''x'')', fid),
      format('insert into feature_routes (feature_id,route_designation) values (%L,''R01'')', fid),
      'update value_divergence set resolution=''x'''
    ] loop
      what := split_part(stmt,' (',1);
      begin
        execute stmt;
        r := r || ('FAIL  a signed-in account could: '||what)::text;
      exception when insufficient_privilege then
        r := r || ('PASS  refused to a signed-in account: '||what)::text;
      when others then
        r := r || ('FAIL  refused for the wrong reason ('||sqlerrm||'): '||what)::text;
      end;
    end loop;
  end;

  -- proposing is the one write, and identity comes from the token
  begin
    perform propose_value('TEST01','H01','BH07','0.240','Div 10 confirmed');
    select actor, reviewer_name into got, t
      from feature_values where feature_id=fid and field='BH07' and source='PROPOSED';
    r := r || format('%s  a proposal is stamped from the token: ...%s / "%s"',
          case when got=uid and t='M. Craig' then 'PASS' else 'FAIL' end, right(got::text,12), t);
  exception when others then r := r || ('FAIL  a signed-in account could not propose: '||sqlerrm)::text; end;

  select bh07, bh07_source into n, s from feature_resolved where feature_id=fid;
  r := r || format('%s  a proposal changes nothing until approved: still %s from %s',
        case when n=0.227 and s='PUBLISHED' then 'PASS' else 'FAIL' end, n, s);

  begin
    perform propose_value('TEST01','H01','BH07','0.241','re-measured');
    select value_num into n from feature_values where feature_id=fid and field='BH07' and source='PROPOSED';
    r := r || format('%s  the proposer may revise their own proposal: now %s',
          case when n=0.241 then 'PASS' else 'FAIL' end, n);
  exception when others then r := r || ('FAIL  could not revise own proposal: '||sqlerrm)::text; end;

  begin
    perform approve_proposal(fid,'BH07','looks right');
    r := r || 'FAIL  a non-approver approved a proposal'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  a non-approver cannot approve'::text; end;
  execute 'reset role';

  -- a second account cannot overwrite the first one's open proposal
  perform set_config('request.jwt.claims',
    json_build_object('sub',uid2,'role','authenticated','email','jsmith@ncdot.gov')::text, true);
  execute 'set local role authenticated';
  begin
    perform propose_value('TEST01','H01','BH07','9.999','mine instead');
    r := r || 'FAIL  another account replaced an open proposal'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  another account cannot replace an open proposal'::text; end;
  select value_num into n from feature_values where feature_id=fid and field='BH07' and source='PROPOSED';
  r := r || format('%s  ...so it still holds the first proposer''s value: %s',
        case when n=0.241 then 'PASS' else 'FAIL' end, n);

  -- a reviewer with no display name set must not leak an address into a public table
  begin
    perform propose_value('TEST01','H01','BH06','40401138060',null);
    select reviewer_name into t from feature_values where feature_id=fid and field='BH06' and source='PROPOSED';
    r := r || format('%s  no display name falls back to the local part, not the address: "%s"',
          case when t='jsmith' then 'PASS' else 'FAIL' end, t);
  exception when others then r := r || ('FAIL  second account could not propose: '||sqlerrm)::text; end;

  begin
    perform trigger_ingest('bridges');
    r := r || 'FAIL  a non-approver started an ingest'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  a non-approver cannot start an ingest'::text; end;
  execute 'reset role';

  -- an approver accepts what they saw, and only that
  insert into reviewer_roles (actor, role, display_name) values (uid2,'approver','J. Smith');
  execute 'set local role authenticated';
  begin
    perform approve_proposal(fid,'BH07','checked',p_expected=>'0.240');
    r := r || 'FAIL  an approval went through for a value the approver never saw'::text;
  exception when serialization_failure then
    r := r || 'PASS  approving a stale value is refused (the proposal is now 0.241)'::text; end;
  begin
    perform trigger_ingest('bridges', '{"off":0}'::jsonb);
    r := r || 'FAIL  a resume cursor was accepted from a browser token'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  even an approver cannot pass a resume cursor from the page'::text; end;
  begin
    perform approve_proposal(fid,'BH07','checked',p_expected=>'0.241');
    select bh07, bh07_source into n, s from feature_resolved where feature_id=fid;
    r := r || format('%s  approving the value on screen promotes it: %s from %s',
          case when n=0.241 and s='REVIEWED' then 'PASS' else 'FAIL' end, n, s);
  exception when others then r := r || ('FAIL  approval refused: '||sqlerrm)::text; end;
  begin
    insert into feature_values (feature_id,field,source,value_text) values (fid,'BH06','REVIEWED','99999999999');
    r := r || 'FAIL  an approver wrote a REVIEWED value without the queue'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  even an approver writes REVIEWED only through the queue'::text; end;
  execute 'reset role';

  -- nothing is removed or forged by any client role
  execute 'set local role authenticated';
  begin
    delete from feature_values where feature_id=fid;
    r := r || 'FAIL  a signed-in account deleted a value'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  DELETE on feature_values is not granted'::text; end;
  begin
    delete from features where id=fid;
    r := r || 'FAIL  a signed-in account deleted a feature'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  DELETE on features is not granted - no sideways cascade'::text; end;
  begin
    insert into findings (feature_id, rule_id, severity) values (fid,'FAKE','note');
    r := r || 'FAIL  a client wrote a finding'::text;
  exception when others then r := r || 'PASS  a client cannot write findings - validation owns those'::text; end;
  begin
    insert into review_history (table_name,row_id,operation,after)
    values ('feature_values','x','INSERT','{}'::jsonb);
    r := r || 'FAIL  a client forged an audit entry'::text;
  exception when others then r := r || 'PASS  a client cannot forge an audit entry'::text; end;
  execute 'reset role';

  -- ------------------------------------------------------------ provenance --
  select count(*) into cnt from review_history where feature_id=fid and actor=uid;
  r := r || format('%s  every proposal is attributed to the account that made it: %s rows',
        case when cnt>=2 then 'PASS' else 'FAIL' end, cnt);

  select string_agg(distinct x, ', ') into t from (
    select after->>'reviewer_name' as x from review_history where after ? 'reviewer_name') q
  where x is not null;
  r := r || format('%s  nothing in the publicly readable trail is an email address: %s',
        case when position('@' in coalesce(t,'')) = 0 then 'PASS' else 'FAIL' end, t);

  -- an ingest carries no user token and is left alone rather than rejected
  perform set_config('request.jwt.claims','',true);
  update feature_values set value_num=0.229
   where feature_id=fid and field='BH07' and source='PUBLISHED';
  select actor into got from feature_values
   where feature_id=fid and field='BH07' and source='PUBLISHED';
  r := r || format('%s  an ingest writes on behalf of nobody: actor=%s',
        case when got is null then 'PASS' else 'FAIL' end, coalesce(got::text,'null'));

  raise exception E'BLOCK 2 - GRANTS, RLS AND IDENTITY (rolled back)\n%', array_to_string(r, E'\n');
end $$;


-- ============================================================================
-- BLOCK 3 — THE INGEST BOUNDARY
--
-- Ingest writes PUBLISHED rows and upserts them. The claim worth testing is not
-- that it writes correctly but that a republish cannot disturb a review: the
-- review is a row with a different key, so there is no statement the ingest
-- issues that reaches it. And where a republish contradicts a live review, the
-- disagreement has to be recorded rather than resolved.
--
-- Rolled back like the others.
-- ============================================================================
do $$
declare
  fid uuid; r text[] := '{}'; cnt int; n numeric; v text; s text; ok boolean;
  run1 bigint; run2 bigint; ts timestamptz;
begin
  insert into ingest_runs (source_service, source_url, publication_label, status)
  values ('NCDOT_Bridges','test','2026 Q3','ok') returning id into run1;
  insert into ingest_runs (source_service, source_url, publication_label, status)
  values ('NCDOT_Bridges','test','2026 Q4','ok') returning id into run2;

  insert into structures (structure_number, county_name, county_sap, ingest_run_id)
  values ('TEST03','MECKLENBURG','060',run1);
  insert into features (structure_number, designation, location_type, feature_name)
  values ('TEST03','H01','C','SR1138 WBL') returning id into fid;

  -- first load
  insert into feature_values (feature_id, field, source, value_text, ingest_run_id)
  values (fid,'BH06','PUBLISHED','40401138060',run1);
  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  values (fid,'BH07','PUBLISHED',0.227,run1);

  select count(*) into cnt from value_divergence where feature_id=fid;
  r := r || format('%s  a first load raises no divergence: %s',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);

  -- a republish with no review under it is simply the new truth
  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  values (fid,'BH07','PUBLISHED',0.231,run2)
  on conflict (feature_id, field, source)
  do update set value_num=excluded.value_num, ingest_run_id=excluded.ingest_run_id;
  select count(*) into cnt from value_divergence where feature_id=fid;
  select bh07 into n from feature_resolved where feature_id=fid;
  r := r || format('%s  a republish with no review under it just lands: bh07=%s, %s divergences',
        case when n=0.231 and cnt=0 then 'PASS' else 'FAIL' end, n, cnt);

  -- now a reviewer disagrees
  insert into feature_values (feature_id, field, source, value_num, reviewer_name, note)
  values (fid,'BH07','REVIEWED',0.240,'M. Craig','Measured with Div 10');

  -- ...and NCDOT republishes again, moving the value out from under them
  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  values (fid,'BH07','PUBLISHED',0.255,run2)
  on conflict (feature_id, field, source)
  do update set value_num=excluded.value_num, ingest_run_id=excluded.ingest_run_id;

  select count(*) into cnt from value_divergence where feature_id=fid and field='BH07';
  r := r || format('%s  a republish under a live review raises a divergence: %s',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);

  select published_before, published_after, reviewed_value
    into v, s, n from value_divergence where feature_id=fid and field='BH07';
  r := r || format('%s  ...and records all three numbers: was %s, now %s, reviewed %s',
        case when v='0.231' and s='0.255' and n=0.240 then 'PASS' else 'FAIL' end, v, s, n);

  select bh07, bh07_source into n, s from feature_resolved where feature_id=fid;
  r := r || format('%s  the review still wins - the ingest resolved nothing: %s from %s',
        case when n=0.240 and s='REVIEWED' then 'PASS' else 'FAIL' end, n, s);

  select resolved_at is null and resolution is null into ok
    from value_divergence where feature_id=fid and field='BH07';
  r := r || format('%s  and it is left open for a person: unresolved=%s',
        case when ok then 'PASS' else 'FAIL' end, ok);

  -- an unchanged republish is not news
  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  values (fid,'BH07','PUBLISHED',0.255,run2)
  on conflict (feature_id, field, source)
  do update set value_num=excluded.value_num, ingest_run_id=excluded.ingest_run_id,
                recorded_at=now();
  select count(*) into cnt from value_divergence where feature_id=fid and field='BH07';
  r := r || format('%s  republishing the same number again raises nothing: still %s',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);

  -- a value that disappears upstream is also a divergence
  delete from feature_values
   where feature_id=fid and field='BH07' and source='PUBLISHED';
  select count(*) into cnt from value_divergence
   where feature_id=fid and field='BH07' and published_after is null;
  r := r || format('%s  a published value that goes away is a divergence too: %s',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);
  select bh07, bh07_source into n, s from feature_resolved where feature_id=fid;
  r := r || format('%s  ...and the review is still what is tested: %s from %s',
        case when n=0.240 and s='REVIEWED' then 'PASS' else 'FAIL' end, n, s);

  -- withdrawn reviews are not live ones
  insert into feature_values (feature_id, field, source, value_text, reviewer_name, withdrawn_at)
  values (fid,'BH06','REVIEWED','40401138999','M. Craig', now());
  insert into feature_values (feature_id, field, source, value_text, ingest_run_id)
  values (fid,'BH06','PUBLISHED','40401138061',run2)
  on conflict (feature_id, field, source)
  do update set value_text=excluded.value_text, ingest_run_id=excluded.ingest_run_id;
  select count(*) into cnt from value_divergence where feature_id=fid and field='BH06';
  r := r || format('%s  a withdrawn review does not make a republish contentious: %s',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);

  -- who may start or perform an ingest
  select count(*) into cnt from information_schema.role_routine_grants
   where routine_name in ('ingest_bridges','ingest_counties','ingest_structures',
                          'ingest_route_extents','ingest_hpms','ingest_begin','ingest_finish')
     and grantee in ('anon','authenticated');
  r := r || format('%s  no client role may execute an ingest function: %s grants',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);

  select count(*) into cnt from information_schema.role_table_grants
   where table_name='ingest_secret' and grantee in ('anon','authenticated');
  r := r || format('%s  and none may read the ingest token: %s grants',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);

  select count(*) into cnt from information_schema.role_routine_grants
   where routine_name='trigger_ingest' and grantee='authenticated';
  r := r || format('%s  the reload button can still call it, and 0045 lets only an approver through: %s grant',
        case when cnt>0 then 'PASS' else 'FAIL' end, cnt);

  select count(*) into cnt from cron.job where jobname like 'ingest-%';
  r := r || format('%s  every source is scheduled: %s jobs',
        case when cnt=5 then 'PASS' else 'FAIL' end, cnt);

  -- the vintage an export cites
  select parse_publication_date('Latest Publication Date: 03/15/2026 : 14:05')::date::text into v;
  r := r || format('%s  publication date parses the bridge-layer format: %s',
        case when v='2026-03-15' then 'PASS' else 'FAIL' end, v);
  select parse_publication_date('(Geoservice Date: 7/27/2020)')::date::text into v;
  r := r || format('%s  ...and the structures format: %s',
        case when v='2020-07-27' then 'PASS' else 'FAIL' end, v);
  select parse_publication_date('(Friday, Feb 10, 2023)')::date::text into v;
  r := r || format('%s  ...and the county format: %s',
        case when v='2023-02-10' then 'PASS' else 'FAIL' end, v);
  select parse_publication_date('HPMS 2024 submittal') into ts;
  r := r || format('%s  ...and returns null rather than guessing: %s',
        case when ts is null then 'PASS' else 'FAIL' end, coalesce(ts::text,'null'));

  raise exception E'BLOCK 3 - THE INGEST BOUNDARY (rolled back)\n%', array_to_string(r, E'\n');
end $$;


-- ============================================================================
-- BLOCK 4 — FEATURES, ROUTES AND TWINS
--
-- A structure is a set of roadways, not a row. What has to hold: the population
-- that gets a feature at all is the NBI set of ServiceOn codes and not just
-- code 1; the crosswalk order survives a renumbering that has to swap two
-- designations; route designations restart inside each feature; co-signed
-- routes stay one feature with several route records; and a sister pair is
-- recorded on both rows so the exclusion it drives can be audited.
--
-- Rolled back like the others.
-- ============================================================================
do $$
declare r text[] := '{}'; cnt int; v text;
  f1 uuid; f2 uuid; f3 uuid; f4 uuid;
begin
  r := r || format('%s  ServiceOn 6 (interchange overpass) carries a highway',
        case when carries_highway('6') then 'PASS' else 'FAIL' end);
  r := r || format('%s  ...and so does the decoded label the structures layer publishes',
        case when carries_highway('Overpass structure at an interchange or second level of a multi-level interchange')
             then 'PASS' else 'FAIL' end);
  r := r || format('%s  a railroad bridge does not', case when not carries_highway('2') then 'PASS' else 'FAIL' end);
  select count(*) into cnt from structures where carries_highway(service_on);
  r := r || format('%s  the population is the NBI set, not just code 1: %s structures',
        case when cnt between 19000 and 20500 then 'PASS' else 'FAIL' end, cnt);
  select count(*) into cnt from features f where f.structure_number='590819';
  r := r || format('%s  590819 (ServiceOn 6) now has a feature: %s',
        case when cnt=1 then 'PASS' else 'FAIL' end, cnt);
  select value_text into v from feature_values fv join features f on f.id=fv.feature_id
   where f.structure_number='590819' and fv.field='BH06' and fv.source='PUBLISHED';
  r := r || format('%s  ...with NCDOT''s published BH06 under test at last: %s',
        case when v='10000085060' then 'PASS' else 'FAIL' end, v);

  insert into structures (structure_number, county_name, county_sap, service_on, feature_carried, feature_intersected)
  values ('TEST09','MECKLENBURG','060','6','I85','I485');
  insert into features (structure_number, designation, location_type, feature_name, is_primary, created_at)
  values ('TEST09','H01','C','I85NBL', true , now()-interval '4 min') returning id into f1;
  insert into features (structure_number, designation, location_type, feature_name, is_primary, created_at)
  values ('TEST09','H02','B','I485N',  true , now()-interval '3 min') returning id into f2;
  insert into features (structure_number, designation, location_type, feature_name, is_primary, created_at)
  values ('TEST09','H03','B','I485S',  false, now()-interval '2 min') returning id into f3;
  -- the second carried roadway, established last, exactly as 590819's report numbers it
  insert into features (structure_number, designation, location_type, feature_name, is_primary, created_at)
  values ('TEST09','H04','C','I85SBL', false, now()-interval '1 min') returning id into f4;

  begin
    insert into features (structure_number, designation, location_type, feature_name, is_primary)
    values ('TEST09','H09','C','ANOTHER PRIMARY', true);
    r := r || 'FAIL  a second primary carried feature was accepted'::text;
  exception when unique_violation then
    r := r || 'PASS  only one primary carried roadway per structure'::text;
  end;

  perform renumber_features('TEST09');
  select string_agg(designation||' '||location_type, ' ' order by feature_seq) into v
    from features where structure_number='TEST09';
  r := r || format('%s  carried first, then primary below, then the rest: %s',
        case when v='H01 C H02 C H03 B H04 B' then 'PASS' else 'FAIL' end, v);
  select designation into v from features where id=f4;
  r := r || format('%s  the second carried roadway moved ahead of the roads beneath: H04 -> %s',
        case when v='H02' then 'PASS' else 'FAIL' end, v);
  select designation into v from features where id=f2;
  r := r || format('%s  the primary below feature follows the carried ones: %s',
        case when v='H03' then 'PASS' else 'FAIL' end, v);

  insert into feature_routes (feature_id, route_designation, route_number, route_direction, reported_seq)
  values (f1,'R01','I85NBL','NB',1), (f2,'R01','485','NB',2), (f3,'R01','485','SB',3), (f4,'R01','I85SBL','SB',5);
  select count(*) into cnt from feature_routes where route_designation='R01';
  r := r || format('%s  every feature starts at R01: %s do', case when cnt=4 then 'PASS' else 'FAIL' end, cnt);
  begin
    insert into feature_routes (feature_id, route_designation) values (f1,'R01');
    r := r || 'FAIL  a duplicate designation inside one feature was accepted'::text;
  exception when unique_violation then
    r := r || 'PASS  a designation is unique inside its feature'::text;
  end;
  begin
    insert into feature_routes (feature_id, route_designation) values (f1,'1');
    r := r || 'FAIL  a malformed route designation was accepted'::text;
  exception when check_violation then
    r := r || 'PASS  a malformed route designation is refused'::text;
  end;
  select count(*) into cnt from check_designation_rules('TEST09') where rule_id='ROUTE_DESIGNATION_CONTINUOUS';
  r := r || format('%s  designations that ran on across features are reported: %s',
        case when cnt=3 then 'PASS' else 'FAIL' end, cnt);

  update feature_routes set lrs_route_id='10000077060' where feature_id=f1;
  insert into feature_routes (feature_id, route_designation, route_number, lrs_route_id)
  values (f1,'R02','US21 NBL','20000021060');
  select count(*) into cnt from feature_routes where feature_id=f1;
  r := r || format('%s  two co-signed routes live under one feature: %s route records, 1 feature',
        case when cnt=2 then 'PASS' else 'FAIL' end, cnt);
  select count(*) into cnt from check_designation_rules('TEST09') where rule_id='CONCURRENCY_SPLIT';
  r := r || format('%s  ...and that is not reported as a split: %s', case when cnt=0 then 'PASS' else 'FAIL' end, cnt);
  update feature_routes set lrs_route_id='10000077060' where feature_id=f4;
  select count(*) into cnt from check_designation_rules('TEST09') where rule_id='CONCURRENCY_SPLIT';
  r := r || format('%s  but one roadway split across two features IS: %s', case when cnt>0 then 'PASS' else 'FAIL' end, cnt);

  insert into structures (structure_number, county_name, county_sap, service_on) values ('TEST09B','MECKLENBURG','060','1');
  insert into structure_twins (structure_number, twin_number, separation_ft, carried_route, twin_route)
  values ('TEST09','TEST09B',51.0,'30000051060','30400051060'),
         ('TEST09B','TEST09',51.0,'30400051060','30000051060');
  select count(*) into cnt from structure_twins where 'TEST09' in (structure_number, twin_number);
  r := r || format('%s  a sister pair is recorded on both rows: %s', case when cnt=2 then 'PASS' else 'FAIL' end, cnt);
  begin
    insert into structure_twins (structure_number, twin_number) values ('TEST09','TEST09');
    r := r || 'FAIL  a structure was allowed to be its own twin'::text;
  exception when check_violation then
    r := r || 'PASS  a structure cannot be its own twin'::text;
  end;

  select count(*) into cnt from information_schema.role_table_grants
   where table_name='structure_twins' and grantee in ('anon','authenticated') and privilege_type <> 'SELECT';
  r := r || format('%s  no client may write the twin table: %s non-select grants',
        case when cnt=0 then 'PASS' else 'FAIL' end, cnt);

  raise exception E'BLOCK 4 - FEATURES, ROUTES AND TWINS (rolled back)\n%', array_to_string(r, E'\n');
end $$;
