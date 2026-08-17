-- Continuation of 0033: the tables the three traffic items are read from.
-- Split only because ALTER TYPE ... ADD VALUE cannot share a transaction with
-- anything that uses the value it adds.

-- ---------------------------------------------------------------------------
create table traffic_station (
  location_id   text primary key,
  county_name   text,
  route_id      text,
  location      text,
  rte_cls       smallint,
  func_cls      smallint,
  coll_cycle    text,
  active        boolean,
  category      text,
  lat           double precision,
  lon           double precision,
  ingest_run_id bigint
);
comment on table traffic_station is
  'NCDOT Traffic Survey count stations. route_id is the 11-digit LRS Route ID, which is what makes this joinable to a bridge''s BH06 without a spatial guess. Values are two-way totals - all lanes, both directions - per NCDOT''s own file description.';
create index traffic_station_route_idx on traffic_station (route_id);
create index traffic_station_county_idx on traffic_station (county_name);

create table traffic_station_year (
  location_id text not null references traffic_station(location_id) on delete cascade,
  year        smallint not null,
  aadt        integer not null,
  primary key (location_id, year)
);
comment on table traffic_station_year is
  'One row per station per year that actually has a count. Long rather than wide on purpose: a missing row means the station was not counted that year - which its collection cycle predicts - and that is a different fact from a traffic volume of zero.';

-- ---------------------------------------------------------------------------
create table traffic_segment (
  id          bigserial primary key,
  route_id    text not null,
  begin_mp    numeric(9,4) not null,
  end_mp      numeric(9,4) not null,
  aadt        integer,
  aadtt       integer,
  su_aadt     integer,
  mu_aadt     integer,
  su_pct      numeric(6,3),
  mu_pct      numeric(6,3),
  source      text,
  tms_id      text,
  road_class  text,
  value_year  smallint,
  ingest_run_id bigint
);
comment on column traffic_segment.value_year is
  'Which year of the governing station''s series this segment''s AADT equals, worked out at ingest rather than assumed from a release note. It is what dates the truck share, and it re-dates itself when NCDOT republishes.';
create index traffic_segment_route_idx on traffic_segment (route_id, begin_mp, end_mp);
create index traffic_segment_tms_idx   on traffic_segment (tms_id);

create table traffic_probe (
  id          bigserial primary key,
  route_id    text not null,
  begin_mp    numeric(9,4) not null,
  end_mp      numeric(9,4) not null,
  estimated   integer,
  lo95        integer,
  hi95        integer,
  data_year   smallint,
  ingest_run_id bigint
);
comment on table traffic_probe is
  'Probe-derived AADT for the roads no count station governs. Reported only with its interval attached: an estimate of 3,380 that could be 2,400 or 5,200 is usable, and the same number with the interval stripped off is a lie about precision.';
create index traffic_probe_route_idx on traffic_probe (route_id, begin_mp, end_mp);

alter table traffic_station      enable row level security;
alter table traffic_station_year enable row level security;
alter table traffic_segment      enable row level security;
alter table traffic_probe        enable row level security;
create policy read_all on traffic_station      for select to anon, authenticated using (true);
create policy read_all on traffic_station_year for select to anon, authenticated using (true);
create policy read_all on traffic_segment      for select to anon, authenticated using (true);
create policy read_all on traffic_probe        for select to anon, authenticated using (true);
grant select on traffic_station, traffic_station_year, traffic_segment, traffic_probe
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- The ingest side. Same shape as every other loader here.
create or replace function ingest_traffic_stations(p jsonb, p_run bigint)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into traffic_station (location_id, county_name, route_id, location, rte_cls,
                               func_cls, coll_cycle, active, category, lat, lon, ingest_run_id)
  select x.location_id, upper(x.county_name), nullif(btrim(x.route_id),''), x.location,
         x.rte_cls, x.func_cls, x.coll_cycle, x.active, x.category, x.lat, x.lon, p_run
    from jsonb_to_recordset(p) as x(location_id text, county_name text, route_id text,
         location text, rte_cls smallint, func_cls smallint, coll_cycle text,
         active boolean, category text, lat double precision, lon double precision)
  on conflict (location_id) do update
    set county_name=excluded.county_name, route_id=excluded.route_id, location=excluded.location,
        rte_cls=excluded.rte_cls, func_cls=excluded.func_cls, coll_cycle=excluded.coll_cycle,
        active=excluded.active, category=excluded.category, lat=excluded.lat, lon=excluded.lon,
        ingest_run_id=p_run;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ingest_traffic_station_years(p jsonb, p_run bigint)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into traffic_station_year (location_id, year, aadt)
  select x.location_id, x.year, x.aadt
    from jsonb_to_recordset(p) as x(location_id text, year smallint, aadt integer)
   where x.aadt is not null and x.aadt > 0
     and exists (select 1 from traffic_station s where s.location_id = x.location_id)
  on conflict (location_id, year) do update set aadt = excluded.aadt;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ingest_traffic_segments(p jsonb, p_run bigint)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into traffic_segment (route_id, begin_mp, end_mp, aadt, aadtt, su_aadt, mu_aadt,
                               su_pct, mu_pct, source, tms_id, road_class, ingest_run_id)
  select x.route_id, x.begin_mp, x.end_mp, x.aadt, x.aadtt, x.su_aadt, x.mu_aadt,
         x.su_pct, x.mu_pct, x.source, nullif(btrim(x.tms_id),''), x.road_class, p_run
    from jsonb_to_recordset(p) as x(route_id text, begin_mp numeric, end_mp numeric,
         aadt integer, aadtt integer, su_aadt integer, mu_aadt integer,
         su_pct numeric, mu_pct numeric, source text, tms_id text, road_class text);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ingest_traffic_probe(p jsonb, p_run bigint)
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into traffic_probe (route_id, begin_mp, end_mp, estimated, lo95, hi95, data_year, ingest_run_id)
  select x.route_id, x.begin_mp, x.end_mp, x.estimated, x.lo95, x.hi95, x.data_year, p_run
    from jsonb_to_recordset(p) as x(route_id text, begin_mp numeric, end_mp numeric,
         estimated integer, lo95 integer, hi95 integer, data_year smallint);
  get diagnostics n = row_count;
  return n;
end $$;

-- Date every segment against its own station's series. Run after both loads.
create or replace function traffic_date_segments()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  update traffic_segment s
     set value_year = y.year
    from lateral (select yy.year from traffic_station_year yy
                   where yy.location_id = s.tms_id and yy.aadt = s.aadt
                   order by yy.year desc limit 1) y
   where s.tms_id is not null and s.aadt is not null;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function ingest_traffic_stations(jsonb,bigint),
                          ingest_traffic_station_years(jsonb,bigint),
                          ingest_traffic_segments(jsonb,bigint),
                          ingest_traffic_probe(jsonb,bigint),
                          traffic_date_segments() from public;
grant execute on function ingest_traffic_stations(jsonb,bigint),
                         ingest_traffic_station_years(jsonb,bigint),
                         ingest_traffic_segments(jsonb,bigint),
                         ingest_traffic_probe(jsonb,bigint),
                         traffic_date_segments() to service_role;
