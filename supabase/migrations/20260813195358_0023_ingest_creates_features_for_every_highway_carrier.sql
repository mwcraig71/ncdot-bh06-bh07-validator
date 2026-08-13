-- ============================================================================
-- Same ingest, correct population.
--
-- The carried feature the bridge layer can supply is the primary one - that
-- layer has one row per structure, so it can describe one roadway. Additional
-- carried roadways on the same deck, and everything below, are derived, and
-- the derivation has its own guard. What changes here is only which structures
-- get their first feature at all.
-- ============================================================================
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

  -- The primary carried feature, for every structure that carries a highway.
  insert into features (structure_number, designation, location_type, feature_name,
                        feature_seq, is_primary, route_id_hint,
                        derivation_method, computed_at, computed_by)
  select b.sn, 'H01', 'C', b.carried, 1, true, b.rte,
         'published inventory: ServiceOn ' || b.service_on, now(), 'ingest'
  from _b b where carries_highway(b.service_on)
  on conflict (structure_number, designation) do update
    set feature_name = excluded.feature_name,
        is_primary   = true,
        feature_seq  = coalesce(features.feature_seq, 1),
        route_id_hint= excluded.route_id_hint;
  get diagnostics n_f = row_count;

  insert into feature_values (feature_id, field, source, value_text, ingest_run_id)
  select f.id, 'BH06', 'PUBLISHED', b.rte, p_run
  from _b b join features f on f.structure_number=b.sn and f.designation='H01'
  where carries_highway(b.service_on) and b.rte is not null and upper(b.rte) <> 'NA'
  on conflict (feature_id, field, source) do update
    set value_text = excluded.value_text, ingest_run_id = excluded.ingest_run_id,
        recorded_at = now();
  get diagnostics n_v = row_count;

  insert into feature_values (feature_id, field, source, value_num, ingest_run_id)
  select f.id, 'BH07', 'PUBLISHED', round(b.mp,3), p_run
  from _b b join features f on f.structure_number=b.sn and f.designation='H01'
  where carries_highway(b.service_on) and b.mp is not null
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

revoke execute on function ingest_bridges(jsonb,bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Backfill, so the correction applies to what is already loaded rather than
-- waiting for the next quarterly run. PUBLISHED values follow from the columns
-- the structures table already holds.
insert into features (structure_number, designation, location_type, feature_name,
                      feature_seq, is_primary, derivation_method, computed_at, computed_by)
select s.structure_number, 'H01', 'C', s.feature_carried, 1, true,
       'published inventory: ServiceOn ' || coalesce(s.service_on,'?'), now(), 'backfill 0023'
from structures s
where carries_highway(s.service_on)
  and not exists (select 1 from features f where f.structure_number = s.structure_number)
on conflict (structure_number, designation) do nothing;

update features set feature_seq = 1, is_primary = true
where designation = 'H01' and (feature_seq is null or is_primary = false);
