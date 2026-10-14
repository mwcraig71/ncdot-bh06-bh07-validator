# Code review brief: NCDOT SNBI BH Validator

You're reviewing a working web app from top to bottom. Find what is wrong, fragile, unsafe or
misleading, and report it. **Don't fix anything until the findings have been read and the owner
has said which to fix.** The owner is Michael Craig, a bridge engineer, not a software developer.
Write the findings so he can decide on them without reading code.

## What the app is

A browser tool for checking North Carolina bridge records before they go to FHWA under the
Specifications for the National Bridge Inventory (SNBI). It checks:

- **BH06** (LRS route ID) and **BH07** (LRS milepoint) against FHWA's rules and NCDOT's live GIS
  (the core of the tool)
- **BH09 to BH11**: traffic (AADT, trucks, count year)
- **B.H.17**: detour length. NCDOT's coded value sits beside a detour measured statewide on an
  OpenStreetMap road graph.

A reviewer picks a bridge, a route, a county or the whole state. The tool pulls NCDOT's bridge
layer and runs the checks, and shows the results on a map, in a table and in a per-bridge panel.
Results export as CSV. Signed-in reviewers can record corrections and approvals, and field users
on a phone can drop a pin on a road to read its route and milepoint.

Live: https://mwcraig71.github.io/ncdot-bh06-bh07-validator/
Repo: https://github.com/mwcraig71/ncdot-bh06-bh07-validator

## How it's built

| Part | Where | Notes |
|---|---|---|
| The app | `src/tool_template.html` | About 5,900 lines in one HTML file. All CSS and JS are inline. **This is the single source of truth.** |
| Build | `src/build.py`, `npm run build` | Injects the Supabase URL and anon key, the logo and fonts. Writes three builds. |
| Builds | `dist/NCDOT_BH06_BH07_Validator.html`, `dist/..._artifact.html`, `docs/index.html` | Self-contained (Leaflet and fonts inlined), artifact, and the GitHub Pages site. Never edit these by hand. |
| Backend | Supabase project `drstmntdbmacdplhjvmx` | Postgres with row level security. Anon can SELECT and nothing more. |
| Schema | `supabase/migrations/` (43 files, 0001 to 0043) | Read in order. Each file name says what it does. |
| Ingest | `supabase/functions/ingest-*`, `_shared/ingest.ts` | Edge functions that load NCDOT, FHWA HPMS and traffic reference data on a schedule. The browser never pulls this reference data itself. |
| Detour pipeline | `tools/detour/`, `tools/detour_probe.py` | Offline. Self-hosted Valhalla on the NC OSM extract of 12 Oct 2026. Results are in table `detour_measured`. |
| Tests | `tests/*.test.js`, `tests/fx/` | Ten Playwright suites with every endpoint mocked. 497 assertions per build, all passing. See `tests/README.md`. |
| Docs | `README.md`, `guide/BH06_BH07_Validator_guide.md` | The guide is the user manual. Check the code against what it promises. |

Running it:

```bash
npm install
# Tests run against the committed builds; no network needed:
for s in data basemap corrections auth features columns field approvals traffic detour; do
  node tests/$s.test.js dist/NCDOT_BH06_BH07_Validator.html; done
```

To rebuild, set `LOGO_PATH` to any PNG first. The real logo is not in the repo. Before you
rebuild, check that the build reproduces the committed `dist/` files exactly. If it doesn't, say
so and don't commit the rebuilt files.

## What to review, in priority order

### 1. Correctness of the answers (most important)

A wrong BH06 or BH07 that passes FHWA's checks is the worst outcome. The tool exists to catch
those.

- **Route and milepoint logic.** Check RID decoding, the carried-versus-beneath feature engine,
  and twin-structure and parallel-road handling (search `deckContext`, `classifyCandidate`,
  `featuresOf`). Also check milepoint rounding to 3 decimal places and the county-reset LRS
  semantics. Are there inputs that give a confident wrong answer?
- **The rules list (`RULES`, `RULEMAP`).** Does each rule fire when it says it does, and nowhere
  else? Do severities match what the text claims? Look for rules that can never fire, or that
  fire on missing data.
- **Pin drop** (`pinAt`, `pinNCDOT`, `pinLocal`, `gpTool`). NCDOT's GP tool currently fails on
  their server, so the pin falls back to the Road Characteristics layer's M values. Check that the
  fallback really gives the same answer as the GP tool would. The pin attaches its result to the
  armed bridge feature (`PINTARGET`, `PENDPIN`): check that it can never write to the wrong
  bridge or feature.
- **Traffic** (`loadTraffic`, `trafficAt`, `trafficFlags`). Check segment matching on a route and
  measure, the station versus probe-estimate basis, and the year (BH11).
- **Detour** (`bh17`, `detourOf`, `detourFlags`, `detourVal`, `detourPop`, `pinNearestStructure`).
  Check the decoding of 0, 99 and 199, the thresholds on the four DETOUR_ findings, and that a
  missing or failed read is never shown as "no detour" or as 0.
- **CSV export.** Check that columns and rows stay aligned for every structure type, and that
  quoting and escaping are right (commas, quotes, newlines in names). Make sure nothing exports as
  0 when it should be blank.

### 2. Security and data integrity

- **Row level security.** Read every migration's policies. Can the anon role write anything? Can
  a signed-in reviewer approve their own work, change another reviewer's rows, or escalate a role?
  Migration 0041 (first approver) and the approvals flow deserve a close look.
- **Write paths.** `ingest_detour` and the other ingest RPCs are guarded by a token in
  `ingest_secret`. Migration 0043 revokes the detour write path after the load. Confirm each
  write path is closed or properly guarded.
- **Secrets.** Only the anon key and publishable key should appear in the page or the repo. That
  is by design (see the comment in `build.py`). Flag anything else that looks secret, but **never
  print a secret's value** in your findings.
- **XSS.** Values from NCDOT, FHWA, OSM and other reviewers are rendered as HTML in many places.
  Find every `innerHTML` and string-built HTML that doesn't pass through `esc()`.
- **Edge functions.** Check auth on each function, input validation, and what happens on partial
  failure. Is the resume cursor in migration 0040 safe to re-run?

### 3. Robustness

- **External services.** The app depends on NCDOT ArcGIS (gis11.services.ncdot.gov), FHWA, the
  tile hosts and Supabase. What does the user see when each is slow, down, renamed or returns an
  error? Silent failures and endless spinners are bugs.
- **Paging and limits.** ArcGIS caps queries at 2,000 records and PostgREST at 1,000 rows. Check
  every query loop for a stop condition that can end early or loop forever.
- **State.** Check global state (`ALL`, `VIEW`, `SEL`, `PINTARGET`, `DETOUR`, `REVIEW`) across
  re-runs, county switches and sign-in or sign-out. Look for stale data shown against a new run.
- **Performance** on a statewide run (about 23,000 structures): rendering, filtering, sorting,
  memory. Is anything quadratic?

### 4. Phone and field use

Inspectors use this on an iPhone in the field.

- Check at 390×844 (iPhone 13; Playwright's `devices['iPhone 13']` works): the field bar, the
  panel, the pin popup (which should scroll, with BH06, BH07, AADT and both detours at the top),
  the table and the filters.
- Look for anything that can't be reached, overlaps, needs hover, or uses tap targets under 44 px.
- What happens offline or on a weak signal ("Map" saves tiles for offline use)?

### 5. Code health

Only raise what matters. Don't propose a framework or a rewrite.

- Duplicate or shadowed function names. One was found and fixed recently (`nearestStructure`
  was defined twice and the later definition won silently). Look for others.
- Dead code, unused rules, stale comments that contradict the code.
- Places where the guide or README promises something the code doesn't do, or the reverse.
- Test gaps. Which risky paths above have no assertion? Suggest the specific tests to add.

## Constraints

- **Keep the single-file design.** The deliverable is one HTML file that works offline and is
  emailed to people. Don't split it, add a bundler or add a framework.
- **Don't run anything against the live Supabase project that writes, deletes, grants or
  revokes.** Read-only queries are fine if you have access. Any SQL fix goes in a new numbered
  migration file for the owner to apply himself.
- **Don't change what a check means** (thresholds, rule text, LRS semantics) without flagging it
  as a judgement call for the owner.
- **Don't push to GitHub.** Commit on a branch, or leave the changes uncommitted, and report.
- **Keep the tests passing.** All ten suites must pass on all three builds after any change.

## What to hand back

One markdown file, `REVIEW_FINDINGS.md`, with:

1. **A summary** of five to ten lines: overall state, and the three most important problems.
2. **Findings**, most severe first. For each one:
   - **Severity:**
     - Critical: a wrong answer shown as right, a security hole, or data loss
     - High
     - Medium
     - Low
   - **Where:** file and line, or function name
   - **What's wrong**, in plain English
   - **How to see it:** the exact steps, input, or a failing test
   - **Suggested fix**, and roughly how big it is
   - **Judgement call?** Yes, if it changes what the tool tells users
3. **Verified OK:** the areas you checked and found sound, so the owner knows they were covered.
4. **Tests you'd add**, as a list.

Separate what you confirmed by running something from what you suspect from reading. Mark each
finding **Confirmed** or **Suspected**.
