-- ============================================================================
-- Detour length, as measured.
--
-- Two measurements per structure, from a routing graph built on OpenStreetMap,
-- never on NCDOT's coded value:
--
--   bypass   the road ON the bridge. The deck is blocked; the road beneath
--            stays open, so a detour may drop down, pass under and come back.
--   collapse a road UNDER the bridge. The ground beneath the span is blocked;
--            the deck stays open, so a detour may cross on the bridge where a
--            ramp connects the two. One row per roadway direction beneath.
--
-- Minimum distance only. No bridge on a detour is checked for clearance,
-- posting or width.
--
-- This is NOT B.H.17. B.H.17 is NCDOT's published coded item for the carried
-- route and stays where it is published. Keeping the measurement separate is
-- what lets the two disagree visibly instead of one silently replacing the
-- other. The collapse detour has no SNBI item at all.
--
-- A row whose verdict is not 'ok' or 'bypass_at_site' carries no distance, by
-- construction: an UNMEASURED structure must never be rendered as a number.
-- ============================================================================

create table detour_measured (
  brdg_nbr      text     not null,
  mode          text     not null check (mode in ('bypass','collapse')),
  seq           smallint not null default 0,
  road          text,
  heading       smallint,
  verdict       text     not null check (verdict in
                  ('ok','bypass_at_site','no_detour','unmeasured','none_beneath')),
  around_mi     numeric(8,3),
  direct_mi     numeric(8,3),
  additional_mi numeric(8,3),
  probe_mi      numeric(6,2),
  reason        text,
  width_assumed boolean  not null default false,
  deck_inferred boolean  not null default false,
  graph_vintage text     not null,
  run_id        bigint,
  measured_at   timestamptz not null default now(),
  primary key (brdg_nbr, mode, seq),
  -- a distance exists exactly when the measurement succeeded
  constraint detour_distance_only_when_measured check (
    (verdict in ('ok','bypass_at_site')) = (around_mi is not null and direct_mi is not null)
  ),
  -- and anything that is not a distance says why
  constraint detour_reason_when_not_measured check (
    verdict in ('ok','bypass_at_site') or reason is not null
  )
);

comment on table detour_measured is
  'As-measured detour length per structure: bypass = road on the bridge with the deck blocked; collapse = road beneath with the ground under the span blocked. Derived from an OSM routing graph, graph_vintage names it. Not B.H.17.';
comment on column detour_measured.additional_mi is
  'around_mi - direct_mi: the extra travel the closure costs. around_mi is the path length itself, from one side to the other.';
comment on column detour_measured.probe_mi is
  'How far out along the road the anchors had to go before a way around existed. On a freeway this is the distance back to the nearest point traffic can actually leave.';
comment on column detour_measured.width_assumed is
  'True where NCDOT publishes no deck width and 30 ft was used to size the footprint. Affects which lanes beneath were blocked, so it is recorded rather than hidden.';

comment on column detour_measured.deck_inferred is
  'True where the map has the carried road but does not tag the bridge on it - common for small creek crossings. The nearest road segment was blocked instead; with no junction between the bridge and the segment ends that is the same closure. Never inferred where NCDOT records a highway beneath, because there the nearest road may be the one underneath.';

create index detour_measured_verdict_idx on detour_measured (mode, verdict);

alter table detour_measured enable row level security;
create policy read_all on detour_measured for select to anon, authenticated using (true);
grant select on detour_measured to anon, authenticated;

-- ---------------------------------------------------------------------------
-- The write path. Gated by the same database-owned token as every other
-- ingest (migration 0017), because the measurement runs outside the database
-- and has to reach it through the API.
--
-- A batch replaces whole structures: every row for a structure in the batch
-- is deleted, then the batch's rows inserted. A re-run that finds fewer roads
-- beneath therefore cannot leave a stale row behind.
create or replace function ingest_detour(p jsonb, p_token text)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  if p_token is null or p_token is distinct from (select token from ingest_secret where id = 1) then
    raise exception 'not authorised to load detour measurements' using errcode = '42501';
  end if;

  delete from detour_measured d
   where d.brdg_nbr in (select distinct x.brdg_nbr
                          from jsonb_to_recordset(p) as x(brdg_nbr text));

  insert into detour_measured (brdg_nbr, mode, seq, road, heading, verdict, around_mi,
                               direct_mi, additional_mi, probe_mi, reason,
                               width_assumed, deck_inferred, graph_vintage, run_id)
  select x.brdg_nbr, x.mode, x.seq, x.road, x.heading, x.verdict, x.around_mi,
         x.direct_mi, x.additional_mi, x.probe_mi, x.reason,
         coalesce(x.width_assumed,false), coalesce(x.deck_inferred,false), x.graph_vintage, x.run_id
    from jsonb_to_recordset(p) as x(brdg_nbr text, mode text, seq smallint, road text,
         heading smallint, verdict text, around_mi numeric, direct_mi numeric,
         additional_mi numeric, probe_mi numeric, reason text, width_assumed boolean,
         deck_inferred boolean, graph_vintage text, run_id bigint);
  get diagnostics n = row_count;
  return n;
end $$;

-- Revoke from PUBLIC, which is what grants it by default (see 0031), then
-- state who may call it. The token, not the role, is what admits a caller.
revoke execute on function ingest_detour(jsonb, text) from public;
grant  execute on function ingest_detour(jsonb, text) to anon, authenticated;

comment on function ingest_detour(jsonb, text) is
  'Load as-measured detour rows. Requires the ingest_secret token. Close it after a statewide run by revoking execute from anon, authenticated.';
