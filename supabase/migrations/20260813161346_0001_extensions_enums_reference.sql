-- ============================================================================
-- NCDOT SNBI BH06 / BH07 — foundations
--
-- Vocabulary follows SNBI (FHWA-HIF-22-017) rather than the bridge layer's
-- column names, because the hierarchy is what the data actually is:
--   BRIDGE  -> FEATURE (B.F.01 = H01/R01/W01..., B.F.02 = C carried / B below)
--           -> HIGHWAY record (B.H), where BH06 and BH07 live, one per highway
--              FEATURE — not one per route. Concurrent routes on one deck are
--              route records under a single highway feature, which is why
--              feature, not structure, is the grain of every value below.
-- ============================================================================

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums ----
-- The two SNBI items this system exists to get right.
create type snbi_field as enum ('BH06','BH07');

-- Where a value came from. Ordering here is deliberate and load-bearing:
-- Postgres orders enums by declaration, so `max(source)` IS the precedence
-- rule. Declared weakest first.
create type value_source as enum ('PUBLISHED','DERIVED','REVIEWED');

-- B.F.02 — is the feature carried ON the structure, or does it pass BELOW it?
-- BH06/BH07 are only reported for a highway feature that is CARRIED. The road
-- underneath is the single commonest wrong answer, so the distinction is a
-- column, not a convention.
create type feature_location as enum ('C','B');

create type finding_severity as enum ('error','warning','note');

create type review_status as enum
  ('open','progress','fixed','notissue','accepted');

-- How much to trust a derived value. Low means "this may be the road
-- underneath" — it must never be silently promoted.
create type derivation_confidence as enum ('low','medium','high');

-- ---------------------------------------------------------- ingest_runs ----
-- Every load records what it read and when NCDOT says that data was published.
-- An export that cannot state its own vintage is not evidence, and the March
-- submittal will be asked what it was built from.
create table ingest_runs (
  id                bigint generated always as identity primary key,
  source_service    text        not null,
  source_url        text,
  -- what NCDOT/FHWA reports for the layer, not when we happened to fetch it
  published_at      timestamptz,
  publication_label text,
  started_at        timestamptz not null default now(),
  completed_at      timestamptz,
  row_count         integer,
  rows_inserted     integer,
  rows_updated      integer,
  status            text        not null default 'running'
                    check (status in ('running','ok','failed')),
  error             text,
  notes             text
);
comment on table  ingest_runs is
  'One row per load from an upstream service. published_at is the vintage NCDOT or FHWA reports for the data, which is what an export cites — not the time we fetched it.';
comment on column ingest_runs.publication_label is
  'The service''s own words for its vintage (e.g. "2024 Q3"), kept verbatim alongside the parsed timestamp.';

create index ingest_runs_service_idx on ingest_runs (source_service, completed_at desc);

-- --------------------------------------------------------- hpms_routes -----
-- FHWA's published HPMS submittal for NC, ~213k route IDs. BH06-3 is a real
-- test only because this exists. county_id is FIPS — HPMS keys on FIPS while
-- NCDOT keys on SAP, and conflating the two silently fails a whole county.
create table hpms_routes (
  hpms_year     smallint not null,
  route_id      text     not null,
  county_id     smallint,
  begin_point   numeric(12,3),
  end_point     numeric(12,3),
  ingest_run_id bigint references ingest_runs(id),
  primary key (hpms_year, route_id)
);
comment on table  hpms_routes is
  'FHWA''s published HPMS submittal, one row per route per year. Presence is BH06-3; begin/end bound the milepoint.';
comment on column hpms_routes.county_id is
  'FIPS county code, as HPMS publishes it. NCDOT''s own 11-digit route ID ends in the SAP code instead — see county_codes.';

create index hpms_routes_county_idx on hpms_routes (hpms_year, county_id);

-- --------------------------------------------------------- county_codes ----
-- The SAP/FIPS crosswalk, needed to ask HPMS about an NCDOT route at all.
create table county_codes (
  sap_code     char(3) primary key,
  county_name  text    not null unique,
  fips_code    smallint unique,
  dot_division smallint
);
comment on table county_codes is
  'NCDOT SAP county code (last three digits of an 11-digit route ID) to county name and FIPS. LRS measures are county-scoped and reset to zero at every county line.';

-- -------------------------------------------------------- route_extents ----
-- The materialised ROUTELEN: how far a route actually runs inside one county.
-- A milepoint outside this range cannot be right, however well-formed it is.
create table route_extents (
  route_id      text primary key,
  min_mp        numeric(12,3) not null,
  max_mp        numeric(12,3) not null,
  segment_count integer,
  measured_at   timestamptz not null default now(),
  ingest_run_id bigint references ingest_runs(id),
  constraint route_extents_ordered check (max_mp >= min_mp)
);
comment on table route_extents is
  'Measured extent of each 11-digit route within its county, from NCDOT Road Characteristics. Mileposts are county-scoped, so these are county extents by construction.';
