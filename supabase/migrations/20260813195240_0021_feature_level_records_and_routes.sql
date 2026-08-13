-- ============================================================================
-- Feature-level records
--
-- Until now a structure had at most one feature, created only where the bridge
-- layer said SERVICEON = '1'. That was two mistakes in one line. A structure
-- can carry more than one highway feature and can have any number of highways
-- beneath it, each with its own BH06, BH07, findings and review; and '1' is not
-- the set of codes that means "a highway is carried".
--
-- The hierarchy SNBI actually specifies is three deep, and it is now three deep
-- here:
--
--   FEATURE  (B.F)   one per roadway, carried or below
--     ROUTE  (B.RT)  one per designation signed on that roadway
--     HIGHWAY(B.H)   BH06/BH07 - one pair per FEATURE, never per route
--
-- The middle level is what stops concurrency multiplying features. I-77 and
-- US-21 co-signed on one deck are two ROUTE records under one FEATURE, and
-- therefore one BH06/BH07 pair. That was already the rule; it now has a table
-- to live in rather than a convention to be remembered.
-- ============================================================================

-- ---------------------------------------------------------------- features --
alter table features
  add column feature_seq        smallint,
  add column is_primary         boolean not null default false,
  add column route_id_hint      text,
  add column source_report      text,
  add column admitted_by        text,
  add column crossing_angle_deg numeric(5,2),
  add column expected_angle_deg numeric(5,2),
  add column footprint_hit      boolean,
  add column neighbour_carrier  text,
  add column withdrawn_at       timestamptz;

comment on column features.feature_seq is
  'Ordinal behind the designation. H01 is 1. Carried features occupy the low numbers, in the order the deck carries them; below features follow, primary first. Stored rather than parsed out of the designation so the ordering rule is queryable.';
comment on column features.is_primary is
  'The principal roadway for its location. Exactly one carried feature and at most one below feature may hold it. The primary below feature is the one the crosswalk numbers immediately after the carried features.';
comment on column features.admitted_by is
  'How a derived feature earned its place: footprint+skew, footprint+skew+neighbour, or buffer-fallback. Null on features that came from the published inventory. A reviewer should be able to see which test admitted a road they did not expect.';
comment on column features.neighbour_carrier is
  'Set where a candidate route was refused because a neighbouring structure carries it. Holds that structure number, so the refusal is auditable instead of silent.';
comment on column features.withdrawn_at is
  'A derived feature a reviewer rejected. Withdrawn, never deleted - the same rule corrections follow.';

-- One primary per (structure, location). Two primary carried roadways is a
-- contradiction, not a preference.
create unique index features_one_primary_per_location
  on features (structure_number, location_type) where is_primary;

create unique index features_seq_unique
  on features (structure_number, feature_seq) where withdrawn_at is null;

-- ----------------------------------------------------------- feature_routes -
-- B.RT. The designation restarts at R01 inside every feature. NCDOT's own
-- reports number them continuously across the whole structure - 590819 runs
-- R01 to R05 across five features - so the composite key is what makes the
-- difference visible rather than a matter of opinion.
create table feature_routes (
  id                uuid primary key default gen_random_uuid(),
  feature_id        uuid not null references features(id) on delete cascade,

  route_designation text not null,                       -- B.RT.01  R01, R02...
  route_number      text,                                -- B.RT.02
  route_direction   text,                                -- B.RT.03  NB, SB, EB, WB, CW, CC
  route_type        smallint,                            -- B.RT.04
  service_type      smallint,                            -- B.RT.05

  lrs_route_id      text,                                -- the 11-digit ID this designation resolves to
  is_inventory      boolean,                             -- the direction NCDOT measures
  source            value_source not null default 'PUBLISHED',
  reported_seq      smallint,                            -- what the source document called it, verbatim
  created_at        timestamptz not null default now(),

  constraint route_designation_shape check (route_designation ~ '^R[0-9]{2}$'),
  unique (feature_id, route_designation)
);

comment on table feature_routes is
  'B.RT route records. Concurrent designations on one roadway are rows here, not extra features: co-signed routes share one deck and therefore one BH06/BH07 pair. reported_seq keeps whatever number the source document used, so a report that numbers R01..Rnn straight through the structure can be recognised without being reproduced.';
comment on column feature_routes.reported_seq is
  'The numeric part of the designation as the source document wrote it. Where it disagrees with route_designation the document numbered routes continuously across features instead of restarting at R01 within each - a finding, not a correction to apply silently.';

create index feature_routes_feature_idx on feature_routes (feature_id);
create index feature_routes_lrs_idx on feature_routes (lrs_route_id);

alter table feature_routes enable row level security;
create policy read_all on feature_routes for select to anon, authenticated using (true);
create policy write_routes on feature_routes for insert to authenticated with check (true);
create policy update_routes on feature_routes for update to authenticated using (true) with check (true);
grant select on feature_routes to anon;
grant select, insert, update on feature_routes to authenticated;

-- ---------------------------------------------------------- structure_twins -
-- Two decks carrying opposing directions of one divided facility. Recorded on
-- both rows because the fact is symmetric, and surfaced to reviewers because a
-- silent exclusion is indistinguishable from a missing feature.
create table structure_twins (
  structure_number  text not null references structures(structure_number) on delete cascade,
  twin_number       text not null references structures(structure_number) on delete cascade,
  separation_ft     numeric(7,1),
  carried_route     text,
  twin_route        text,
  detected_at       timestamptz not null default now(),
  ingest_run_id     bigint references ingest_runs(id),
  primary key (structure_number, twin_number),
  constraint twins_are_distinct check (structure_number <> twin_number)
);

comment on table structure_twins is
  'Sister structures: within about 250 ft, carrying routes that decode to the same class and number but a different inventory digit. Each is a separate bridge number with its own deck, so neither is a feature of the other however close they sit. This table is what makes that exclusion auditable.';

create index structure_twins_twin_idx on structure_twins (twin_number);

alter table structure_twins enable row level security;
create policy read_all on structure_twins for select to anon, authenticated using (true);
grant select on structure_twins to anon, authenticated;
