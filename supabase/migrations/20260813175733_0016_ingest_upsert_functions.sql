-- ============================================================================
-- What the Edge Functions call.
--
-- The functions fetch and page; all the writing happens here, in one place, in
-- SQL. That keeps the upsert semantics — and the rule that ingest touches
-- PUBLISHED and nothing else — reviewable in the schema rather than spread
-- across five TypeScript files.
--
-- Every one of these is service_role only. There is no client path to any of it.
-- ============================================================================

-- A published value that disappears upstream is also a divergence, if a
-- reviewer had already spoken. The UPDATE trigger from 0015 does not see that
-- case, so it is covered here.
create or replace function flag_published_removal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare rv text;
begin
  if old.source <> 'PUBLISHED' then return old; end if;
  select coalesce(value_text, value_num::text) into rv
  from feature_values
  where feature_id = old.feature_id and field = old.field
    and source = 'REVIEWED' and withdrawn_at is null;
  if rv is null then return old; end if;
  insert into value_divergence
    (feature_id, field, published_before, published_after, reviewed_value)
  values
    (old.feature_id, old.field, coalesce(old.value_text, old.value_num::text), null, rv);
  return old;
end $$;

revoke execute on function flag_published_removal() from public, anon, authenticated;

create trigger feature_values_divergence_removed
  after delete on feature_values
  for each row execute function flag_published_removal();

-- ------------------------------------------------------------- counties ----
create or replace function ingest_counties(p jsonb, p_run bigint)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_catalog as $$
declare n int;
begin
  insert into county_codes (sap_code, county_name, fips_code, dot_division, boundary, ingest_run_id)
  select r->>'sap', upper(r->>'name'), nullif(r->>'fips','')::smallint,
         nullif(r->>'division','')::smallint,
         case when r->'geom' is not null
              then st_multi(st_geomfromgeojson(r->>'geom'))::geography end,
         p_run
  from jsonb_array_elements(p) r
  where r->>'sap' is not null and r->>'name' is not null
  on conflict (sap_code) do update
    set county_name = excluded.county_name,
        fips_code   = coalesce(excluded.fips_code, county_codes.fips_code),
        dot_division= coalesce(excluded.dot_division, county_codes.dot_division),
        boundary    = coalesce(excluded.boundary, county_codes.boundary),
        ingest_run_id = excluded.ingest_run_id;
  get diagnostics n = row_count;
  return jsonb_build_object('rows', n);
end $$;

-- -------------------------------------------------------------- bridges ----
-- The bridge layer gives location, description, county and the published
-- BH06/BH07. SERVICEON = '1' is NCDOT's own statement that a highway is carried
-- on the structure, and it is the test for whether a highway FEATURE exists at
-- all: measured across the whole layer it selects 17,159 of 23,022, excluding
-- every sign, railroad and pedestrian structure. That is the real NBI
-- population, and nothing else should be given a BH06.
create or replace function ingest_bridges(p jsonb, p_run bigint)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_catalog as $$
declare n_s int; n_f int; n_v int; n_gone int;
begin
  create temp table _b on commit drop as
  select btrim(r->>'BRDG_NBR')                       as sn,
         upper(nullif(btrim(r->>'COUNTY'),''))       as county,
         nullif(btrim(r->>'DIVISION'),'')::smallint  as division,
         nullif(btrim(r->>'F_CARRIED'),'')           as carried,
         nullif(btrim(r->>'FTR_INTRSC'),'')          as crossed,
         nullif(btrim(r->>'SERVICEON'),'')           as service_on,
         nullif(btrim(r->>'SERVICEUNDER'),'')        as service_under,
         nullif(btrim(r->>'MAINT_RESP'),'')          as maint,
         nullif(btrim(r->>'FUNC_CLASS'),'')          as fclass,
         nullif(btrim(r->>'BRDG_TYP_NM'),'')         as typ,
         nullif(r->>'AADT','')::int                  as adt,
         nullif(r->>'LAT_DD','')::double precision   as lat,
         nullif(r->>'LONG_DD','')::double precision  as lon,
         nullif(btrim(r->>'RTE_ID'),'')              as rte,
         nullif(r->>'MP','')::numeric                as mp
  from jsonb_array_elements(p) r
  where btrim(coalesce(r->>'BRDG_NBR','')) <> '';

  insert into structures (structure_number, county_name, county_sap, division,
                          feature_carried, feature_intersected, service_on, service_under,
                          maint_responsible, functional_class, structure_type, adt,
                          location, ingest_run_id, last_seen_at)
  select b.sn, b.county, c.sap_code, b.division, b.carried, b.crossed, b.service_on,
         b.service_under, b.maint, b.fclass, b.typ, b.adt,
         case when b.lat is not null and b.lon is not null
              then st_setsrid(st_makepoint(b.lon, b.lat),4326)::geography end,
         p_run, now()
  from _b b left join county_codes c on c.county_name = b.county
  on conflict (structure_number) do update
    set county_name = excluded.county_name, county_sap = excluded.county_sap,
        division = excluded.division, feature_carried = excluded.feature_carried,
        feature_intersected = excluded.feature_intersected,
        service_on = excluded.service_on, service_under = excluded.service_under,
        maint_responsible = excluded.maint_responsible,
        functional_class = excluded.functional_class,
        structure_type = excluded.structure_type, adt = excluded.adt,
        location = coalesce(excluded.location, structures.location),
        ingest_run_id = excluded.ingest_run_id, last_seen_at = now();
  get diagnostics n_s = row_count;

  -- One highway feature per structure that carries a highway.
  insert into features (structure_number, designation, location_type, feature_name,
                        derivation_method, computed_at, computed_by)
  select b.sn, 'H01', 'C', b.carried, 'published inventory: SERVICEON=1', now(), 'ingest'
  from _b b where b.service_on = '1'
  on conflict (structure_number, designation) do update
    set feature_name = excluded.feature_name;
  get diagnostics n_f = row_count;

  -- PUBLISHED BH06 / BH07. Absence of a row is how "NCDOT publishes nothing"
  -- is represented, so a value that has gone away is removed rather than kept.
  insert into feature_values (feature_id, field, source, value_text, ingest_run_id)
  select f.id, 'BH06', 'PUBLISHED', b.rte, p_run
  from _b b join features f on f.structure_number=b.sn and f.designation='H01'
  where b.service_on='1' and b.rte is not null and upper(b.rte) <> 'NA'
  on conflict (feature_id, field, source) do update
    set value_text = excluded.value_text, ingest_run_id = excluded.ingest_run_id,
        recorded_at = now();
  get diagnostics n_v = row_count;

  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  select f.id, 'BH07', 'PUBLISHED', round(b.mp,3), p_run
  from _b b join features f on f.structure_number=b.sn and f.designation='H01'
  where b.service_on='1' and b.mp is not null
  on conflict (feature_id, field, source) do update
    set value_num = excluded.value_num, ingest_run_id = excluded.ingest_run_id,
        recorded_at = now();
  get diagnostics n_gone = row_count;
  n_v := n_v + n_gone;

  delete from feature_values fv
  using _b b join features f on f.structure_number=b.sn and f.designation='H01'
  where fv.feature_id=f.id and fv.source='PUBLISHED'
    and ( (fv.field='BH06' and (b.rte is null or upper(b.rte)='NA'))
       or (fv.field='BH07' and b.mp is null) );
  get diagnostics n_gone = row_count;

  return jsonb_build_object('structures',n_s,'features',n_f,'values',n_v,'removed',n_gone);
end $$;

-- ----------------------------------------------------------- structures ----
-- The SNBI inventory service, which carries condition, geometry and service
-- type. Joins onto the same row by structure number and never touches the
-- bridge-layer columns.
create or replace function ingest_structures(p jsonb, p_run bigint, p_type text)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_catalog as $$
declare n int;
begin
  update structures s set
    structure_type = coalesce(p_type, s.structure_type),
    service_on = coalesce(nullif(btrim(r->>'ServiceOn'),''), s.service_on),
    service_under = coalesce(nullif(btrim(r->>'ServiceUnder'),''), s.service_under),
    structure_length = coalesce(nullif(r->>'StructureLength','')::numeric, s.structure_length),
    bridge_deck_width = coalesce(nullif(r->>'BridgeDeckWidth','')::numeric, s.bridge_deck_width),
    bridge_road_width = coalesce(nullif(r->>'BridgeRoadWidth','')::numeric, s.bridge_road_width),
    approach_road_width = coalesce(nullif(r->>'ApproachRoadWidth','')::numeric, s.approach_road_width),
    fed_skew = coalesce(nullif(r->>'FedSkew','')::smallint, s.fed_skew),
    through_lanes_on = coalesce(nullif(r->>'ThroughLanesOn','')::smallint, s.through_lanes_on),
    year_built = coalesce(nullif(r->>'YearBuilt','')::smallint, s.year_built),
    deck_condition = coalesce(nullif(btrim(r->>'DeckCondition'),''), s.deck_condition),
    superstructure_condition = coalesce(nullif(btrim(r->>'SuperStructureCondition'),''), s.superstructure_condition),
    substructure_condition = coalesce(nullif(btrim(r->>'SubStructureCondition'),''), s.substructure_condition),
    culvert_condition = coalesce(nullif(btrim(r->>'CulvertCondition'),''), s.culvert_condition),
    last_inspect_date = coalesce(
        case when (r->>'LastInspectDate') ~ '^\d+$'
             then to_timestamp((r->>'LastInspectDate')::bigint/1000)::date end, s.last_inspect_date),
    scour_critical = coalesce(nullif(btrim(r->>'ScourCritical'),''), s.scour_critical),
    fracture_critical = coalesce(nullif(btrim(r->>'FractureCritical'),''), s.fracture_critical),
    posted_open_closed = coalesce(nullif(btrim(r->>'PostedOpenClosed'),''), s.posted_open_closed),
    nhs = coalesce(nullif(btrim(r->>'NHS'),''), s.nhs),
    owner_code = coalesce(nullif(btrim(r->>'Owner'),''), s.owner_code),
    legacy_inventory_route = coalesce(nullif(btrim(r->>'InventoryRoute'),''), s.legacy_inventory_route),
    ingest_run_id = p_run, last_seen_at = now()
  from jsonb_array_elements(p) r
  where s.structure_number = btrim(r->>'StructureNumber');
  get diagnostics n = row_count;
  return jsonb_build_object('matched', n);
end $$;

-- --------------------------------------------------------------- extents ---
-- The materialised deepCheck. Grouping EndMp1/BeginMp1 by RouteID is what the
-- browser used to do live, once per run, for every route in scope.
create or replace function ingest_route_extents(p jsonb, p_run bigint)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into route_extents (route_id, min_mp, max_mp, measured_at, ingest_run_id)
  select btrim(r->>'route_id'), round((r->>'mn')::numeric,3), round((r->>'mx')::numeric,3), now(), p_run
  from jsonb_array_elements(p) r
  where btrim(coalesce(r->>'route_id','')) <> ''
    and (r->>'mn') is not null and (r->>'mx') is not null
    and (r->>'mx')::numeric >= (r->>'mn')::numeric
  on conflict (route_id) do update
    set min_mp=excluded.min_mp, max_mp=excluded.max_mp,
        measured_at=excluded.measured_at, ingest_run_id=excluded.ingest_run_id;
  get diagnostics n = row_count;
  return jsonb_build_object('rows', n);
end $$;

-- ------------------------------------------------------------------ hpms ---
create or replace function ingest_hpms(p jsonb, p_year int, p_run bigint)
returns jsonb language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  insert into hpms_routes (hpms_year, route_id, county_id, begin_point, end_point, ingest_run_id)
  select p_year, btrim(r->>'route_id'), nullif(r->>'county_id','')::smallint,
         round((r->>'mn')::numeric,3), round((r->>'mx')::numeric,3), p_run
  from jsonb_array_elements(p) r
  where btrim(coalesce(r->>'route_id','')) <> ''
  on conflict (hpms_year, route_id) do update
    set county_id=excluded.county_id, begin_point=excluded.begin_point,
        end_point=excluded.end_point, ingest_run_id=excluded.ingest_run_id;
  get diagnostics n = row_count;
  return jsonb_build_object('rows', n);
end $$;

revoke execute on function ingest_counties(jsonb,bigint)        from public, anon, authenticated;
revoke execute on function ingest_bridges(jsonb,bigint)         from public, anon, authenticated;
revoke execute on function ingest_structures(jsonb,bigint,text) from public, anon, authenticated;
revoke execute on function ingest_route_extents(jsonb,bigint)   from public, anon, authenticated;
revoke execute on function ingest_hpms(jsonb,int,bigint)        from public, anon, authenticated;
