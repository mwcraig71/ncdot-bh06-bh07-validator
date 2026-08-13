-- ============================================================================
-- feature_values, findings, cleared_findings, review
--
-- A note on what is and is not constrained here. These tables enforce
-- STRUCTURAL invariants: a value belongs to a feature, two sources cannot
-- collide, a source cannot change identity. They deliberately do NOT enforce
-- the FHWA rules — no 120-character limit on BH06, no 8-digit limit on BH07,
-- no requirement that a route exists. The entire purpose of the system is to
-- find values that break those rules, and a constraint that rejects them at
-- INSERT would mean the worst data in the state could never be loaded, and so
-- could never be reported. Validity is a finding, not a constraint.
-- ============================================================================

create table feature_values (
  id            uuid primary key default gen_random_uuid(),
  feature_id    uuid not null references features(id) on delete cascade,
  field         snbi_field   not null,
  source        value_source not null,

  -- BH06 is an identifier, BH07 a measure. Two typed columns beat one text
  -- column: the milepoint stays comparable to route_extents without casting.
  value_text    text,
  value_num     numeric(12,3),

  -- PUBLISHED provenance
  ingest_run_id bigint references ingest_runs(id),

  -- DERIVED provenance
  derivation_method text,
  confidence        derivation_confidence,
  offset_ft         numeric(10,2),

  -- REVIEWED provenance. actor is the account; reviewer_name is what they
  -- typed, kept because a name outlives an account.
  actor         uuid references auth.users(id),
  reviewer_name text,
  note          text,

  recorded_at   timestamptz not null default now(),

  -- The rule that makes the hierarchy enforceable rather than aspirational.
  -- A derive upserts on (feature, field, DERIVED) and can only ever land on
  -- its own row; there is no statement it can write that reaches the REVIEWED
  -- row, because that row has a different key.
  unique (feature_id, field, source),

  -- exactly one typed column, matching the field
  constraint feature_values_typed check (
    (field = 'BH06' and value_text is not null and value_num  is null) or
    (field = 'BH07' and value_num  is not null and value_text is null)
  )
);

comment on table feature_values is
  'One row per (feature, field, source). Sources are rows, not columns, so a derive writes only its own row and structurally cannot reach a reviewer''s. Absence of a row means the source has no value: a feature with no PUBLISHED BH06 row is one NCDOT publishes nothing for.';
comment on column feature_values.source is
  'PUBLISHED < DERIVED < REVIEWED. The enum is declared in that order, so precedence is the enum ordering and lives in one place.';
comment on column feature_values.confidence is
  'DERIVED only. low means the value may be the road underneath rather than the road carried.';

create index feature_values_feature_idx on feature_values (feature_id, field);
create index feature_values_source_idx  on feature_values (source, recorded_at desc);
-- BH06 lookups against HPMS and route_extents go through the value itself
create index feature_values_route_idx    on feature_values (value_text)
  where field = 'BH06';

-- A source cannot change identity. Without this, a derive could take its own
-- row and relabel it REVIEWED, which would launder a guess into a human
-- decision and defeat the whole arrangement.
create or replace function feature_values_source_is_immutable()
returns trigger language plpgsql as $$
begin
  if new.source is distinct from old.source
     or new.field is distinct from old.field
     or new.feature_id is distinct from old.feature_id then
    raise exception
      'feature_values.(feature_id, field, source) is immutable: % / % / % cannot become % / % / %. Write to the row that already carries that key instead.',
      old.feature_id, old.field, old.source, new.feature_id, new.field, new.source;
  end if;
  return new;
end $$;

create trigger feature_values_no_relabel
  before update on feature_values
  for each row execute function feature_values_source_is_immutable();

-- ------------------------------------------------------------- findings ----
create table findings (
  id            uuid primary key default gen_random_uuid(),
  feature_id    uuid not null references features(id) on delete cascade,
  rule_id       text not null,
  severity      finding_severity not null,
  rule_code     text,
  detail        jsonb,

  -- Which resolved source the check actually ran against. A finding raised on
  -- a reviewer's correction means something different from the same finding
  -- raised on NCDOT's published value, and the export has to say which.
  evaluated_source value_source,

  computed_at   timestamptz not null default now(),
  computed_by   text,

  unique (feature_id, rule_id)
);
comment on table findings is
  'Current findings, replaced on each validation pass. evaluated_source records which value the rule was tested against.';

create index findings_rule_idx     on findings (rule_id);
create index findings_severity_idx on findings (severity);

-- ----------------------------------------------------- cleared_findings ----
-- Clearing is an event, not a flag. Restoring is another event. Nothing is
-- deleted, so the sequence of decisions survives and "why is this not an
-- error any more" always has an answer with a name and a date on it.
create table cleared_findings (
  id          uuid primary key default gen_random_uuid(),
  feature_id  uuid not null references features(id) on delete cascade,
  rule_id     text not null,
  action      text not null check (action in ('clear','restore')),
  reason      text,
  actor       uuid references auth.users(id),
  reviewer_name text,
  created_at  timestamptz not null default now()
);
comment on table cleared_findings is
  'Append-only log of clear/restore decisions. The current state of a finding is its latest event; earlier decisions are never overwritten.';
comment on column cleared_findings.reason is
  'Required in practice by policy for action = clear — the record should read "cleared by X on date: checked with Div 10, ramp is correct as coded".';

create index cleared_findings_current_idx
  on cleared_findings (feature_id, rule_id, created_at desc);

-- Nothing may edit or remove a decision once made.
create or replace function append_only_guard()
returns trigger language plpgsql as $$
begin
  raise exception '% is append-only; % is not permitted. Record a new event instead.',
    tg_table_name, tg_op;
end $$;

create trigger cleared_findings_append_only
  before update or delete on cleared_findings
  for each row execute function append_only_guard();

-- --------------------------------------------------------------- review ----
create table review (
  feature_id    uuid primary key references features(id) on delete cascade,
  status        review_status,
  note          text,
  actor         uuid references auth.users(id),
  reviewer_name text,
  updated_at    timestamptz not null default now()
);
comment on table review is
  'Reviewer status and notes, one row per feature. Corrections are not here — they are REVIEWED rows in feature_values, so that a correction is a value with a source rather than a note about a value.';

create index review_status_idx on review (status);
