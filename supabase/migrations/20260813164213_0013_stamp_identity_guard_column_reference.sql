-- ============================================================================
-- Fix: stamp_identity() referenced new.withdrawn_at inside a compound
-- condition. plpgsql resolves every field in the expression when it plans it,
-- regardless of whether the left-hand test would have short-circuited, so on
-- `review` and `cleared_findings` — which have no such column — the trigger
-- raised 42703 and the write failed outright.
--
-- The effect was that a signed-in reviewer could correct a value but could not
-- set a status, leave a note, or clear a finding. Nesting the reference behind
-- its own IF is the whole fix.
-- ============================================================================

create or replace function stamp_identity()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $$
declare c jsonb; uid uuid;
begin
  begin
    c := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then c := null;
  end;

  -- No user token: an ingest, a derive job, a migration, psql. These write on
  -- behalf of nobody and say so by leaving actor null.
  if c is null or (c ->> 'sub') is null then
    return new;
  end if;

  begin
    uid := (c ->> 'sub')::uuid;
  exception when others then
    raise exception 'Request carries an unreadable subject claim; % cannot be written.', tg_table_name;
  end;

  -- Overwritten, not validated. A check can only reject a wrong name; this
  -- means a wrong one cannot be submitted at all.
  new.actor         := uid;
  new.reviewer_name := auth_display_name();

  -- Nested, not conjoined: the field must not appear in an expression that is
  -- planned for a table which does not have it.
  if tg_table_name = 'feature_values' then
    if new.withdrawn_at is not null then
      new.withdrawn_by := uid;
    end if;
  end if;

  return new;
end $$;

revoke execute on function stamp_identity() from public, anon, authenticated;
