-- ============================================================================
-- Inspectors propose. Approvers accept.
--
-- Until now "signed in" was the whole of authorisation, deliberately: everyone
-- who could write could write everything, and the audit trail said who. Field
-- capture breaks that, because the point of it is that data arrives from people
-- who are not the people who decide what NCDOT is told. So there is now exactly
-- one distinction — approver or not — and it is a row in a table rather than a
-- claim in a token, so that granting and revoking it are ordinary writes with
-- an audit trail behind them.
--
-- Nothing about reading changes. Anonymous visitors still see everything,
-- including the queue, because the provenance of a public submittal is public.
-- ============================================================================

create table reviewer_roles (
  actor       uuid primary key,
  role        text not null check (role in ('inspector','approver')),
  display_name text,
  granted_at  timestamptz not null default now(),
  granted_by  uuid,
  revoked_at  timestamptz
);

comment on table reviewer_roles is
  'Who may approve what an inspector submits. Absence of a row means inspector: any signed-in account can propose. Only a live approver row lets an account promote a proposal to REVIEWED, or write a REVIEWED value directly. Revoking sets revoked_at rather than deleting, so the record of who could approve what, when, survives.';

create index reviewer_roles_live_idx on reviewer_roles (role) where revoked_at is null;

alter table reviewer_roles enable row level security;
create policy read_all on reviewer_roles for select to anon, authenticated using (true);
grant select on reviewer_roles to anon, authenticated;
-- Granting the role is not something a client does. It is a service-role write,
-- which means the dashboard or a deliberate script, which is the correct amount
-- of ceremony for "this person may decide what the state is told".

-- ---------------------------------------------------------------------------
create or replace function current_actor()
returns uuid language plpgsql stable
set search_path = public, pg_catalog as $$
declare u uuid;
begin
  begin u := nullif(current_setting('request.jwt.claim.sub', true),'')::uuid;
  exception when others then u := null; end;
  if u is null then
    begin u := (nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'sub')::uuid;
    exception when others then u := null; end;
  end if;
  return u;
end $$;

create or replace function is_approver()
returns boolean language sql stable security definer
set search_path = public, pg_catalog as $$
  select exists (
    select 1 from reviewer_roles r
     where r.actor = current_actor() and r.role = 'approver' and r.revoked_at is null)
$$;

comment on function is_approver() is
  'True where the calling account holds a live approver row. Security definer because reviewer_roles is readable but the decision must not depend on the caller''s own view of it.';

grant execute on function current_actor(), is_approver() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- The policies. PROPOSED is open to any signed-in account; REVIEWED is not.
drop policy write_review_and_derived  on feature_values;
drop policy update_review_and_derived on feature_values;

create policy propose_or_derive on feature_values
  for insert to authenticated
  with check (
    source in ('PROPOSED','DERIVED')
    or (source = 'REVIEWED' and is_approver())
  );

create policy amend_own_layer on feature_values
  for update to authenticated
  using (
    source in ('PROPOSED','DERIVED')
    or (source = 'REVIEWED' and is_approver())
  )
  with check (
    source in ('PROPOSED','DERIVED')
    or (source = 'REVIEWED' and is_approver())
  );

comment on policy propose_or_derive on feature_values is
  'Any signed-in account may record a PROPOSED value or a DERIVED one. Only an approver may write REVIEWED, which is the only source that decides anything a reviewer sees. PUBLISHED remains invisible to every client, as before.';

-- ---------------------------------------------------------------------------
-- Approval is an action with a record, not an UPDATE somebody remembers to do.
create table proposal_decisions (
  id           uuid primary key default gen_random_uuid(),
  feature_id   uuid not null references features(id) on delete cascade,
  field        snbi_field not null,
  action       text not null check (action in ('approve','reject')),
  proposed_text text,
  proposed_num  numeric,
  reason       text,
  actor        uuid,
  actor_name   text,
  decided_at   timestamptz not null default now()
);

comment on table proposal_decisions is
  'Every approval and every rejection, append-only. A rejected proposal is withdrawn rather than deleted, so "why is this not in the submittal" always has an answer with a name and a date on it.';

create index proposal_decisions_feature_idx on proposal_decisions (feature_id, field);
alter table proposal_decisions enable row level security;
create policy read_all on proposal_decisions for select to anon, authenticated using (true);
grant select on proposal_decisions to anon, authenticated;

create or replace function approve_proposal(p_feature uuid, p_field snbi_field, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare p feature_values; nm text;
begin
  if not is_approver() then
    raise exception 'Only a designated approver can accept a proposal.' using errcode='42501';
  end if;
  select * into p from feature_values
   where feature_id=p_feature and field=p_field and source='PROPOSED' and withdrawn_at is null;
  if not found then raise exception 'No open proposal for that feature and field.'; end if;

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
end $$;

create or replace function reject_proposal(p_feature uuid, p_field snbi_field, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare p feature_values;
begin
  if not is_approver() then
    raise exception 'Only a designated approver can reject a proposal.' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'A rejection needs a reason. The inspector who submitted it has to be able to read why.';
  end if;
  select * into p from feature_values
   where feature_id=p_feature and field=p_field and source='PROPOSED' and withdrawn_at is null;
  if not found then raise exception 'No open proposal for that feature and field.'; end if;

  update feature_values set withdrawn_at=now(), note=coalesce(note,'')||E'\n[rejected] '||p_reason
   where feature_id=p_feature and field=p_field and source='PROPOSED';

  insert into proposal_decisions (feature_id, field, action, proposed_text, proposed_num, reason, actor)
  values (p_feature, p_field, 'reject', p.value_text, p.value_num, p_reason, current_actor());
  return jsonb_build_object('rejected', true);
end $$;

revoke execute on function approve_proposal(uuid,snbi_field,text) from anon;
revoke execute on function reject_proposal(uuid,snbi_field,text)  from anon;
grant execute on function approve_proposal(uuid,snbi_field,text),
                          reject_proposal(uuid,snbi_field,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
create view proposal_queue
with (security_invoker = true) as
select fv.feature_id, fv.field,
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
where fv.source = 'PROPOSED' and fv.withdrawn_at is null;

comment on view proposal_queue is
  'Everything submitted from the field and not yet decided, with the published value beside it so an approver can see what is being changed without a second query.';

grant select on proposal_queue to anon, authenticated;
