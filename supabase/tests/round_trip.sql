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
  perform set_config('request.jwt.claims',
    json_build_object('sub',uid,'role','authenticated','email','michael.craig@strinteg.test',
                      'user_metadata', json_build_object('full_name','M. Craig'))::text, true);
  execute 'set local role authenticated';

  -- identity is taken from the token, not from the request body
  begin
    insert into feature_values (feature_id, field, source, value_num, actor, reviewer_name, note)
    values (fid,'BH07','REVIEWED',0.240,
            '99999999-9999-9999-9999-999999999999','Somebody Else','Div 10 confirmed');
    select actor, reviewer_name into got, t
      from feature_values where feature_id=fid and field='BH07' and source='REVIEWED';
    r := r || format('%s  a forged actor and name are overwritten from the token: ...%s / "%s"',
          case when got=uid and t='M. Craig' then 'PASS' else 'FAIL' end, right(got::text,12), t);
  exception when others then r := r || ('FAIL  reviewer could not write: '||sqlerrm)::text; end;

  begin
    insert into feature_values (feature_id, field, source, value_text, derivation_method, confidence)
    values (fid,'BH06','DERIVED','40401138060','nearest carried route','high');
    r := r || 'PASS  a reviewer can write DERIVED - Fill missing runs client-side'::text;
  exception when others then r := r || ('FAIL  DERIVED refused: '||sqlerrm)::text; end;

  begin
    insert into feature_values (feature_id, field, source, value_num, derivation_method, confidence)
    values (fid,'BH07','DERIVED',0.231,'re-derive','medium')
    on conflict (feature_id, field, source) do update set value_num=excluded.value_num;
    r := r || 'PASS  a reviewer can upsert DERIVED'::text;
  exception when others then r := r || ('FAIL  DERIVED upsert refused: '||sqlerrm)::text; end;

  begin
    insert into features (structure_number, designation, location_type, derivation_method, confidence)
    values ('TEST01','H02','C','derived from carried text','medium');
    r := r || 'PASS  a reviewer can upsert a feature'::text;
  exception when others then r := r || ('FAIL  feature insert refused: '||sqlerrm)::text; end;

  begin
    insert into review (feature_id, status, note, reviewer_name)
    values (fid,'progress','checking with Div 10','Totally Made Up');
    r := r || 'PASS  a reviewer can set a status and leave a note'::text;
  exception when others then r := r || ('FAIL  review write refused: '||sqlerrm)::text; end;

  begin
    insert into cleared_findings (feature_id, rule_id, action, reason, reviewer_name)
    values (fid,'BH06_3_HPMS','clear','Ramp - HPMS carries none','Totally Made Up');
    r := r || 'PASS  a reviewer can clear a finding'::text;
  exception when others then r := r || ('FAIL  clear refused: '||sqlerrm)::text; end;

  select reviewer_name into t from review where feature_id=fid;
  r := r || format('%s  review is stamped from the token too, not from the body: "%s"',
        case when t='M. Craig' then 'PASS' else 'FAIL' end, t);

  -- PUBLISHED belongs to ingest, in both directions
  begin
    insert into feature_values (feature_id, field, source, value_text)
    values (fid,'BH06','PUBLISHED','99999999999');
    r := r || 'FAIL  a reviewer inserted PUBLISHED'::text;
  exception when others then r := r || 'PASS  a reviewer cannot insert PUBLISHED'::text; end;

  update feature_values set value_text='99999999999'
   where feature_id=fid and field='BH06' and source='PUBLISHED';
  get diagnostics hit = row_count;
  select value_text into t from feature_values
   where feature_id=fid and field='BH06' and source='PUBLISHED';
  r := r || format('%s  a PUBLISHED row is invisible to a client UPDATE: %s rows hit, still %s',
        case when hit=0 and t='40401138060' then 'PASS' else 'FAIL' end, hit, t);

  -- nothing is removed, by any client role
  begin
    delete from feature_values where feature_id=fid and source='REVIEWED';
    r := r || 'FAIL  a reviewer deleted a value'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  DELETE on feature_values is not granted to a reviewer'::text;
  when others then r := r || ('PASS  delete refused: '||sqlerrm)::text; end;

  begin
    delete from features where id=fid;
    r := r || 'FAIL  a reviewer deleted a feature, cascading away a correction'::text;
  exception when insufficient_privilege then
    r := r || 'PASS  DELETE on features is not granted - no sideways cascade'::text;
  when others then r := r || ('PASS  feature delete refused: '||sqlerrm)::text; end;

  begin
    insert into findings (feature_id, rule_id, severity) values (fid,'FAKE','note');
    r := r || 'FAIL  a client wrote a finding'::text;
  exception when others then r := r || 'PASS  a client cannot write findings - validation owns those'::text; end;

  begin
    insert into review_history (table_name,row_id,operation,after)
    values ('feature_values','x','INSERT','{}'::jsonb);
    r := r || 'FAIL  a client forged an audit entry'::text;
  exception when others then r := r || 'PASS  a client cannot forge an audit entry'::text; end;

  -- withdrawal is the client path, and it leaves the row behind
  update feature_values set withdrawn_at=now()
   where feature_id=fid and field='BH07' and source='REVIEWED';
  get diagnostics hit = row_count;
  select bh07, bh07_source into n, s from feature_resolved where feature_id=fid;
  select count(*), min(withdrawn_by::text)::uuid into cnt, got from feature_values
   where feature_id=fid and field='BH07' and source='REVIEWED';
  r := r || format('%s  withdrawal falls back to DERIVED and keeps the row: %s marked, now %s from %s, row kept by ...%s',
        case when hit=1 and n=0.231 and s='DERIVED' and cnt=1 and got=uid then 'PASS' else 'FAIL' end,
        hit, n, s, right(coalesce(got::text,'-'),12));

  begin
    update feature_values set withdrawn_at=now()
     where feature_id=fid and field='BH06' and source='DERIVED';
    r := r || 'FAIL  a DERIVED row could be withdrawn'::text;
  exception when check_violation then
    r := r || 'PASS  only a REVIEWED row can be withdrawn'::text; end;

  execute 'reset role';

  -- ------------------------------------------------------------ provenance --
  select count(*) into cnt from review_history where feature_id=fid and actor=uid;
  r := r || format('%s  every audited client write is attributed to the account: %s rows',
        case when cnt>=5 then 'PASS' else 'FAIL' end, cnt);

  -- a reviewer with no display name set must not leak an address into a public table
  perform set_config('request.jwt.claims',
    json_build_object('sub',uid2,'role','authenticated','email','jsmith@ncdot.gov')::text, true);
  execute 'set local role authenticated';
  update review set status='fixed' where feature_id=fid;
  execute 'reset role';
  select reviewer_name into t from review where feature_id=fid;
  r := r || format('%s  no display name falls back to the local part, not the address: "%s"',
        case when t='jsmith' then 'PASS' else 'FAIL' end, t);

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
  r := r || format('%s  a signed-in reviewer may still ask for a reload: %s grant',
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
