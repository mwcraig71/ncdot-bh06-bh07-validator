-- ============================================================================
-- What a phone calls.
--
-- The field app knows a bridge number, a feature designation and a number. It
-- does not know feature UUIDs, and it should not have to: a hand-held device on
-- a bad connection wants one call that either works or can be retried, not a
-- lookup followed by an insert that can half-succeed.
--
-- It can also create the feature. An inspector standing under a roadway nobody
-- recorded is the only source that roadway will ever have, and refusing it
-- because there is no row yet would lose exactly the observation worth having.
-- A feature created this way is marked as such and its values are PROPOSED, so
-- nothing it says reaches a check or an export before an approver sees it.
-- ============================================================================
create or replace function propose_value(
  p_structure   text,
  p_designation text,
  p_field       snbi_field,
  p_value       text,
  p_note        text default null,
  p_location    feature_location default 'B',
  p_name        text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_catalog
as $$
declare fid uuid; created boolean := false; nm text; num numeric;
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
end $$;

comment on function propose_value(text,text,snbi_field,text,text,feature_location,text) is
  'One call from a hand-held device: identify the feature by bridge number and designation, create it if the inspector found something nobody had recorded, and record the value as PROPOSED. Idempotent on re-submission, because a phone on a bad connection will retry.';

revoke execute on function propose_value(text,text,snbi_field,text,text,feature_location,text) from anon;
grant  execute on function propose_value(text,text,snbi_field,text,text,feature_location,text)
  to authenticated, service_role;
