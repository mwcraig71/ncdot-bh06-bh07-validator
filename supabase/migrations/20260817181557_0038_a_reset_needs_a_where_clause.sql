-- The project runs with the "DELETE requires a WHERE clause" guard on, which is
-- a good default and applies inside a definer function too. Replacing a whole
-- table is exactly the case it is there to make deliberate, so it is spelled
-- out rather than worked around.
create or replace function traffic_reset_segments()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  select count(*) into n from traffic_segment;
  delete from traffic_segment where id is not null;
  return n;
end $$;

create or replace function traffic_reset_probe()
returns int language plpgsql security definer
set search_path = public, pg_catalog as $$
declare n int;
begin
  select count(*) into n from traffic_probe;
  delete from traffic_probe where id is not null;
  return n;
end $$;

revoke execute on function traffic_reset_segments(), traffic_reset_probe() from public;
grant execute on function traffic_reset_segments(), traffic_reset_probe() to service_role;
