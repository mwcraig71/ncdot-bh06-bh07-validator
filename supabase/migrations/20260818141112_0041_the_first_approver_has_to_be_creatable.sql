-- ============================================================================
-- Bootstrapping the first approver was impossible. Checked, not assumed:
--
--   select jwt_role(), is_approver();   -- in the SQL editor
--   -> null, false
--
-- grant_approver() admits a live approver or the service_role JWT, and a direct
-- database session is neither: PostgREST is what sets request.jwt.claims, so a
-- session that did not arrive through PostgREST has no claims at all. With zero
-- approvers in the table and no way to make one, the queue had no possible
-- first decider - the one state the whole design cannot recover from.
--
-- So a THIRD caller is admitted: a session with no JWT whatsoever. That is not
-- a weakening. Every browser request carries a role claim - 'anon' for a
-- signed-out visitor, 'authenticated' for a signed-in one - so no client can
-- present an absent claim. jwt_role() IS NULL means psql, the SQL editor, or a
-- migration: somebody holding the database's own credentials, who could write
-- the row by hand regardless. Naming it in the function is better than leaving
-- the only route a manual INSERT that bypasses the checks on the email.
-- ============================================================================

create or replace function grant_approver(p_email text, p_display_name text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare u uuid; em text; nm text; direct boolean;
begin
  -- No claims at all: not a browser. See the note above.
  direct := jwt_role() is null;

  if not is_approver() and coalesce(jwt_role(),'') <> 'service_role' and not direct then
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

  return jsonb_build_object('granted', true, 'actor', u, 'display_name', nm,
                            'bootstrap', direct and current_actor() is null);
end $$;

comment on function grant_approver(text,text) is
  'Appoint an existing account as an approver, by email. Refuses if the account has never signed in, because an appointment should not be able to invent a person. Callable by a live approver, by the service key, or from a direct database session - which is how the FIRST one is created, since a browser can never present an absent JWT claim.';

revoke execute on function grant_approver(text, text) from public;
grant  execute on function grant_approver(text, text) to authenticated, service_role;
