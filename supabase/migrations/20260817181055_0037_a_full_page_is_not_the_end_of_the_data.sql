-- ============================================================================
-- The 1,000-row cap, again.
--
-- The AADT segmentation layers advertise maxRecordCount 1000 while their
-- standardMaxRecordCount says 2000. Ask for 2,000 and you get 1,000 rows and
-- exceededTransferLimit: true. The loader treated "fewer rows than I asked for"
-- as "that is the end of this layer" and moved on, so it loaded 2,659 segments
-- out of 47,071 and reported success. Silent truncation, and the second time
-- this exact shape of bug has appeared in this project - the first put 4,367 of
-- 22,899 structures into the old client.
--
-- The rule that follows: never infer completion from the size of a page.
-- exceededTransferLimit is the service telling you there is more, and it is the
-- only thing worth believing.
--
-- These two exist because the segment and probe tables have no natural key to
-- upsert on - a segment is a stretch of road, not a thing with an id - so a
-- reload has to replace rather than merge. Called once per logical run, at the
-- point the first page is requested.
-- ============================================================================

create or replace function traffic_reset_segments()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  select count(*) into n from traffic_segment;
  delete from traffic_segment;
  return n;
end $$;

create or replace function traffic_reset_probe()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  select count(*) into n from traffic_probe;
  delete from traffic_probe;
  return n;
end $$;

revoke execute on function traffic_reset_segments(), traffic_reset_probe() from public;
grant execute on function traffic_reset_segments(), traffic_reset_probe() to service_role;
