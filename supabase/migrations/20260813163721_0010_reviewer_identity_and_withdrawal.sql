-- ============================================================================
-- Reviewer identity, and withdrawal without deletion
--
-- Two changes, both about the same thing: a claim about who did what should not
-- be something a client can assert.
--
-- 1. actor and reviewer_name are stamped from the JWT by trigger, not accepted
--    from the request body. RLS could already stop a client writing someone
--    else's uuid, but nothing stopped it writing someone else's NAME, and the
--    name is what a person reads in an export. Now neither is typed in.
--
-- 2. Withdrawing a correction was a DELETE. Nothing is removed any more, so it
--    becomes withdrawn_at: the row and its history stay, and resolution skips
--    it. A withdrawal is then itself an auditable event rather than a gap.
-- ============================================================================

-- ------------------------------------------------------------- withdrawal ---
alter table feature_values
  add column withdrawn_at timestamptz,
  add column withdrawn_by uuid references auth.users(id);

comment on column feature_values.withdrawn_at is
  'Set when a reviewer takes a correction back. The row stays, with its history; resolution ignores it and the feature falls back to the next source down. Withdrawal is a change, not an absence, so it has to leave a trace.';

-- Only a review can be withdrawn. A PUBLISHED row that has gone away upstream
-- is the ingest''s business, and a DERIVED row is replaced by re-deriving.
alter table feature_values
  add constraint feature_values_only_reviews_withdraw
  check (withdrawn_at is null or source = 'REVIEWED');

create index feature_values_live_idx
  on feature_values (feature_id, field, source)
  where withdrawn_at is null;

-- --------------------------------------------------------------- identity ---
-- The reviewer's display name, from the JWT rather than from a text box.
-- Prefers a name they have set; falls back to the local part of the email
-- rather than the whole address, because reviewer_name ends up in exports and
-- on a public page, and an email address does not need to be in either.
create or replace function auth_display_name()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare c jsonb; nm text; em text;
begin
  begin
    c := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then return null;
  end;
  if c is null then return null; end if;

  nm := coalesce(
          c -> 'user_metadata' ->> 'full_name',
          c -> 'user_metadata' ->> 'name',
          c -> 'app_metadata'  ->> 'full_name');
  if nm is not null and btrim(nm) <> '' then return btrim(nm); end if;

  em := coalesce(c ->> 'email', c -> 'user_metadata' ->> 'email');
  if em is not null and position('@' in em) > 1 then
    return split_part(em, '@', 1);
  end if;
  return em;
end $$;

comment on function auth_display_name() is
  'Display name for the current session, from the JWT. Falls back to the local part of the email, never the full address — reviewer_name is readable on a public page.';

revoke execute on function auth_display_name() from public, anon;

-- ---------------------------------------------------------------------------
-- Stamp identity on the way in. Applies to client roles only: an ingest or a
-- back-end job running as the service role legitimately writes rows on behalf
-- of nobody, and gets left alone.
create or replace function stamp_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare uid uuid;
begin
  if current_user <> 'authenticated' then
    return new;                      -- service_role, postgres: ingest and jobs
  end if;

  begin
    uid := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  exception when others then uid := null;
  end;
  if uid is null then
    begin
      uid := ((nullif(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'sub')::uuid;
    exception when others then uid := null;
    end;
  end if;

  if uid is null then
    raise exception 'No authenticated identity on this request. % cannot be written without one.',
      tg_table_name;
  end if;

  -- Overwritten, not validated: whatever the client sent is discarded.
  new.actor         := uid;
  new.reviewer_name := auth_display_name();

  if tg_table_name = 'feature_values' and new.withdrawn_at is not null then
    new.withdrawn_by := uid;
  end if;

  return new;
end $$;

comment on function stamp_identity() is
  'Overwrites actor and reviewer_name from the JWT for client writes. Provenance is therefore asserted by the token, not by the request body — a reviewer cannot sign someone else''s name to a correction.';

revoke execute on function stamp_identity() from public, anon, authenticated;

create trigger feature_values_stamp
  before insert or update on feature_values
  for each row execute function stamp_identity();

create trigger review_stamp
  before insert or update on review
  for each row execute function stamp_identity();

create trigger cleared_findings_stamp
  before insert on cleared_findings
  for each row execute function stamp_identity();

-- ---------------------------------------------------------------------------
-- Resolution skips withdrawn rows. This is the only place that needed to
-- change: everything downstream reads the view.
create or replace view feature_value_resolved
with (security_invoker = true) as
select distinct on (fv.feature_id, fv.field)
  fv.feature_id,
  fv.field,
  fv.source,
  fv.value_text,
  fv.value_num,
  fv.confidence,
  fv.derivation_method,
  fv.offset_ft,
  fv.reviewer_name,
  fv.actor,
  fv.note,
  fv.ingest_run_id,
  fv.recorded_at
from feature_values fv
where fv.withdrawn_at is null
order by fv.feature_id, fv.field, fv.source desc;

comment on view feature_value_resolved is
  'The winning live row per (feature, field). Withdrawn corrections are skipped, so a feature falls back to the next source down on its own.';
