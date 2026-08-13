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

  delete from feature_values where feature_id=fid and field='BH07' and source='REVIEWED';
  select bh07, bh07_source into n, s from feature_resolved where feature_id = fid;
  r := r || format('%s  withdrawing the review falls back to derived: %s from %s',
        case when n=9.999 and s='DERIVED' then 'PASS' else 'FAIL' end, n, s);

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

  -- audit trail: 5 inserts + 1 update + 1 delete
  select count(*) into cnt from review_history where feature_id=fid and table_name='feature_values';
  r := r || format('%s  history holds one row per change: %s',
        case when cnt=7 then 'PASS' else 'FAIL' end, cnt);
  select count(*) into cnt from review_history where feature_id=fid and operation='DELETE';
  r := r || format('%s  withdrawal recorded as a DELETE with its before-image: %s',
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
-- RLS. Note that RLS FILTERS rather than raising: a denied UPDATE affects zero
-- rows and reports success. Anything written against this database has to
-- check the affected row count, not just the absence of an error.
do $$
declare
  r text[] := '{}'; fid uuid; owner_n int; anon_n int; auth_n int; rows_hit int; val numeric;
  uid uuid := '11111111-2222-3333-4444-555555555555';
begin
  insert into county_codes (sap_code, county_name) values ('060','MECKLENBURG');
  insert into structures (structure_number, county_name, county_sap) values ('TEST01','MECKLENBURG','060');
  insert into features (structure_number, designation, location_type)
  values ('TEST01','H01','C') returning id into fid;
  insert into feature_values (feature_id,field,source,value_text) values (fid,'BH06','PUBLISHED','40401138060');
  insert into feature_values (feature_id,field,source,value_num)  values (fid,'BH07','PUBLISHED',0.227);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'reviewer@strinteg.test','x',now(),now(),now());

  select count(*) into owner_n from review_history;
  execute 'set local role anon';   select count(*) into anon_n from review_history;   execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub',uid,'role','authenticated')::text, true);
  execute 'set local role authenticated'; select count(*) into auth_n from review_history; execute 'reset role';
  r := r || format('%s  audit trail: owner sees %s, anon sees %s, signed-in sees %s',
        case when owner_n=2 and anon_n=0 and auth_n=2 then 'PASS' else 'FAIL' end, owner_n, anon_n, auth_n);

  execute 'set local role anon'; select count(*) into anon_n from feature_values; execute 'reset role';
  r := r || format('%s  reference data stays public: anon sees %s feature_values rows',
        case when anon_n=2 then 'PASS' else 'FAIL' end, anon_n);

  execute 'set local role anon';
  update feature_values set value_num=1.0 where feature_id=fid and field='BH07';
  get diagnostics rows_hit = row_count;
  execute 'reset role';
  select value_num into val from feature_values where feature_id=fid and field='BH07' and source='PUBLISHED';
  r := r || format('%s  anon UPDATE touched %s rows; value still %s',
        case when rows_hit=0 and val=0.227 then 'PASS' else 'FAIL' end, rows_hit, val);

  execute 'set local role anon';
  delete from feature_values where feature_id=fid;
  get diagnostics rows_hit = row_count;
  execute 'reset role';
  select count(*) into rows_hit from feature_values where feature_id=fid;
  r := r || format('%s  anon DELETE removed nothing; %s rows remain',
        case when rows_hit=2 then 'PASS' else 'FAIL' end, rows_hit);

  execute 'set local role anon';
  begin
    insert into structures (structure_number) values ('HACK01');
    r := r || 'FAIL  anon wrote to the published inventory'::text;
  exception when others then r := r || 'PASS  anon cannot write the published inventory'::text; end;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub',uid,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into feature_values (feature_id,field,source,value_num,actor,reviewer_name)
    values (fid,'BH07','REVIEWED',0.240,uid,'M. Craig');
    r := r || 'PASS  a signed-in reviewer can write a REVIEWED correction'::text;
  exception when others then r := r || ('FAIL  signed-in reviewer blocked: '||sqlerrm)::text; end;
  begin
    insert into feature_values (feature_id,field,source,value_text,actor)
    values (fid,'BH06','PUBLISHED','99999999999',uid);
    r := r || 'FAIL  a reviewer wrote a PUBLISHED value'::text;
  exception when others then r := r || 'PASS  a reviewer cannot write PUBLISHED - ingest owns that'::text; end;
  begin
    insert into feature_values (feature_id,field,source,value_num,actor)
    values (fid,'BH07','DERIVED',1.5,uid);
    r := r || 'FAIL  a reviewer wrote a DERIVED value'::text;
  exception when others then r := r || 'PASS  a reviewer cannot write DERIVED - the derive pass owns that'::text; end;
  begin
    insert into feature_values (feature_id,field,source,value_text,actor)
    values (fid,'BH06','REVIEWED','40401138999','99999999-9999-9999-9999-999999999999');
    r := r || 'FAIL  a reviewer attributed a correction to someone else'::text;
  exception when others then r := r || 'PASS  a correction cannot be attributed to another account'::text; end;
  begin
    insert into review_history (table_name,row_id,operation,after)
    values ('feature_values','x','INSERT','{}'::jsonb);
    r := r || 'FAIL  a client forged an audit entry'::text;
  exception when others then r := r || 'PASS  a client cannot forge an audit entry'::text; end;
  begin
    insert into findings (feature_id, rule_id, severity) values (fid,'FAKE','note');
    r := r || 'FAIL  a client wrote a finding'::text;
  exception when others then r := r || 'PASS  a client cannot write findings - validation owns that'::text; end;
  execute 'reset role';

  select actor into uid from review_history
   where feature_id=fid and table_name='feature_values' order by id desc limit 1;
  r := r || format('%s  the correction was logged against the reviewer''s account: %s',
        case when uid='11111111-2222-3333-4444-555555555555' then 'PASS' else 'FAIL' end, uid);

  raise exception E'BLOCK 2 - ROW LEVEL SECURITY (rolled back)\n%', array_to_string(r, E'\n');
end $$;
