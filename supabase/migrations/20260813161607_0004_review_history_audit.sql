-- ============================================================================
-- review_history — append-only, trigger-enforced
--
-- Enforced by triggers rather than by application discipline, because the one
-- thing that must never happen is a change reaching the table while the write
-- that records it does not. Any client, any script, any hand-run statement in
-- the SQL editor lands in here. If it isn't in the history, it didn't happen.
-- ============================================================================

create table review_history (
  id           bigint generated always as identity primary key,
  table_name   text not null,
  row_id       text not null,
  feature_id   uuid references features(id) on delete set null,
  operation    text not null check (operation in ('INSERT','UPDATE','DELETE')),
  before       jsonb,
  after        jsonb,
  changed      text[],
  -- who: the account if there is a session, plus the Postgres role, which is
  -- what catches a service-key script or a statement run in the dashboard.
  actor        uuid,
  actor_role   text not null default current_user,
  occurred_at  timestamptz not null default now()
);

comment on table review_history is
  'Append-only record of every change to feature_values and review, with before/after and actor. The March submittal has to be able to answer who changed what; that cannot be reconstructed after the fact, so it is captured at write time by trigger.';
comment on column review_history.actor_role is
  'The Postgres role that made the change. Distinguishes an authenticated client from a service-key job or a statement typed into the dashboard, which auth.uid() alone cannot.';

create index review_history_feature_idx on review_history (feature_id, occurred_at desc);
create index review_history_table_idx   on review_history (table_name, occurred_at desc);
create index review_history_actor_idx   on review_history (actor, occurred_at desc);

-- History cannot be rewritten, including by whoever wrote it.
create trigger review_history_append_only
  before update or delete on review_history
  for each row execute function append_only_guard();

-- ------------------------------------------------------------------------
create or replace function log_review_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  b jsonb;
  a jsonb;
  fid uuid;
  rid text;
  chg text[];
  who uuid;
begin
  if tg_op = 'DELETE' then b := to_jsonb(old); else b := case when tg_op='UPDATE' then to_jsonb(old) end; end if;
  if tg_op <> 'DELETE' then a := to_jsonb(new); end if;

  fid := coalesce((a->>'feature_id')::uuid, (b->>'feature_id')::uuid);
  rid := coalesce(a->>'id', b->>'id', a->>'feature_id', b->>'feature_id');

  -- Which columns actually moved, so a reader is not left diffing two blobs.
  if tg_op = 'UPDATE' then
    select array_agg(key order by key) into chg
    from jsonb_each_text(a)
    where to_jsonb(old) ->> key is distinct from a ->> key;
    -- a no-op update writes nothing; the log is for changes, not for traffic
    if chg is null then return new; end if;
  end if;

  -- auth.uid() is null outside a request context (a service-key job, psql).
  -- That is not an error — actor_role carries the answer in that case.
  begin
    who := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  exception when others then who := null;
  end;
  if who is null then
    begin
      who := (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
    exception when others then who := null;
    end;
  end if;
  who := coalesce(who, (a->>'actor')::uuid, (b->>'actor')::uuid);

  insert into review_history
    (table_name, row_id, feature_id, operation, before, after, changed, actor)
  values
    (tg_table_name, rid, fid, tg_op, b, a, chg, who);

  return case when tg_op = 'DELETE' then old else new end;
end $$;

comment on function log_review_change() is
  'Audit trigger for feature_values and review. security definer so that a client which may write the row still cannot write the history directly.';

create trigger feature_values_audit
  after insert or update or delete on feature_values
  for each row execute function log_review_change();

create trigger review_audit
  after insert or update or delete on review
  for each row execute function log_review_change();

create trigger cleared_findings_audit
  after insert on cleared_findings
  for each row execute function log_review_change();

-- review.updated_at should reflect the change, not whatever the client sent.
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger review_touch
  before update on review
  for each row execute function touch_updated_at();
