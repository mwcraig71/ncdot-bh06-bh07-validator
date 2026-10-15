-- ============================================================================
-- Detour length measured from the turn points (FHWA SNBI Figure 102).
--
-- The statewide measurement (0042) put its two measuring points at the bridge
-- ends. A driver there has to double back to the nearest turn-off, and that
-- doubling back was counted as detour. Figure 102 measures between the point
-- where traffic leaves the road and the point where it rejoins it:
--
--   reported = detour route between the turn points
--            - the normal route between the same two points
--
-- detour_measured keeps the bridge-end figures (around_mi, direct_mi,
-- additional_mi) unchanged, and gains the reported figure and its basis:
--
--   report_basis  turn_points             normal route routed between the turn points
--                 turn_points_along_road  normal route measured along the road (routing
--                                         from a turn point could not be trusted)
--                 bridge_ends_local       a shorter way between the turn points skips the
--                                         bridge (a loop road): only traffic between them
--                                         uses it, and for them the bridge-end figure is
--                                         the detour
--                 bridge_ends             no turn points could be fixed on the route
--   report_mi     the figure to report; for the two bridge_ends bases it equals
--                 additional_mi
--
-- detour_route gains what the turn-point figure was measured on: the two turn
-- points, the detour and the normal route between them (encoded polylines,
-- precision 6) and the roads each uses. Null where the basis is bridge_ends*.
--
-- Columns only. The rows are loaded from data/detour_turns/ (tools/detour/
-- fig102.py, export_turns.py), as the routes were.
-- ============================================================================

alter table detour_measured
  add column report_mi    numeric(8,3),
  add column report_basis text check (report_basis in
                ('turn_points','turn_points_along_road','bridge_ends_local','bridge_ends')),
  add constraint detour_report_only_when_measured check (
    report_mi is null or verdict in ('ok','bypass_at_site')),
  add constraint detour_report_has_basis check (
    (report_mi is null) = (report_basis is null));

comment on column detour_measured.report_mi is
  'The detour length to report, FHWA SNBI Figure 102: detour route between the turn points minus the normal route between them. Equals additional_mi where report_basis is bridge_ends or bridge_ends_local.';
comment on column detour_measured.report_basis is
  'How report_mi was measured: turn_points, turn_points_along_road, bridge_ends_local (loop road: only local traffic uses the bridge), bridge_ends.';

alter table detour_route
  add column ja                  jsonb,
  add column jb                  jsonb,
  add column turn_detour_mi      numeric(8,3),
  add column turn_original_mi    numeric(8,3),
  add column turn_detour_path    text,
  add column turn_original_path  text,
  add column turn_detour_steps   jsonb,
  add column turn_original_steps jsonb,
  add constraint detour_route_turns_whole check (
    (ja is null) = (jb is null) and (ja is null) = (turn_detour_mi is null)
    and (ja is null) = (turn_original_mi is null));

comment on column detour_route.ja is
  'Turn-off point [lat, lon]: where the detour leaves the road. Null when the reported figure is from the bridge ends.';
comment on column detour_route.jb is
  'Turn-back-on point [lat, lon]: where the detour rejoins the road.';
