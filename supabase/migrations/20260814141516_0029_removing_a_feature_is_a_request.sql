-- ============================================================================
-- An inspector can say a feature should not be there. They cannot make it so.
--
-- No client role has DELETE on any table in this schema and that does not
-- change here. A feature the inspector believes is wrong - a roadway the
-- derivation invented, a duplicate, something that was rebuilt away - is a
-- REQUEST, sitting beside the value proposals in the same queue, decided by the
-- same approvers. Accepting it withdraws the feature; withdrawn, never deleted,
-- so the record of what was reported and who removed it survives the removal.
--
-- The asymmetry is deliberate. Being wrong about a value costs one number.
-- Being wrong about whether a roadway exists costs the whole highway record for
-- it - the clearances, the traffic, everything reported beneath the bridge.
-- ============================================================================

alter table features
  add column removal_requested_at timestamptz,
  add column removal_requested_by uuid,
  add column removal_reason       text;

comment on column features.removal_requested_at is
  'Set when somebody in the field says this feature should not exist. It stays in every list and every export until an approver decides, because an unapproved opinion is not a reason to stop reporting a roadway.';

create index features_removal_open_idx on features (removal_requested_at)
  where removal_requested_at is not null and withdrawn_at is null;

-- ---------------------------------------------------------------------------
create or replace function propose_feature_removal(
  p_structure text, p_designation text, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare fid uuid;
begin
  if current_actor() is null then
    raise exception 'Sign in before asking for a feature to be removed.' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'Say why. An approver has to be able to judge it, and the record has to explain it.';
  end if;
  select id into fid from features
   where structure_number = btrim(p_structure) and designation = btrim(p_designation)
     and withdrawn_at is null;
  if fid is null then raise exception 'No live feature % on structure %', p_designation, p_structure; end if;

  update features
     set removal_requested_at = now(), removal_requested_by = current_actor(),
         removal_reason = btrim(p_reason)
   where id = fid;
  return jsonb_build_object('requested', true, 'feature_id', fid);
end $$;

create or replace function decide_feature_removal(
  p_feature uuid, p_accept boolean, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare f features;
begin
  if not is_approver() then
    raise exception 'Only a designated approver can decide whether a feature is removed.' using errcode='42501';
  end if;
  select * into f from features where id = p_feature and removal_requested_at is not null;
  if not found then raise exception 'No open removal request for that feature.'; end if;

  if p_accept then
    update features set withdrawn_at = now(), removal_requested_at = null where id = p_feature;
  else
    if coalesce(btrim(p_reason),'') = '' then
      raise exception 'A refusal needs a reason. The inspector who asked has to be able to read why.';
    end if;
    update features set removal_requested_at = null,
           removal_reason = coalesce(removal_reason,'') || E'\n[kept] ' || p_reason
     where id = p_feature;
  end if;

  insert into proposal_decisions (feature_id, field, action, proposed_text, reason, actor)
  values (p_feature, 'BH06', case when p_accept then 'approve' else 'reject' end,
          'remove feature ' || f.designation, coalesce(p_reason, f.removal_reason), current_actor());

  return jsonb_build_object('removed', p_accept, 'feature_id', p_feature);
end $$;

revoke execute on function propose_feature_removal(text,text,text) from anon;
revoke execute on function decide_feature_removal(uuid,boolean,text) from anon;
grant execute on function propose_feature_removal(text,text,text) to authenticated, service_role;
grant execute on function decide_feature_removal(uuid,boolean,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- One queue. An approver should not have to look in two places to find out what
-- is waiting on them. Dropped and recreated because the column list changes.
drop view proposal_queue;
create view proposal_queue
with (security_invoker = true) as
select fv.feature_id, fv.field, 'value'::text as kind,
       coalesce(fv.value_text, fv.value_num::text) as proposed_value,
       fv.reviewer_name as proposed_by, fv.recorded_at as proposed_at, fv.note,
       f.structure_number, f.designation, f.location_type, f.feature_name,
       s.county_name, s.division,
       coalesce(pub.value_text, pub.value_num::text) as published_value
from feature_values fv
join features f on f.id = fv.feature_id
join structures s on s.structure_number = f.structure_number
left join feature_values pub
  on pub.feature_id = fv.feature_id and pub.field = fv.field and pub.source = 'PUBLISHED'
where fv.source = 'PROPOSED' and fv.withdrawn_at is null
union all
select f.id, null::snbi_field, 'removal'::text,
       'remove ' || f.designation, null::text, f.removal_requested_at, f.removal_reason,
       f.structure_number, f.designation, f.location_type, f.feature_name,
       s.county_name, s.division, null::text
from features f
join structures s on s.structure_number = f.structure_number
where f.removal_requested_at is not null and f.withdrawn_at is null;

comment on view proposal_queue is
  'Everything waiting on an approver: proposed values, and requests to remove a feature altogether. The published value sits beside a proposed one so the change is legible without a second query.';

grant select on proposal_queue to anon, authenticated;
