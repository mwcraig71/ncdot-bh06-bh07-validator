# Tests

Five Playwright suites. Every endpoint is mocked — NCDOT, FHWA, Supabase, the auth
service and all six tile hosts — so none of them needs network access, and none of
them can pass because a live service happened to answer.

```bash
npm install playwright leaflet @supabase/supabase-js
node tests/data.test.js        dist/NCDOT_BH06_BH07_Validator.html
node tests/basemap.test.js     dist/NCDOT_BH06_BH07_Validator.html
node tests/corrections.test.js dist/NCDOT_BH06_BH07_Validator.html
node tests/auth.test.js        dist/NCDOT_BH06_BH07_Validator.html
node tests/features.test.js    dist/NCDOT_BH06_BH07_Validator.html
```

Each takes a build as its argument and should pass on all three: `dist/`, the
artifact build, and `docs/index.html`.

---

`data.test.js` — **36 assertions**, the reference-data layer. It replaces the
request-counting cache suite, whose question ("does the tool stop re-pulling
reference data on every run?") the ingest made moot: the browser does not pull
reference data at all now. What is asserted instead is that the reads it *does*
make are scoped to the counties on screen, that they page past PostgREST's
1,000-row ceiling, that deep check is two reads rather than 434 measurements, and
that the four services the ingest owns — `CountyBdy`, `DynamicStructures`, the
road-network statistics endpoint and `geo.dot.gov` — are never contacted from a
reviewer's machine. It also pins the failure paths: a dead database is reported
rather than drawn as an empty state, a refused reload says so, and reloading
while signed out asks the server for nothing.

`basemap.test.js` blocks tile hosts one at a time and asserts the map finds
another one — Esri → Esri mirror → USGS → CARTO → NCDOT-rendered → county
outlines. It also checks the Web Mercator envelope the NCDOT export layer builds
for each tile, and that a host outside the automatic chain can still be chosen by
hand.

`corrections.test.js` proves a reviewer's corrected BH06/BH07 is actually
validated: that a wrong correction fails, a right one clears the finding it was
meant to fix, withdrawing one restores the published verdict exactly, corrections
feed the duplicate pre-pass, a changed value invalidates the cached Locate offset,
and both v1 and v2 review files round-trip. It also pins CSV column alignment —
the header declared `OFFSET_FT` and the rows never emitted it, which shifted every
later column by one.

`auth.test.js` asserts the password gate is gone from the shipped file — no
`isAdmin`, `needAdmin`, `sha()`, `AUTH`, `ROLE`, `PRISTINE`, no gate overlay, no
`type="password"` anywhere — that a signed-out visitor can still read, filter and
export everything, that the reviewer name comes from the account rather than a
text box, and that forcing `SESSION.user` from the console gets the buttons back
and buys nothing, because the token is what the database checks.

`features.test.js` asks two questions, and the second is why the first is hard.

Can the tool tell a road passing *beneath* a structure from a road running *alongside* it on a
sister deck? Its fixture is a real one — NC-51 northbound and southbound over US-74 in
Mecklenburg, 51 ft apart, with geometry captured off NCDOT's live services — and it asserts that
each structure returns US-74 and **neither returns the other's carried route**. It also asserts
that the shared road beneath is not deduplicated, because a road under a twin pair is genuinely a
feature of both.

Then: can a structure be expressed as a set of features? Its second fixture is 590819, I-85 over
I-485, which carries both directions of I-85 on one deck. The suite asserts that the southbound
carriageway is classified as *carried* rather than as a road beneath (parallel, inside the
footprint, claimed by no neighbour), that both I-485 carriageways are found beneath, that carried
features are numbered before below features, that route designations restart at R01 inside each
feature, and that co-signed routes stay one feature with two route records.

Its last section feeds the tool the 24 September 2025 inspection report's own numbering — H05
carried after three below features, R01 through R05 running straight across — and asserts that
the tool flags the pattern instead of reproducing it.

`fx/sbmock.js` is the stand-in for the Supabase REST API, shared by all five. It
is a real little query engine — it honours `limit`, `offset`, `in.()` and `eq.` —
because the things worth asserting are exactly whether the client scopes its reads
and whether it pages. A mock that ignored those would pass either way.

Counts, all passing on all three builds: **36** data, **16** basemap, **37**
corrections, **37** auth, **42** features — 168 in all.

The database has its own tests under `supabase/tests/`, including one that runs
against the live project over HTTPS with the publishable key.
