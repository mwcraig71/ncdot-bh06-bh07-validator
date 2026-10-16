# Tests

Ten Playwright suites. Every endpoint is mocked — NCDOT, FHWA, Supabase, the auth
service and all six tile hosts — so none of them needs network access, and none of
them can pass because a live service happened to answer.

```bash
npm install          # exact versions, from package.json
node tests/data.test.js        dist/NCDOT_BH06_BH07_Validator.html
node tests/basemap.test.js     dist/NCDOT_BH06_BH07_Validator.html
node tests/corrections.test.js dist/NCDOT_BH06_BH07_Validator.html
node tests/auth.test.js        dist/NCDOT_BH06_BH07_Validator.html
node tests/features.test.js    dist/NCDOT_BH06_BH07_Validator.html
node tests/columns.test.js     dist/NCDOT_BH06_BH07_Validator.html
node tests/field.test.js       dist/NCDOT_BH06_BH07_Validator.html
node tests/approvals.test.js   dist/NCDOT_BH06_BH07_Validator.html
node tests/traffic.test.js     dist/NCDOT_BH06_BH07_Validator.html
node tests/detour.test.js      dist/NCDOT_BH06_BH07_Validator.html
```

Each takes a build as its argument and should pass on all three: `dist/`, the
artifact build, and `docs/index.html`.

Each suite prints `N passed, M failed` last and **exits 1 if anything failed**, or if it
stopped before making any assertion (`_check.js`). Before October 2026 a FAIL printed and the
suite still exited 0, so check the exit code, not just the output.

The suites look for Chromium at `/opt/pw-browsers/chromium`, where they were written. Anywhere
else, set `PW_CHROMIUM` to a Chromium executable, or leave it unset and run
`npx playwright install chromium` once so Playwright uses its own.

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

It then asserts the two things a reviewer actually does: that **opening** a bridge measures its
features without anyone running a batch pass first, that opening it twice does not measure twice,
and that the pin-drop popup no longer labels its answer "BH06 LRS Route ID" — it reports the road
at the clicked point, which at a grade separation is usually not the road the bridge carries, and
it says which of the open bridge's features that road is.

It covers the triage states, the RD_ANGLE orientation, and the pin drop being
aimed at a named feature. It feeds the tool the 24 September 2025 inspection report's own numbering — H05
carried after three below features, R01 through R05 running straight across — and asserts that
the tool flags the pattern instead of reproducing it.

Its last two sections are what the field asked for. A pin drop **asks before it
writes**: the answer is held, the panel shows the route and the milepoint it
found and offers a yes and a try-again, and nothing reaches the feature until the
yes. A reflow while a bridge is open no longer throws away the zoom — the map
frames itself once per scope, not once per redraw, which is what sent an
inspector standing under a bridge back to a county view every time the table
refilled. And removing a feature is a **request**: the feature stays in the list
and in the export, the panel says a removal was requested and that it is still
reported until somebody decides, and the request joins the value proposals in one
queue.

`columns.test.js` covers filtering on the table itself — a box under every column
heading, matching against the text in the cell rather than against a field, which is
the only way to reach the decoded label, the findings and the suggested correction.
It asserts the comparison syntax on numeric columns (`>5`, `1-2`, `<=0.5`, `-` for
nothing recorded), that a half-typed comparison hides nothing, that `!` excludes,
that filters combine, and that the CSV exports what is on screen rather than the
whole view.

`field.test.js` runs at 390x844 with touch and a geolocation fix 120 ft from a real
structure. It asserts what field mode removes — the filter panel, the tab strip, the
severity legend — and what it adds: a table that starts off screen and slides up from
the bar, a bridge already open because the phone knew where it was, a panel that leads
with BH06 and BH07 and ends with the paperwork, and Add new feature arming the pin at
the feature it just created. Then the part that matters most in a field app: a
submission is queued rather than applied, it survives the page closing because it is in
localStorage, and it goes out when the connection returns. The county itself round-trips
through IndexedDB and every structure validates again with the network switched off.

Its last two sections are the phone as it is actually held. A canvas circleMarker
is hit-tested against its own radius, so a 6 px dot was a 12 px target against a
44 px fingertip — "it works sometimes, but it's very sensitive to where you tap"
was a precise description of the bug. The suite asserts the widened hit test, that
a tap 12 px off centre still lands on the bridge, and that no sticky tooltip eats
the first tap. Then the pin, end to end, through NCDOT's route/milepost tool
mocked in its three parts: the carried feature offers the pin at all, arming it
closes the panel so the map can be reached, **closing the panel does not disarm
the pin** — that one line is the whole bug, since the close handler cleared the
selection and the measurement then arrived with nothing to attach to — the panel
reopens with the confirmation, and accepting on the carried feature corrects the
bridge's own BH06 and BH07 and queues **both** for approval. Both, because a
second submission arriving mid-flush used to be overwritten by the first one's
save, and accepting a pin drop submits BH06 and BH07 back to back.

`approvals.test.js` is about the other half of field capture, and the question it
keeps asking is not "does the button work" but "does the screen tell an approver
enough to be right". Most of it is the verdict: a milepoint past the end of its
route, a BH06 proposed on a roadway that runs *beneath* the bridge, a route ID
carrying the wrong county — all things that pass every FHWA submittal check and
are still wrong, put in front of the person about to accept them. It asserts that
a proposal correcting only BH07 is still tested, on the route the feature already
has, which is what migration 0032 put in the queue.

The rest is refusals. An anonymous visitor can read the queue and gets no
buttons; a signed-in non-approver gets none either, and is told why; a rejection
with no reason never reaches the database; accept-all takes the value proposals
on one structure and leaves the removal request alone. It covers appointing an
approver by email, the refusal when that account has never signed in, and the
refusal to revoke the last one — each arriving as the database's own sentence
rather than an HTTP code. It also pins the thing that made the view feel broken:
running a scope while the queue is open now leaves it, instead of filling a table
nobody can see.

`traffic.test.js` covers B.H.09, B.H.10 and B.H.11. The claim under test is not
"an AADT appears" — it is that the number is the **current counted** one, that it
says which year it was counted, that the truck figure is a *share* applied to
that current total rather than an older count carried forward, and that where
nothing was counted the estimate says so and carries its 95% interval. That
distinction is the whole point: the thing being replaced, the AADT on NCDOT's
bridge record, looks identical on screen and is none of those things.

One assertion earns its place on its own. `su_pct` and `mu_pct` are **fractions**,
not percentages — checked against all 12,673 NCDOT segments carrying both a truck
count and a share, 12,672 satisfy `AADTT = AADT x share` and only 398 would
satisfy `AADT x share / 100`. A stray division by a hundred would look like a
small number on one bridge and be wrong by two orders of magnitude statewide, so
the suite asserts the share is treated as a fraction *and* that the resulting
B.H.10 lands in the thousands rather than the hundreds.

It also pins the per-feature shape — the roadway beneath reports its own AADT
from its own station, not the bridge's — the four findings, the two arithmetic
checks, that correcting BH07 moves the traffic to the segment the new milepoint
falls in rather than serving a cached value, and that the CSV carries the basis,
the station, the share and its year beside each number, because a bare AADT
column would reproduce exactly the problem the group was added to fix.

Its last sections drive the pin, through NCDOT's route/milepost tool mocked in
its three parts, and assert that the popup reports B.H.09, B.H.10 and B.H.11 for
the point clicked — with the station on a counted road, the 95% interval on a
probe-covered one, and a plain refusal where nothing reaches. A pin drop and a
feature are the same question about the same stretch of road, so they get the
same answer. The confirmation card shows that traffic before the yes, and
accepting carries it onto the feature.

`detour.test.js` covers B.H.17. The claim under test is not "a detour appears".
It is that NCDOT's coded value and the measured detour are shown as **two
things**, allowed to disagree in plain view, and that a structure the statewide
run did not reach, or could not measure, says so and is never shown as a zero-mile
detour. A dead end is "No detour" in the panel, "none" in the table and
`NO DETOUR` with blank distances in the CSV. B.H.17's special codes are decoded
rather than read as distances: 0 is a bypass at the site, 99 is NCDOT's no-detour
code, and 199 is reported as a code, not as 199 miles.

The findings are pinned to fire exactly where the road network contradicts the
code and nowhere else: a detour coded on a structure that is the only way across,
a 99 with a way around, and a 0 with miles to go are warnings. A plain mismatch is
only a note, and only when it is both more than half and more than 5 miles off,
because from code 10 upward the two agree to a median within 3% statewide. It
asserts the reads are scoped by structure number and made once, that the CSV stays
aligned, and that the pin reports the detour for the road it lands on: the
bridge's own on the carried road, the road-beneath detour on a road under it. Its
last section fails the read and asserts the tool says "not looked up" rather than
drawing an empty state, and raises no finding on missing data.

It also pins the route behind each detour (migration 0046): opening a bridge reads its route, one bridge at a time, and draws the detour in orange, the normal route dashed, the measuring points as A and B and the closed point in red; the panel lists the detour road by road with a total equal to the detour, links to the same path in Google Maps, and "Show on the map" fits the map to it. Opening another bridge clears it, a dead end draws nothing, a route not on file says so, and a failed route read leaves the distances standing.

And it pins the Figure 102 figure (migration 0048). Where the turn points are on file, the
headline is the turn-point figure, not the bridge-end one, says how it was measured and what the
bridge ends would give; the panel spells out the subtraction to three decimals and lists the
detour and the normal route between the turn points road by road; A and B sit on the turn points
and the orange and grey lines are the routes between them; Google Maps goes from A to B. A loop
road keeps its bridge-end figure and says only local traffic uses the bridge; a figure with no
basis on file reads as the bridge-end figure it is; and the CSV carries the figure, its basis and
the bridge-end figure beside it.

And it pins the B.H.17 check (BH17_MEASURED), an FHWA-group error: a coded distance more than 1 mile
from the calculated detour fails, code 0 is compared as 0 miles, 99 and a blank are not compared,
exactly 1 mile apart passes; the bridge counts as failing FHWA in the panel and the CSV; and the
pass box says whether B.H.17 was compared, and why not when it was not.

It also pins three fixes from the 13 October review. The panel never calls the
trip between the measuring points "straight across": on a divided highway those
points sit out where a driver can leave, so that trip can be a mile or more, and
the panel says so in plain words. It does not repeat the structure's length,
which is not part of the measurement, and heads the values "Calculated detour
length" and "Calculated detour length, road beneath". The pin finds NCDOT's route/milepost tool again if it is
renamed, and when the tool fails on NCDOT's side it reads the route and milepoint
off the Road Characteristics geometry instead, says so in the popup, and does not
wait on the broken tool for the next pin. And the switch above the table shows
bridges only, culverts and pipes only, or signs and other structures.

`fx/sbmock.js` is the stand-in for the Supabase REST API, shared by all ten. It
is a real little query engine — it honours `limit`, `offset`, `in.()` and `eq.` —
because the things worth asserting are exactly whether the client scopes its reads
and whether it pages. A mock that ignored those would pass either way.

Counts, all passing on all three builds: **36** data, **16** basemap, **37**
corrections, **37** auth, **106** features, **21** columns, **66** field,
**51** approvals, **60** traffic, **138** detour — 568 in all.

The database has its own tests under `supabase/tests/`, including one that runs
against the live project over HTTPS with the publishable key.
