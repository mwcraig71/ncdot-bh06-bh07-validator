-- ============================================================================
-- Fix: stamp_identity() was deciding "is this a client?" with current_user
-- while running SECURITY DEFINER, where current_user is the function's OWNER
-- and never the caller. So the test came back as postgres, the function
-- returned early, and a forged actor went straight through to the foreign key.
--
-- The condition should not have been about roles in the first place. What
-- actually matters is whether the request carries a user token: an ingest or a
-- back-end job legitimately writes on behalf of nobody and has no `sub`, while
-- anything with a `sub` is a person and must be stamped as that person.
-- ============================================================================

create or replace function auth_display_name()
returns text
language plpgsql
stable
security invoker                     -- reads settings only; needs no privilege
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

revoke execute on function auth_display_name() from public, anon;
grant  execute on function auth_display_name() to authenticated, service_role;

-- ---------------------------------------------------------------------------
create or replace function stamp_identity()
returns trigger
language plpgsql
security invoker                     -- so the check is about the caller, not me
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

  if tg_table_name = 'feature_values' and new.withdrawn_at is not null then
    new.withdrawn_by := uid;
  end if;

  return new;
end $$;

comment on function stamp_identity() is
  'Overwrites actor and reviewer_name from the request''s JWT. Keyed on the presence of a subject claim rather than on a role name, because a SECURITY DEFINER function cannot see who called it and a service-role job has no subject to stamp.';

revoke execute on function stamp_identity() from public, anon, authenticated;
