-- ============================================================================
-- structures and features
-- ============================================================================

create table structures (
  -- The bridge number is the natural key: it is what NCDOT, FHWA, the
  -- structures service and every inspector already use. A surrogate id would
  -- add a join and an opportunity to mismatch, and buy nothing.
  structure_number text primary key
                   check (structure_number = btrim(structure_number)
                          and structure_number <> ''),

  county_name      text references county_codes(county_name),
  county_sap       char(3) references county_codes(sap_code),
  division         smallint,

  -- Published descriptive text, kept verbatim. FTR_INTRSC is what the
  -- structure crosses; F_CARRIED is what it carries. Both are free text and
  -- frequently stale after a redesignation, which is exactly why the derived
  -- and reviewed layers exist — but the published words stay untouched.
  feature_carried    text,
  feature_intersected text,

  -- geography, not geometry: distances come out in metres on the sphere
  -- without anyone remembering to project first.
  location         geography(Point,4326),

  -- SNBI structure inventory join (NCDOT_DynamicStructures). Named as SNBI
  -- names them so the mapping to SNBI_FIELDS stays legible.
  structure_type          text,
  service_on              text,
  service_under           text,
  structure_length        numeric(10,2),
  bridge_deck_width       numeric(10,2),
  bridge_road_width       numeric(10,2),
  approach_road_width     numeric(10,2),
  fed_skew                smallint,
  through_lanes_on        smallint,
  year_built              smallint,
  deck_condition          text,
  superstructure_condition text,
  substructure_condition  text,
  culvert_condition       text,
  last_inspect_date       date,
  scour_critical          text,
  fracture_critical       text,
  posted_open_closed      text,
  nhs                     text,
  functional_class        text,
  owner_code              text,
  maint_responsible       text,
  legacy_inventory_route  text,
  adt                     integer,
  adt_year                smallint,

  ingest_run_id    bigint references ingest_runs(id),
  first_seen_at    timestamptz not null default now(),
  last_seen_at     timestamptz not null default now()
);

comment on table structures is
  'One row per structure in the NCDOT bridge layer, keyed on bridge number. Note this population is wider than the NBI: it also holds sign structures and pipes, which carry no highway and require no BH06.';
comment on column structures.service_on is
  'SNBI ServiceOn. "Highway" here is the authoritative test of whether BH06 applies at all; the carried-description text is only a fallback.';
comment on column structures.location is
  'Published coordinates. geography so that distance to a milepoint comes back in metres without a projection step.';

-- The spatial index. Everything that asks "what route is near this structure"
-- goes through it.
create index structures_location_gix on structures using gist (location);
create index structures_county_idx    on structures (county_name);
create index structures_division_idx  on structures (division);
create index structures_type_idx      on structures (structure_type);

-- ------------------------------------------------------------- features ----
create table features (
  id               uuid primary key default gen_random_uuid(),
  structure_number text not null references structures(structure_number)
                     on update cascade on delete cascade,

  -- B.F.01 — H01, H02, R01, W01 ...
  designation      text not null
                     check (designation ~ '^[A-Z][0-9]{2}$'),
  -- B.F.02 — carried on the structure, or passing below it
  location_type    feature_location not null,
  feature_name     text,

  -- How this feature's values were arrived at, when the feature itself was
  -- created by derivation rather than read from the published inventory.
  derivation_method text,
  confidence        derivation_confidence,
  computed_at       timestamptz,
  computed_by       text,

  created_at       timestamptz not null default now(),

  -- One H01 per structure, one R01 per structure. This is the constraint that
  -- stops a second derive silently creating a duplicate highway feature.
  unique (structure_number, designation)
);

comment on table features is
  'The SNBI FEATURE level. BH06/BH07 belong to a highway feature, one pair per feature — concurrent route designations on the same deck are route records beneath a single feature and do NOT get their own BH06.';
comment on column features.location_type is
  'B.F.02. Only location_type = C (carried) can legitimately carry BH06/BH07. A highway with location_type = B is the road underneath.';
comment on column features.confidence is
  'Set when the feature came from derivation. low means the answer may be the road underneath and must be confirmed before use.';

create index features_structure_idx on features (structure_number);
create index features_highway_idx   on features (structure_number)
  where designation like 'H%' and location_type = 'C';
