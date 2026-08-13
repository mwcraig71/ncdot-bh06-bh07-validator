# Database

Postgres 17 on Supabase, project **`drstmntdbmacdplhjvmx`** — *NCDOT SNBI BH06 BH07*,
region `us-east-1`, created for this work so it shares nothing with the TxDOT or Bridge SHM
projects.

Everything here was applied as a migration. There is no ad-hoc SQL in the schema's history:
`supabase/migrations/` is the whole of it, and the files are byte-identical to what the
database actually ran (verified by comparing each file's MD5 against
`supabase_migrations.schema_migrations`).

```bash
supabase link --project-ref drstmntdbmacdplhjvmx
supabase db push          # apply
supabase db reset         # rebuild from zero, locally
psql "$DATABASE_URL" -f supabase/tests/round_trip.sql   # verify
```

---

## The shape of it

SNBI's own hierarchy, not the bridge layer's column names, because the hierarchy is what the
data actually is:

```
structures            one row per bridge number (natural key)
  └── features        SNBI FEATURE. B.F.01 designation (H01, R01, W01…),
                      B.F.02 location (C carried / B below)
        ├── feature_values     one row per (field, source)
        ├── findings           current rule failures
        │     └── cleared_findings   clear/restore, as events
        └── review             status and note
```

**BH06/BH07 belong to a feature, not a structure.** Concurrent route designations on one deck
are route records beneath a single highway feature and get a *single* BH06/BH07 pair. Making
the feature the grain is what stops that being re-litigated in application code.

Only a feature with `designation like 'H%'` and `location_type = 'C'` can legitimately carry
BH06/BH07. A highway feature with `location_type = 'B'` is the road *underneath* — the single
commonest wrong answer, so it is a column rather than a convention.

## Sources are rows, not columns

`feature_values` is keyed `(feature_id, field, source)` where source is
`PUBLISHED` / `DERIVED` / `REVIEWED`.

That key is the whole point. A derivation pass upserts on
`(feature, field, 'DERIVED')` and there is **no statement it can write that reaches the
REVIEWED row**, because that row has a different key. The hierarchy is a property of the
schema, not a rule someone has to remember. Three further things enforce it:

- a trigger makes `(feature_id, field, source)` immutable, so a DERIVED row cannot be
  relabelled REVIEWED and launder a guess into a human decision;
- RLS lets an authenticated client write `REVIEWED` and `DERIVED` rows only — `PUBLISHED`
  belongs to ingest, which runs as the service role, and is invisible to a client UPDATE;
- precedence is the **enum declaration order**. `value_source` is declared weakest-first, so
  the winner is `max(source)` and `order by source desc` picks it. Reorder that enum and you
  have changed the precedence of the entire system; there is nowhere else to look.

Absence of a row means the source has no value. A feature with no `PUBLISHED` BH06 row is one
NCDOT publishes nothing for — that is the null, and it needs no sentinel.

## What is deliberately *not* constrained

No 120-character limit on BH06. No 8-digit limit on BH07. No requirement that a route exists.

The purpose of this database is to find values that break those rules. A constraint rejecting
them at INSERT would mean the worst data in the state could never be loaded, and therefore
could never be reported. **Validity is a finding, not a constraint.** The constraints that do
exist are structural: a value belongs to a feature, two sources cannot collide, a source
cannot change identity.

## Reading it

`feature_resolved` is the object the application reads — one row per feature with the BH06 and
BH07 under test, the source that won, and NCDOT's published values alongside so a panel can
show "testing X, NCDOT publishes Y" without a second query.

Nothing downstream should re-implement precedence. The browser tool validated one number and
exported another for exactly that reason.

| View | For |
|---|---|
| `feature_value_resolved` | winning row per (feature, field) |
| `feature_resolved` | one row per feature, both fields, published values alongside |
| `finding_current` | findings with the latest clear/restore decision applied |
| `structure_status` | per-structure rollup, cleared findings excluded from the counts |
| `data_vintage` | latest successful load per service — what an export cites |

All are `security_invoker`, so RLS is evaluated as the caller and a view can never be a way
around a policy.

## Clearing is an event

`cleared_findings` is an append-only log of `clear` / `restore` decisions. A restore is a later
event, never a deletion, so "why is this not an error any more" always has an answer with a
name and a date on it. UPDATE and DELETE are refused by trigger, including for the service
role.

## The audit trail

`review_history` records every change to `feature_values`, `review` and `cleared_findings` with
before/after JSONB, the list of columns that actually moved, the account, and the Postgres role.

It is written by an `AFTER` trigger, not by application code, because the one thing that must
never happen is a change reaching the table while the write that records it does not. Any
client, any script, any statement typed into the dashboard lands in it. The March submittal has
to answer who changed what, and that cannot be reconstructed afterwards.

`actor_role` exists alongside `actor` because `auth.uid()` is null outside a request context —
it is what distinguishes an authenticated reviewer from a service-key job or a hand-run
statement.

## Access

Two layers, because they fail differently. **Grants** are coarse and refuse loudly —
`permission denied for table`, which a client cannot mistake for success. **RLS** is
fine-grained and refuses quietly. So the blunt rules are grants and the conditional ones are
policies.

| | anon | authenticated | service_role |
|---|---|---|---|
| read everything, including `review_history` | yes | yes | yes |
| write `REVIEWED` corrections | no | yes | yes |
| write `DERIVED` values, upsert `features` | no | yes — *Fill missing* runs in the browser | yes |
| write `review`, `cleared_findings` | no | yes | yes |
| write `PUBLISHED` | no | **no** | yes |
| write structures, findings, HPMS, extents, ingest_runs | no | **no** | yes |
| **DELETE anything** | **no** | **no** | only structures/features |
| edit or delete audit / clearing history | no | no | **no** |

Read is open because every input is already published by NCDOT and FHWA, and the tool being
useful without a login is the point of it. The audit trail is public too: it is the provenance
of a public submittal, and a trail nobody can inspect is worth less than one they can — which
is safe precisely because `reviewer_name` is a display name and never an address.

**No client role has DELETE on any table.** Corrections supersede. Withdrawing one sets
`withdrawn_at`, which leaves the row, its author and its history in place and lets resolution
fall back to the next source down on its own. A cleared finding is restored by a later event.
`features` in particular is undeletable by a client because it cascades — a reviewer able to
drop a feature could erase a correction sideways without ever touching `feature_values`.

A `PUBLISHED` row is not merely protected from being changed: the UPDATE policy's `USING`
clause excludes it, so it is **invisible to a client UPDATE entirely** and the statement
reports zero rows affected.

## Identity is stamped, not submitted

`actor` and `reviewer_name` are overwritten from the request's JWT by a `BEFORE` trigger.
Whatever the client sends in those columns is discarded. RLS could already have rejected a
wrong `actor`; nothing could have rejected a wrong *name*, and the name is what a person reads
in an export.

The display name prefers what the account has set and otherwise falls back to the **local part**
of the email, never the whole address — `reviewer_name` is readable on a public page.

The trigger keys on the presence of a `sub` claim rather than on a role name, because a
`SECURITY DEFINER` function cannot see who called it (`current_user` is the function's owner).
An ingest or derive job carries no `sub`, writes on behalf of nobody, and leaves `actor` null,
which is the honest record of what happened.

**RLS filters; it does not raise.** A denied UPDATE affects zero rows and reports success.
Anything written against this database must check the affected row count rather than trusting
the absence of an error — `round_trip.sql` asserts this explicitly so the behaviour is on the
record.

## Verification

`tests/round_trip.sql` runs two blocks, each ending in a deliberate exception so the
transaction rolls back and nothing persists. Block 1 covers resolution, constraints, the audit
trail and clearing. Block 2 switches Postgres roles so the RLS policies are genuinely
exercised — a test that runs as the table owner bypasses RLS and proves nothing.

`tests/anon_api_test.sh` is the stronger half of the same question: it hits PostgREST over
HTTPS with the publishable key, so grants, RLS and the API layer are exercised together rather
than simulated with `SET ROLE`.

```bash
supabase/tests/anon_api_test.sh
```

Current state: **24 assertions in block 1, 25 in block 2, 32 over the API — all passing.** Both
database advisors report clean, apart from `unused_index` notices that are expected while the
tables are empty.

A missing policy fails open in the direction that is hardest to notice, so none of this is
asserted from reading the migration. It is asserted from a session that actually tried.

## Still to come

Ingest writes `structures`, `features`, `PUBLISHED` values, `route_extents`, `hpms_routes`
and `ingest_runs` as the service role. Validation writes `findings`. Neither exists yet, and
the schema denies both to every client role until they do.
