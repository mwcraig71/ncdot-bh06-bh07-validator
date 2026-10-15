-- ============================================================================
-- The route behind each measured detour.
--
-- detour_measured (0042) holds the distances. This holds what they were
-- measured on, so a reviewer can see the detour and check it road by road:
--
--   a, b          the two measuring points, [lat, lon]
--   block         the points that were closed: the deck for a bypass, the
--                 ground under the span for a collapse
--   open_path     the route between a and b with nothing closed
--   closed_path   the route between a and b with the block closed - the detour
--                 Both are encoded polylines, precision 6, simplified to ~2 m.
--   open_steps,   the roads each route uses, in order: [{"n": name, "mi": length}]
--   closed_steps  Names are OpenStreetMap's. A step with no name in the map is
--                 "(ramp)" or "(unnamed road)".
--
-- Every row was produced by repeating the published measurement on the same
-- graph and kept only where it reproduced that measurement's distances to
-- within 0.01 mi; open_mi and around_mi are the reproduced values.
-- ============================================================================

create table detour_route (
  brdg_nbr      text     not null,
  mode          text     not null check (mode in ('bypass','collapse')),
  seq           smallint not null default 0,
  a             jsonb    not null,
  b             jsonb    not null,
  block         jsonb    not null,
  open_mi       numeric(8,3) not null,
  around_mi     numeric(8,3) not null,
  open_path     text     not null,
  closed_path   text     not null,
  open_steps    jsonb    not null,
  closed_steps  jsonb    not null,
  graph_vintage text     not null,
  run_id        bigint,
  loaded_at     timestamptz not null default now(),
  primary key (brdg_nbr, mode, seq),
  foreign key (brdg_nbr, mode, seq) references detour_measured (brdg_nbr, mode, seq)
);

comment on table detour_route is
  'The open and closed route behind each detour_measured distance: measuring points, closed points, both paths (encoded polyline, precision 6) and the roads each uses with the distance on each. OSM road names; graph_vintage names the graph.';

alter table detour_route enable row level security;
create policy read_all on detour_route for select to anon, authenticated using (true);
grant select on detour_route to anon, authenticated;

-- ---------------------------------------------------------------------------
-- The write path, gated by the database-owned ingest token like ingest_detour
-- (0042). A row is replaced whole on reload. Migration 0047 closes the role
-- grant once the statewide load is verified.
create or replace function ingest_detour_route(p jsonb, p_token text)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  if p_token is null or p_token is distinct from (select token from ingest_secret where id = 1) then
    raise exception 'not authorised to load detour routes' using errcode = '42501';
  end if;

  insert into detour_route (brdg_nbr, mode, seq, a, b, block, open_mi, around_mi,
                            open_path, closed_path, open_steps, closed_steps,
                            graph_vintage, run_id)
  select x.brdg_nbr, x.mode, x.seq, x.a, x.b, x.block, x.open_mi, x.around_mi,
         x.open_path, x.closed_path, x.open_steps, x.closed_steps,
         x.graph_vintage, x.run_id
    from jsonb_to_recordset(p) as x(brdg_nbr text, mode text, seq smallint, a jsonb, b jsonb,
         block jsonb, open_mi numeric, around_mi numeric, open_path text, closed_path text,
         open_steps jsonb, closed_steps jsonb, graph_vintage text, run_id bigint)
  on conflict (brdg_nbr, mode, seq) do update
    set a = excluded.a, b = excluded.b, block = excluded.block,
        open_mi = excluded.open_mi, around_mi = excluded.around_mi,
        open_path = excluded.open_path, closed_path = excluded.closed_path,
        open_steps = excluded.open_steps, closed_steps = excluded.closed_steps,
        graph_vintage = excluded.graph_vintage, run_id = excluded.run_id,
        loaded_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function ingest_detour_route(jsonb, text) to anon, authenticated;

comment on function ingest_detour_route(jsonb, text) is
  'Load detour routes. Requires the ingest_secret token. Closed to the browser roles by 0047 after the load.';
