-- ============================================================================
-- Function hardening, from the database linter.
-- ============================================================================

-- A trigger function with a mutable search_path can be pointed at a different
-- schema by whoever calls it, and resolve its inserts somewhere else. Pinned.
alter function public.feature_values_source_is_immutable()  set search_path = public, pg_catalog;
alter function public.append_only_guard()                   set search_path = public, pg_catalog;
alter function public.touch_updated_at()                    set search_path = public, pg_catalog;
alter function public.log_review_change()                   set search_path = public, extensions, pg_catalog;

-- PostgREST publishes anything executable in the API schema as an RPC
-- endpoint. log_review_change is SECURITY DEFINER, so as it stood a client
-- could POST to /rest/v1/rpc/log_review_change and write the audit trail
-- directly — forging exactly the record the trail exists to protect. These are
-- trigger functions; nothing but the trigger machinery should reach them.
revoke execute on function public.log_review_change()                  from public, anon, authenticated;
revoke execute on function public.append_only_guard()                  from public, anon, authenticated;
revoke execute on function public.feature_values_source_is_immutable() from public, anon, authenticated;
revoke execute on function public.touch_updated_at()                   from public, anon, authenticated;
