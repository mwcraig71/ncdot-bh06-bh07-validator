-- ============================================================================
-- The ingest boundary
--
-- Ingest runs as the service role, outside any request, and writes PUBLISHED
-- rows only. The interesting question is not how it writes but what happens
-- when a republish contradicts a review — and the answer is that it records
-- the disagreement and changes nothing else. Resolving it is a person's job.
-- ============================================================================

-- County polygons, so the map has boundaries without a live ArcGIS call.
alter table county_codes
  add column boundary extensions.geography(MultiPolygon,4326),
  add column ingest_run_id bigint references ingest_runs(id);

create index county_codes_boundary_gix on county_codes using gist (boundary);

comment on column county_codes.boundary is
  'County outline from NCDOT_CountyBdy_Poly, simplified on ingest. The map draws these; nothing about them changes between quarterly publications.';

-- ------------------------------------------------------- value_divergence ---
create table value_divergence (
  id             uuid primary key default gen_random_uuid(),
  feature_id     uuid not null references features(id) on delete cascade,
  field          snbi_field not null,

  published_before text,
  published_after  text,
  reviewed_value   text,

  ingest_run_id  bigint references ingest_runs(id),
  detected_at    timestamptz not null default now(),

  -- Left for a person. Nothing in the ingest path ever sets these.
  resolved_at    timestamptz,
  resolved_by    uuid,
  resolution     text check (resolution in ('keep_review','accept_published','superseded')),
  note           text
);

comment on table value_divergence is
  'Raised when an ingest changes a PUBLISHED value on a feature that already carries a live review. The ingest records the disagreement and resolves nothing: the review still wins, because it is still the higher source, and a person decides whether it should. Same rule as the resolution hierarchy, applied at the ingest boundary.';
comment on column value_divergence.reviewed_value is
  'The reviewed value as it stood when the divergence was detected, held as text so the record stays readable even if the review is later changed again.';

create index value_divergence_open_idx on value_divergence (detected_at desc)
  where resolved_at is null;
create index value_divergence_feature_idx on value_divergence (feature_id, field);
create index value_divergence_run_idx on value_divergence (ingest_run_id);

alter table value_divergence enable row level security;
create policy read_all on value_divergence for select to anon, authenticated using (true);
create policy resolve_divergence on value_divergence
  for update to authenticated using (true) with check (true);
grant select, update on value_divergence to authenticated;
grant select on value_divergence to anon;

-- ---------------------------------------------------------------------------
-- Detection lives in a trigger, not in the ingest code, for the same reason the
-- audit trail does: it must not be possible to write the change and skip the
-- record. Any path that moves a PUBLISHED value is covered, including a
-- statement typed into the dashboard.
create or replace function flag_published_divergence()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare rv text; old_t text; new_t text;
begin
  if new.source <> 'PUBLISHED' then return new; end if;

  old_t := coalesce(old.value_text, old.value_num::text);
  new_t := coalesce(new.value_text, new.value_num::text);
  if old_t is not distinct from new_t then return new; end if;

  -- Only interesting where a reviewer has already said something about this
  -- field. Everywhere else a republish is simply the new truth.
  select coalesce(value_text, value_num::text) into rv
  from feature_values
  where feature_id = new.feature_id and field = new.field
    and source = 'REVIEWED' and withdrawn_at is null;

  if rv is null then return new; end if;

  insert into value_divergence
    (feature_id, field, published_before, published_after, reviewed_value, ingest_run_id)
  values
    (new.feature_id, new.field, old_t, new_t, rv, new.ingest_run_id);

  return new;
end $$;

comment on function flag_published_divergence() is
  'Records a divergence when a republish moves a PUBLISHED value out from under a live review. Deliberately does not touch the review: the hierarchy already decides which value is used, and this only makes the disagreement visible.';

revoke execute on function flag_published_divergence() from public, anon, authenticated;

create trigger feature_values_divergence
  after update on feature_values
  for each row execute function flag_published_divergence();

-- ---------------------------------------------------------------------------
-- Publication dates, as the services actually report them. Three formats
-- observed live, and none of them is a timestamp field:
--   NCDOT_Bridges / RoadCharacteristics  "Latest Publication Date: 03/15/2026 : 14:05"
--   NCDOT_DynamicStructures              "(Geoservice Date: 7/27/2020)"
--   NCDOT_CountyBdy_Poly                 "(Friday, Feb 10, 2023)"
-- The raw text is kept verbatim in publication_label regardless; this only
-- tries to put a timestamp beside it.
create or replace function parse_publication_date(txt text)
returns timestamptz
language plpgsql
immutable
set search_path = public, pg_catalog
as $$
declare m text[];
begin
  if txt is null then return null; end if;

  m := regexp_match(txt, 'Publication Date:\s*(\d{1,2})/(\d{1,2})/(\d{4})(?:\s*:\s*(\d{1,2}):(\d{2}))?');
  if m is not null then
    return make_timestamptz(m[3]::int, m[1]::int, m[2]::int,
                            coalesce(m[4],'0')::int, coalesce(m[5],'0')::int, 0, 'UTC');
  end if;

  m := regexp_match(txt, 'Geoservice Date:\s*(\d{1,2})/(\d{1,2})/(\d{4})');
  if m is not null then
    return make_timestamptz(m[3]::int, m[1]::int, m[2]::int, 0, 0, 0, 'UTC');
  end if;

  m := regexp_match(txt, '([A-Z][a-z]{2})[a-z]*\s+(\d{1,2}),\s*(\d{4})');
  if m is not null then
    begin
      return (m[1] || ' ' || m[2] || ' ' || m[3])::date;
    exception when others then return null;
    end;
  end if;

  return null;
end $$;

comment on function parse_publication_date(text) is
  'Best effort at a timestamp from the free text a service reports as its vintage. Returns null rather than guessing; publication_label always keeps the original words.';

-- ---------------------------------------------------------------------------
-- Run bookkeeping, called by the Edge Functions.
create or replace function ingest_begin(p_service text, p_url text, p_desc text)
returns bigint
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare rid bigint; lbl text;
begin
  lbl := nullif(btrim(coalesce(
           (regexp_match(p_desc, '(Latest Publication Date:[^\n]*)'))[1],
           (regexp_match(p_desc, '(Geoservice Date:[^)]*)'))[1],
           (regexp_match(p_desc, '\(([A-Z][a-z]+day,[^)]*)\)'))[1],
           p_desc)), '');
  insert into ingest_runs (source_service, source_url, published_at, publication_label, status)
  values (p_service, p_url, parse_publication_date(p_desc), left(lbl, 300), 'running')
  returning id into rid;
  return rid;
end $$;

create or replace function ingest_finish(p_run bigint, p_status text, p_rows int,
                                         p_ins int, p_upd int, p_error text default null,
                                         p_notes text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  update ingest_runs
     set status = p_status, completed_at = now(), row_count = p_rows,
         rows_inserted = p_ins, rows_updated = p_upd, error = p_error, notes = p_notes
   where id = p_run;
end $$;

revoke execute on function ingest_begin(text,text,text)            from public, anon, authenticated;
revoke execute on function ingest_finish(bigint,text,int,int,int,text,text) from public, anon, authenticated;
