-- 0044: the traffic write path is not public.
--
-- The seven functions the traffic ingest uses were left executable by anon and
-- authenticated (the Postgres default for new functions is EXECUTE to PUBLIC).
-- All seven are SECURITY DEFINER and none checks a token, so the anon key that
-- every copy of the page carries could empty traffic_probe and traffic_segment
-- (traffic_reset_*) or write into all four traffic tables (ingest_traffic_*).
-- Found by the code review of 14 October 2026; nothing had been touched.
--
-- Only the ingest edge function calls them, with the service role key, so the
-- service role keeps EXECUTE and everyone else loses it. Reads are unaffected:
-- the page reads the traffic tables through their views under row level security.
revoke execute on function public.traffic_reset_probe()                           from public, anon, authenticated;
revoke execute on function public.traffic_reset_segments()                        from public, anon, authenticated;
revoke execute on function public.traffic_date_segments()                         from public, anon, authenticated;
revoke execute on function public.ingest_traffic_probe(jsonb, bigint)             from public, anon, authenticated;
revoke execute on function public.ingest_traffic_segments(jsonb, bigint)          from public, anon, authenticated;
revoke execute on function public.ingest_traffic_station_years(jsonb, bigint)     from public, anon, authenticated;
revoke execute on function public.ingest_traffic_stations(jsonb, bigint)          from public, anon, authenticated;
grant  execute on function public.traffic_reset_probe()                           to service_role;
grant  execute on function public.traffic_reset_segments()                        to service_role;
grant  execute on function public.traffic_date_segments()                         to service_role;
grant  execute on function public.ingest_traffic_probe(jsonb, bigint)             to service_role;
grant  execute on function public.ingest_traffic_segments(jsonb, bigint)          to service_role;
grant  execute on function public.ingest_traffic_station_years(jsonb, bigint)     to service_role;
grant  execute on function public.ingest_traffic_stations(jsonb, bigint)          to service_role;
