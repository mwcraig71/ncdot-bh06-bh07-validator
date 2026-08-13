-- ============================================================================
-- The first statewide bridge load hit the 8s statement timeout on a 2,000-row
-- batch. Two causes, both worth fixing rather than papering over with a smaller
-- page size.
--
-- 1. A PUBLISHED INSERT was writing a review_history row. On a first load that
--    is ~34,000 audit rows saying "NCDOT publishes a value here", which is not
--    news: feature_values.ingest_run_id already records which load wrote it,
--    and ingest_runs records what that load was and when. The audit trail
--    exists to answer who CHANGED something. So a first-time PUBLISHED insert
--    is no longer audited — while every UPDATE and DELETE of a published value
--    still is, because those are changes to something that already existed, and
--    those are exactly what a divergence is made of.
--
--    Nothing about review auditing changes: every REVIEWED and DERIVED write,
--    of any kind, is still recorded in full.
--
-- 2. service_role inherited the 8s timeout meant for interactive requests. It
--    is the role a scheduled back-end job runs as; a batch upsert is not an
--    interactive request and should not be held to an interactive limit.
-- ============================================================================

create or replace function log_review_change()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  b jsonb; a jsonb; fid uuid; rid text; chg text[]; who uuid;
begin
  -- A published value appearing for the first time is not a change to anything.
  -- Its provenance is ingest_run_id, and its arrival is the ingest_runs row.
  if tg_op = 'INSERT' and tg_table_name = 'feature_values'
     and new.source = 'PUBLISHED' then
    return new;
  end if;

  if tg_op = 'DELETE' then b := to_jsonb(old); else b := case when tg_op='UPDATE' then to_jsonb(old) end; end if;
  if tg_op <> 'DELETE' then a := to_jsonb(new); end if;

  fid := coalesce((a->>'feature_id')::uuid, (b->>'feature_id')::uuid);
  rid := coalesce(a->>'id', b->>'id', a->>'feature_id', b->>'feature_id');

  if tg_op = 'UPDATE' then
    select array_agg(key order by key) into chg
    from jsonb_each_text(a)
    where to_jsonb(old) ->> key is distinct from a ->> key;
    if chg is null then return new; end if;
    -- recorded_at moves on every republish even when the value has not; that is
    -- traffic, not a change worth a row
    if chg = array['recorded_at'] then return new; end if;
  end if;

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

-- The ingest role is not an interactive client.
alter role service_role set statement_timeout = '240s';

-- Supporting index for the "published value has gone away" delete, which scans
-- by feature and source on every batch.
create index if not exists feature_values_pub_idx
  on feature_values (feature_id, field) where source = 'PUBLISHED';
