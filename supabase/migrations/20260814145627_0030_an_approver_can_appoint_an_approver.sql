-- ============================================================================
-- An approver can appoint another approver, and that is a written act.
--
-- Until now the role was granted only with the service key, from the Supabase
-- dashboard or a deliberate script. That is the right amount of ceremony for
-- the first one and the wrong amount for the ninth: it puts a database
-- credential in the path of an ordinary staffing decision, and in practice it
-- means the person who holds the key becomes a bottleneck nobody planned for.
--
-- So a live approver may now grant and revoke, from the tool, and every grant
-- and every revocation is a row with a name, a date and a granter on it. Two
-- guards make that safe enough to be worth it:
--
--   * You are appointed BY EMAIL, and only if that account has already signed
--     in. There is no way to create an account here, so granting cannot invent
--     a person - it can only promote one who already exists.
--   * The last live approver cannot be revoked. Not by themselves, not by
--     anyone. An empty approver table is unrecoverable from inside the tool,
--     and a queue nobody can decide is worse than an approver nobody wanted.
--
-- What is still not possible from a client: writing PUBLISHED, deleting
-- anything, or granting yourself the role. The first grant remains a service
-- role write, because somebody has to be trusted first and it should not be
-- whoever signs in first.
-- ============================================================================

alter table reviewer_roles
  add column revoked_by    uuid,
  add column revoke_reason text;

comment on column reviewer_roles.revoked_by is
  'Who took the role away. Revocation sets a date rather than deleting the row, so "who could approve what, when" answers itself for any date in the past.';

-- ---------------------------------------------------------------------------
-- The caller's JWT role, read before the definer context swaps current_user.
-- This is how the service key is recognised: inside a security definer function
-- current_user is the owner and session_user is the authenticator, so neither
-- says anything about who called.
create or replace function jwt_role()
returns text language plpgsql stable
set search_path = public, pg_catalog as $$
declare r text;
begin
  begin r := nullif(current_setting('request.jwt.claim.role', true),'');
  exception when others then r := null; end;
  if r is null then
    begin r := (nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role');
    exception when others then r := null; end;
  end if;
  return r;
end $$;

grant execute on function jwt_role() to anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function grant_approver(p_email text, p_display_name text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare u uuid; em text; nm text;
begin
  if not is_approver() and coalesce(jwt_role(),'') <> 'service_role' then
    raise exception 'Only a designated approver can appoint another approver.' using errcode='42501';
  end if;

  em := lower(btrim(coalesce(p_email,'')));
  if em = '' or em not like '%@%' then
    raise exception 'Give the work email address of the account to appoint.';
  end if;

  select id into u from auth.users where lower(email) = em;
  if u is null then
    raise exception 'No account for %. They have to sign in once before they can be appointed - the sign-in is what creates the account, and appointing cannot create a person.', em;
  end if;

  nm := coalesce(nullif(btrim(coalesce(p_display_name,'')),''), split_part(em,'@',1));

  insert into reviewer_roles (actor, role, display_name, granted_at, granted_by,
                              revoked_at, revoked_by, revoke_reason)
  values (u, 'approver', nm, now(), current_actor(), null, null, null)
  on conflict (actor) do update
    set role = 'approver', display_name = coalesce(excluded.display_name, reviewer_roles.display_name),
        granted_at = now(), granted_by = current_actor(),
        revoked_at = null, revoked_by = null, revoke_reason = null;

  return jsonb_build_object('granted', true, 'actor', u, 'display_name', nm);
end $$;

comment on function grant_approver(text,text) is
  'Appoint an existing account as an approver, by email. Refuses if the account has never signed in, because an appointment should not be able to invent a person. Callable by a live approver, or with the service key for the first one.';

-- ---------------------------------------------------------------------------
create or replace function revoke_approver(p_actor uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare live int;
begin
  if not is_approver() and coalesce(jwt_role(),'') <> 'service_role' then
    raise exception 'Only a designated approver can revoke another approver.' using errcode='42501';
  end if;

  select count(*) into live from reviewer_roles
   where role = 'approver' and revoked_at is null;

  if live <= 1 then
    raise exception 'That is the last approver. Appoint somebody else first - with nobody able to decide, every submission from the field stops at the queue.';
  end if;

  update reviewer_roles
     set revoked_at = now(), revoked_by = current_actor(),
         revoke_reason = nullif(btrim(coalesce(p_reason,'')),'')
   where actor = p_actor and role = 'approver' and revoked_at is null;

  if not found then raise exception 'That account does not currently hold the approver role.'; end if;
  return jsonb_build_object('revoked', true, 'actor', p_actor);
end $$;

comment on function revoke_approver(uuid,text) is
  'Take the approver role away. Sets a date rather than deleting the row. Refuses to remove the last live approver, from any caller including the service key, because an empty approver table cannot be repaired from inside the tool.';

revoke execute on function grant_approver(text,text)   from anon;
revoke execute on function revoke_approver(uuid,text)  from anon;
grant  execute on function grant_approver(text,text)   to authenticated, service_role;
grant  execute on function revoke_approver(uuid,text)  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Who holds it, readable by anyone, and carrying no email addresses. The
-- provenance of a public submittal is public; the address somebody signs in
-- with is not, and this view is what the tool draws.
create view approver_directory
with (security_invoker = true) as
select r.actor, r.display_name, r.granted_at, r.revoked_at, r.revoke_reason,
       g.display_name as granted_by_name,
       v.display_name as revoked_by_name,
       (select count(*) from proposal_decisions d where d.actor = r.actor) as decisions
from reviewer_roles r
left join reviewer_roles g on g.actor = r.granted_by
left join reviewer_roles v on v.actor = r.revoked_by
where r.role = 'approver';

comment on view approver_directory is
  'Every approver appointment, live and revoked, with who appointed them and how many decisions they have made. Deliberately carries no email address: the display name is the account name or the part before the @, because this view is drawn on a page anyone can open.';

grant select on approver_directory to anon, authenticated;
