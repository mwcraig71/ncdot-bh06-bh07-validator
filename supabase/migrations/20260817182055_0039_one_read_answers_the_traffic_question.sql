-- ============================================================================
-- What the browser reads to answer B.H.09, B.H.10 and B.H.11.
--
-- Same shape as route_extents: the client asks for the routes in its scope,
-- one read, and does the milepoint containment itself - it already walks
-- measures for BH07, and the alternative is a round trip per feature.
--
-- Each row is a stretch of road with everything needed to report all three
-- items and to say where each part came from:
--
--   aadt / aadt_year        the CURRENT counted total, from the station
--   segment_aadt / _aadtt   what the segmentation holds, at its own vintage
--   value_year              which year of the station's series that equals
--   su_pct / mu_pct         the measured truck share, dated by value_year
--
-- CORRECTION to what migration 0034 asserted. "91% of segments equal the
-- station's 2022 figure" was measured in Mecklenburg and is not the statewide
-- picture: across all 47,071 segments it is 38.9% at 2022, 17.2% at 2024, 8.6%
-- at 2021, and 18.7% matching no year of their station at all. There is no
-- single vintage to name, which is exactly why the year is stored per segment
-- rather than written into a constant.
-- ============================================================================

comment on column traffic_segment.value_year is
  'Which year of the governing station''s series this segment''s AADT equals, worked out at ingest. Measured statewide: 38.9% are 2022, 17.2% 2024, 8.6% 2021, and 18.7% match no year of their station - so the segmentation has no single vintage and the truck share it carries has to be dated segment by segment.';

create view traffic_client
with (security_invoker = true) as
select s.route_id,
       s.begin_mp,
       s.end_mp,
       s.tms_id,
       s.road_class,
       s.aadt   as segment_aadt,
       s.aadtt  as segment_aadtt,
       s.su_pct,
       s.mu_pct,
       s.value_year,
       st.location_id,
       st.location as station_location,
       st.coll_cycle,
       st.active as station_active,
       cur.year as aadt_year,
       cur.aadt as aadt
from traffic_segment s
left join traffic_station st on st.location_id = s.tms_id
left join lateral (
  select y.year, y.aadt from traffic_station_year y
   where y.location_id = s.tms_id
   order by y.year desc limit 1
) cur on true;

comment on view traffic_client is
  'One row per traffic segment, carrying the current counted total from its station beside the segmentation''s own older value and the truck share that value dates. Read by route, the way route_extents is: the browser does the milepoint containment because it is already walking measures for BH07.';

grant select on traffic_client to anon, authenticated;
