-- ============================================================================
-- What the browser reads.
--
-- PostgREST returns a geography column as WKB hex, which Leaflet cannot draw,
-- and caps any response at 1,000 rows. So: a view that hands back GeoJSON, and
-- the client pages. Nothing here is new data — it is the same tables, shaped
-- for the one consumer that needs a different shape.
-- ============================================================================

create view county_geojson
with (security_invoker = true) as
select county_name, sap_code, fips_code, dot_division,
       extensions.st_asgeojson(boundary)::jsonb as geom
from county_codes;

comment on view county_geojson is
  'County outlines as GeoJSON for the map. 100 rows, one page, one request — this replaces the live NCDOT_CountyBdy_Poly call the browser used to make on every page load.';

-- The SNBI columns the bridge panel and CSV show, by county so the client can
-- ask for exactly the scope it is looking at.
create view structure_snbi
with (security_invoker = true) as
select structure_number, county_name, division, structure_type,
       service_on, service_under, structure_length, bridge_deck_width,
       bridge_road_width, approach_road_width, fed_skew, through_lanes_on,
       year_built, deck_condition, superstructure_condition, substructure_condition,
       culvert_condition, last_inspect_date, scour_critical, fracture_critical,
       posted_open_closed, nhs, owner_code, maint_responsible,
       legacy_inventory_route, adt
from structures;

comment on view structure_snbi is
  'The SNBI inventory join, flattened for the client. Replaces eight paged ArcGIS layer queries per run with one indexed read.';

grant select on county_geojson, structure_snbi to anon, authenticated;
