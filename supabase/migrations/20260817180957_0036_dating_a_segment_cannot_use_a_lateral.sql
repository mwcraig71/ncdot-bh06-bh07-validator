-- UPDATE ... FROM LATERAL cannot see the row being updated. Postgres is explicit
-- about it - "there is an entry for table s, but it cannot be referenced from
-- this part of the query" - and the dating pass died on it after the stations,
-- the years and the segments had all loaded. A correlated subquery in the SET
-- clause can see the target row, which is the whole requirement here: for THIS
-- segment, which year of ITS station's series does its AADT equal.
create or replace function traffic_date_segments()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  update traffic_segment s
     set value_year = (select yy.year
                         from traffic_station_year yy
                        where yy.location_id = s.tms_id and yy.aadt = s.aadt
                        order by yy.year desc limit 1)
   where s.tms_id is not null and s.aadt is not null;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function traffic_date_segments() from public;
grant execute on function traffic_date_segments() to service_role;
