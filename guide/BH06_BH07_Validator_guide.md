# NCDOT SNBI BH06 / BH07 Validator — user guide

A single HTML file. Double-click it. Nothing to install, no login, no ArcGIS licence.

Everything it shows is read live from NCDOT's own public ArcGIS REST services, so it stays
current as NCDOT republishes each quarter.

---

## Passwords and roles

Two passwords, two roles.

**Reviewer** — everything needed to do the work: run any scope, all the checks, filters, map,
CSV export, set a status, write notes, record corrected BH06/BH07 values, save and merge review
files.

**Administrator** — everything above, plus the two things that carry consequences: **clearing a
finding** (which removes an error or warning from the counts) and **changing the passwords**.
A reviewer who thinks a finding is wrong writes a note saying so; an administrator decides.

### Setting them up

A fresh copy ships with no passwords, opens straight into administrator, and says so. Open
**Settings → Passwords**, set both, and it downloads
`NCDOT_BH06_BH07_Validator_configured.html`. **That downloaded file is the one you hand out** —
the copy you are working in is deliberately left unchanged, so a mistyped password can't lock
you out of your own file.

Same flow to change a password later: admin sets the new one, downloads a fresh configured copy,
redistributes. There's no recovery — lose the admin password and you set new ones from a fresh
unconfigured copy.

### What this actually protects — worth being straight about

Passwords are stored as salted SHA-256 hashes, so nobody can read them out of the file. But
this is a single HTML file that runs entirely on your machine: **anyone determined enough can
open it in a text editor and strip the gate out.** It is not encryption and it should not be
described to anyone as securing data.

That is fine, because there is nothing secret here. Every figure the tool reads is already
published by NCDOT and FHWA. What the gate protects is the **review record** — it stops
someone casually clearing 2,000 findings and it makes clear who owns that decision. For that
job it is exactly right, and it is the correct amount of security for a tool whose inputs are
all public.

---

## Sharing this with other staff — send the right file

There are two builds. **Send `NCDOT_BH06_BH07_Validator.html`.** It carries the mapping
library and fonts inside the file, so it needs nothing from the internet except NCDOT's own
data services. It is the one that survives a locked-down agency network.

The other file, `NCDOT_BH06_BH07_Validator_artifact.html`, is a slimmed copy that pulls its
mapping library from a CDN. It exists only because the preview pane can't render the big one.
If you send that copy to someone whose network blocks CDNs, the map will not draw — the page
now says so plainly and tells them which file to ask for.

### If the map still doesn't appear

Open **Settings** and press **Diagnostics**. It tests each service in turn and reports exactly what this machine can
and cannot reach, so you can hand the list to IT rather than guessing. Three hosts matter:

| Host | Needed for | If blocked |
|---|---|---|
| `gis11.services.ncdot.gov` | all bridge and road data | nothing works — this one is essential |
| `geo.dot.gov` | the HPMS test (BH06-3) | every other check still runs |
| `server.arcgisonline.com` | background map imagery only | **cosmetic** |

That last one is the usual culprit, and it is not a real problem. If the tile server is
blocked, the tool notices after a few failed tiles, switches to drawing North Carolina's county
outlines itself, and tells you what happened. Bridges, checks, filters, the table and every
export keep working exactly as before — you just lose the aerial or street background. Most
people describing "the map doesn't load" are seeing this.

---

## What it is for

BH06 (LRS Route ID) and BH07 (LRS Milepoint) are two of the fields most likely to fail the
SNBI submission. This tool pulls NCDOT's published values for every bridge, decodes them, runs
FHWA's published validation rules against them, and then runs a second set of checks for
values that pass FHWA and are still wrong. Results appear on a map and in a filterable table
at the same time.

---

## How you use it

Pick a scope, press **Run all checks**. That is the whole interface.

One button runs the entire pipeline in order: load the structures, join the SNBI inventory
data, fetch NC's HPMS submittal from FHWA, then Deep check, Locate check, Resolve carried and
Fill missing. A county takes about ten seconds. When it finishes you get one summary line and a
fully populated table.

**Pin drop** lives on the map, top right — arm it and click anywhere to read the route and
milepoint at that spot.

Everything else lives behind **Settings**: the review file (save, open, merge), the reviewer
name, HPMS, the Locate tolerance, Diagnostics, the NCDOT table export and passwords. Each
individual check is in there too, if you want to re-run just one.

Two switches in Settings worth knowing:

- **Fetch HPMS automatically** — on by default, and it only pulls what your scope needs. A single
  county fetches that county (about 20,000 routes, a few seconds), not the whole state's 213,475.
  Statewide scope fetches the state. Counties already in memory are never fetched twice, so
  re-running a county costs nothing and widening to statewide only pulls the counties you don't
  already have.
- **Run the per-structure passes** — on by default. Locate, Resolve carried and Fill missing
  query the road network one structure at a time, so on very large scopes the tool asks before
  starting them.

## On a phone

The layout adapts below 860px. Three tabs — **Filters**, **Map**, **Results** — replace the
side-by-side layout, tapping a row opens the bridge panel full screen, and every control is
sized for a thumb. The whole workflow works on a phone in the field: run a county, filter to
errors, tap a structure, read the findings, leave a note.

## The four scopes

| Scope | What you get |
|---|---|
| **Single bridge** | One bridge, fully decoded. Partial numbers match, so `5900` finds every 5900-series bridge. |
| **All bridges on a route** | Type `I-40`, `US74`, `SR1300`, or a full 11-digit ID. Optionally pin it to one county. |
| **All bridges in a county** | The natural working unit — LRS mileposts are county-scoped. |
| **All bridges statewide** | 23,022 bridges in about 8 seconds. |

## What each check does

### Deep check

The client-side rules run instantly. **Deep check** is the extra pass: it asks Road
Characteristics how long each route actually is in that county, then flags every milepoint
that falls outside the route's real extent.

That is the check that catches the most damaging error — **a statewide mile marker number
entered where the county LRS measure belongs.** NC interstate signs run the length of the
state (I-85 goes to about 234), but the LRS measure resets to zero at every county line and
never exceeds that county's width. A bridge on I-85 in Mecklenburg reading 38 is provably
wrong; the route only runs to 21.155 there.

Runs automatically as part of Run all checks. Statewide takes a few minutes.

### Locate check — does the milepoint actually put you at the bridge?

This is the strongest test in the tool, and it is the one that answers "are these mileposts
even right?"

NCDOT's LRS measures live on the route geometry itself: every vertex of every road segment
carries an M value. **Locate check** walks that geometry to the reported milepoint and measures
how far the resulting position is from the bridge's own coordinates. Because it follows the
line vertex by vertex, distance is traced **along the road** — round every curve and switchback,
never cut across.

Tolerance is set in Settings (default 100 ft). Anything landing outside it is flagged, and the measured offset appears as its own sortable column, in
the bridge panel, and in the CSV.

It is deliberate that a milepoint the geometry does not cover comes back as **not measured**
rather than as an error. Snapping to the nearest vertex would invent an offset out of a gap in
the data, so the tool reports the gap instead and says how many it could not reach.

Scope it to a bridge, a route, or a county. Statewide pulls real geometry for roughly ten
thousand routes and will ask you to confirm first.

### Pin drop

**Pin drop** sits on the map itself, top right. Arm it and click anywhere. This calls NCDOT's own
`IdentifyRouteMilepostUsingPointTool` — the same drop-a-pin capability TxDOT's map has, which
NCDOT already publishes but does not surface in its viewer. You get the route ID, the
milepoint to three decimals, and any concurrent routes at that point.

**One caution, shown in the popup every time:** it returns the *nearest* route. At a grade
separation that is usually the road **underneath**. BH06 must be the route **carried on** the
bridge, so use pin drop to confirm a value — never to harvest one blindly.

---

## The checks — two groups, and the distinction matters

### FHWA submittal checks

These are the published SNBI validation rules. They are what actually fails.

| Rule | What it tests |
|---|---|
| **BH06-1** | LRS Route ID not null, and not over 120 characters. Required when B.F.01 (Feature Type) begins with "H" and B.F.02 (Feature Location) = "C". |
| **BH06-3** | The route ID must be valid and found in the state's HPMS submittal to FHWA. |
| **BH06-4** | BH06 must *not* be reported where B.H.18 (Crossing Bridge Number) shows the highway feature is carried on another bridge. |
| **BH07-1** | Mile point must be a valid numeric value. |
| **BH07-2** | Mile point must not exceed 8 digits. |

**Fetch HPMS from FHWA** settles BH06-3 outright, with nothing to request from anybody. FHWA
republishes each state's HPMS submittal as a public feature service, and North Carolina's
`route_id` column is NCDOT's own 11-digit ID. BH06-3 becomes a real test. *Load file* is still
there if you'd rather use your own extract.

It fetches by county, matched to your scope, and caches. Two details worth knowing: HPMS keys on
**FIPS** county codes while NCDOT uses **SAP** codes, so the tool translates between them; and it
pulls not just your scope's county but **every county code appearing in a BH06 in the results**.
A structure near a county line can legitimately carry a route belonging to the neighbouring
county, and failing it for HPMS data that was simply never fetched would be a false error.

Against NCDOT's published bridge data, the real answer is:

| | Bridges |
|---|---|
| BH06-3 **passes** — route found in HPMS | 20,348 (88.4%) |
| BH06-3 **fails** — route not in HPMS | **2,171 (9.4%)** |
| No route assigned at all (BH06-1) | 503 |
| BH07 outside the HPMS section extent | 27 |

**Where the failures actually are — this is not where anyone expects:**

| Route class | Bridges | Fail BH06-3 | Rate |
|---|---|---|---|
| Ramp / non-mainline | 721 | **721** | **100%** |
| SR secondary | 12,269 | 954 | 7.8% |
| US | 3,006 | 176 | 5.9% |
| NC | 2,465 | 123 | 5.0% |
| Non-system (class 5) | 1,204 | 72 | 6.0% |
| Interstate | 2,783 | 107 | 3.8% |

**HPMS carries no ramps at all.** Every one of the 721 ramp-carried bridges fails BH06-3, and
no amount of correcting route IDs will change that — it needs a reporting decision from FHWA
or the state. The other ~1,450 failures are scattered at 4–8% across every class and are
individually fixable: retired routes, wrong county suffix, typos.

Worth noting what this disproves. Non-inventory direction and non-system class 5 were the
obvious suspects, and measured against the real HPMS they fail at **4.1%** and **6.0%** —
essentially the background rate. They are weak predictors, and the tool now says so.

BH06-4 shows as a note, not a defect: it marks the 6,210 bridges that carry a highway *over*
another highway, so your features dataset holds a second highway feature for the road below.
Nothing to fix on the bridge row — but that under-feature must not carry a BH06.

### Strinteg QC — likely wrong

**Here is the thing worth understanding.** FHWA tests BH07 for exactly two things: is it a
number, and is it 8 digits or fewer. **Nothing checks whether the milepoint is anywhere near
the route.** A statewide mile marker number, the measure of the road underneath, a digit
transposed — all of it submits perfectly clean.

So passing validation does not mean the data is right. The QC group catches what FHWA does not:

| Check | Meaning |
|---|---|
| BH07 does not land on the bridge | Following the milepoint along the route lands more than the tolerance from the bridge's own coordinates. The strongest single test of whether a milepoint is right. *Locate check.* |
| BH07 beyond / before the route | The milepoint falls outside where the route actually runs in that county. Provably wrong, and it passes every FHWA rule. *Deep check.* |
| BH06 route does not exist | Well-formed ID, but NCDOT's road network holds no such route — a typo, a retired route, or a county suffix that doesn't go with that route number. Guaranteed BH06-3 failure. *Deep check.* |
| Duplicate BH06 + BH07 | Another bridge claims the identical route and milepoint. Two structures can't occupy the same point on the same route. |
| Non-inventory direction | Third digit 4, 6 or 9. HPMS generally carries only the inventory direction — the leading predictor of a BH06-3 failure. **2,289 statewide.** |
| Non-system route (class 5) | Municipal or private. HPMS generally covers public roads only. **1,204 statewide.** |
| BH06 not a carried route | The decoded route is not among the routes named in Feature Carried — often the road underneath, which BH06 must never be. **754 statewide.** |
| County code mismatch | Last three digits disagree with the bridge's county. **47 statewide.** |
| BH07 exactly 0.000 | Usually an unset default. Valid only at a county line. **191 statewide.** |
| BH06 not an 11-digit ID | Clears FHWA's length rule but is not NCDOT's format, so it will fail the HPMS match. |

The duplicate check already finds a real one in NCDOT's published data: bridges **640011** and
**640110** in New Hanover both report US-74 at milepoint 1.590. One crosses the NE Cape Fear
River, the other crosses wetlands. They are not in the same place.

### Strinteg notes

Informational, nothing to fix. Ramp or non-mainline routes (**721**), and low-precision
milepoints (**2,352**) — fewer than three decimals usually means rounded or hand-entered rather
than measured.

### Working the three groups

Each group header carries a live count of affected bridges and an **all / clear** button, so
you can filter to every FHWA failure, or every QC finding, in one click. Individual checks tick
on and off the same way. Map and table always move together.

**Show what submits clean but is wrong** is the button worth knowing about. It isolates bridges
that clear every FHWA rule and are still provably wrong — the ones that would sail through the
March submission and stay wrong until somebody drives out there. That is the number worth
putting in front of Brian.

The summary tiles keep it honest: **Fails FHWA** is what gets rejected. **Wrong, passes FHWA**
is what nobody catches.

### Fill missing — deriving BH06/BH07 where NCDOT has none

**Fill missing** takes every structure with no LRS route or no milepoint, asks the road network
what lies within 150 ft, picks the candidate that matches Feature Carried, and reads the
milepoint off that route's own geometry. It writes the result into the corrected BH06/BH07
fields and the review note, and shows it in the results table with a ◆ marker so a derived
value is never mistaken for NCDOT's published data.

### It refuses to guess where BH06 does not apply

This matters more than the deriving does. Run against Mecklenburg's 50 structures with no
value, **43 of them need no BH06 at all** — they are railroad bridges carrying rail over a
highway, plus signs and pipes. The tool checks the `ServiceOn` field: BH06 is reported only
where a **highway** is carried on the structure (B.F.01 begins with H, B.F.02 = C).

Handing a railroad bridge the milepoint of the interstate underneath it would be exactly the
error BH06 exists to prevent, so it doesn't. Those come back marked **not required**, with the
reason, and are closed out in the review.

That leaves 7 real derivations, graded:

| Confidence | Meaning |
|---|---|
| **High** | The route named in Feature Carried is one of the candidates. Trust it. |
| **Medium** | Feature Carried names no route number — a local street. The nearest carried route is plausible. |
| **Low** | Feature Carried names a route but none of the candidates matched. **This may be the road underneath. Confirm before use.** |

### The NCDOT table

**NCDOT table** exports one CSV covering both actions: bridge number, county, BH06, BH07,
decoded route, feature carried and crossed, structure type, confidence, the method used, offset
in feet, coordinates, who derived it and when, and the source. Rows that need no value carry
`NOT REQUIRED` with the reason in place of a milepoint.

That is a file NCDOT can work straight from — the proposed values with their provenance and
confidence, and the list of structures that should stay blank.

### Resolve carried — triaging carried-vs-under

**Resolve carried** takes every bridge flagged "BH06 not a carried route" and asks, for each
one, what is actually within 150 ft. It then sorts them three ways:

**Resolved (~38%)** — the route named in Feature Carried really is at the bridge. The tool
proposes it as the corrected BH06 and reads the milepoint straight off that route's geometry,
so you get a complete replacement pair, not just a flag.

**Feature Carried is stale (~62%)** — the named route isn't there, but the route BH06 already
points at *is*. That is the signature of a redesignation, and NC has had several: NC-295
became I-295, US-70 Bypass became I-42, NC-147 became I-885. **BH06 is right and the
description is out of date.** Fixing BH06 here would break correct data.

**Needs a human** — neither route is near the coordinates. In a 60-bridge sample this came out
at zero, which is a good sign for NCDOT's structure locations.

The tool also stopped flagging a false positive it used to report: **253 of the original 754**
were ramp-carried bridges coded to a ramp route, where Feature Carried names the mainline the
ramp serves rather than the ramp itself. Those were always correct. That leaves **501** genuine
flags, and the triage splits those.

Suggested values land in a **Suggested BH06 / BH07** column, in the bridge panel, and in the
CSV as `SUGGESTED_BH06`, `SUGGESTED_BH07` and `CARRIED_TRIAGE`. Nothing is applied
automatically — this produces a reviewed correction list, not an edit.

## SNBI data — the rest of the inventory

NCDOT publishes a second, much richer structures service alongside the bridge layer: **60
fields** split across eight structure types. It keys on structure number, so it joins straight
onto what the tool already has. Press **SNBI data**.

What it brings in: deck, superstructure, substructure and culvert **condition ratings**, last
inspection date, year built, **scour critical**, fracture critical, posting status, sufficiency
rating, structure length, deck and roadway width, skew, lanes, main structure type and
material, superstructure and substructure descriptions, service on/under, NHS, owner and
maintenance responsibility. All of it lands in the bridge panel and the CSV, and two new
filters appear — **structure type** and **worst condition rating**.

### It also tells you the population is not what it looks like

The layer this tool calls "bridges" is really every structure NCDOT tracks. Statewide:

| Type | Count |
|---|---|
| Bridge | 14,262 |
| Culvert | 3,389 |
| **Sign** | **2,853** |
| **Pipe** | **2,025** |
| Railroad bridge | 254 |
| Pedestrian | 69 |
| Tunnel | 4 |
| Other | 43 |

**Sign structures and pipes are almost certainly not NBI structures**, and between them that is
**4,878 records** sitting inside the 23,022 that BH06/BH07 counts have been drawn from. Strip
them out and the reportable population is roughly **18,000** — which is much closer to the
16,000 figure the team started with than the 23,022 the bridge layer suggests.

Worth settling early: it changes the denominator on every number in this tool, and it may mean
a couple of thousand structures do not need BH06 or BH07 at all.

### One trap in the new data

The service carries an **`InventoryRoute`** field — values like `131011380`. That is the old
**9-digit NBI inventory route**, not the LRS route ID. It is not BH06 and must not be reported
as one. The bridge panel labels it "Legacy inv. route" and says so.

## Review — notes, status and clearing findings

Every check the tool raises is a *suggestion*. Some will be wrong, some will be things you've
already chased down, and none of it is worth anything if the next person has to redo the work.
So there's a review layer.

Put your name in the **Reviewer** box first — it stamps everything you touch.

Open any bridge and the panel now starts with a review block:

- **Status** — Open, In progress, Fixed at source, Not an issue, Accepted as-is
- **Corrected BH06 / BH07** — what it *should* be, kept alongside what NCDOT currently publishes
- **Notes** — free text: what you checked, who you asked, what happens next

If you've run *Resolve carried* and it proposed a correction, there's a one-click **use the
suggested correction** link that fills both fields and sets the status.

### Clearing a finding

Under every individual finding there's **clear this finding**. It asks why, and that reason is
kept — so a year from now the record says *"cleared by M. Craig, 12 Aug: checked with Div 10,
ramp is correct as coded"* rather than silently disappearing. Cleared findings show struck
through, and **restore** puts them back.

Tick **Hide cleared findings** in the Review panel and every count in the tool — summary tiles,
rule counters, group totals, map colours — recalculates as if they were never raised. That's
how you drive the error count down to the ones that actually matter and see real progress.

### The review file

Artifacts can't use browser storage, and honestly that's the better outcome: your work lives in
a file you control rather than a browser profile that gets wiped.

**Settings → Save review** writes a JSON file named for you and the date. **Open** loads one
back. There's an unsaved-changes dot on the Settings button and the browser will warn you before you close with
work outstanding.

**Merge** is the one that matters for a team. Two people can work the same county on their own
copies and combine afterwards — newest edit wins per field, notes that differ are kept both,
and cleared findings are unioned so nobody's decision gets dropped. Status conflicts are
reported in the toast rather than resolved quietly.

Everything also lands in the CSV: `REVIEW_STATUS`, `REVIEW_NOTE`, `REVIEW_BY`, `REVIEW_DATE`,
`CORRECTED_BH06`, `CORRECTED_BH07`, `CLEARED_FINDINGS`.

New filters in the Review panel let you pull *not reviewed*, *has a note*, *has cleared
findings*, or any single status — so you can see what's left rather than what's done.

## Reading a bridge

Click any point or row. The panel decodes the 11-digit ID digit by digit — class, qualifier,
inventory code, route number, county — highlighting the inventory and county digits, since
those are the two that drive most failures. Below that: the milepoint against the route's real
extent, every finding with an explanation, and the full bridge record.

**Re-measure from GIS** runs pin drop on that bridge's own coordinates, so you can compare
NCDOT's published value against what the network says today.

## Export

**Export CSV** writes whatever is currently filtered. Findings come out in three separate
columns — `FHWA_FINDINGS`, `QC_FINDINGS`, `NOTES` — alongside `FAILS_FHWA` (yes/no) and
`FHWA_RULES` (the rule codes, so a correction list maps one-to-one onto the error report). Plus
the decoded route, the route's measured extent, and a severity column. That is the file you
hand to whoever is doing the corrections.

---

## BH07 is handled at three decimals throughout

NCDOT's service publishes full precision — `0.06507547`, `2.04446672`. SNBI reports BH07 to
three decimals, so **three decimals is the value this tool validates, compares, displays,
filters, deduplicates and exports.** The unrounded source is kept beside it in the
`BH07_SOURCE_VALUE` column and shown in the bridge panel, so nothing is lost.

Two reasons this matters more than it sounds:

**It removes a false failure.** BH07-2 limits the mile point to 8 digits. `0.06507547` is
9 digits. Checking the raw published value trips BH07-2 on most of the state; checking the
reported value (`0.065`) is correct and trips nothing. If your own submittal carries NCDOT's
unrounded values through, that is a real error waiting to happen, not a theoretical one.

**It changes what counts as a duplicate.** Two bridges at `4.1234001` and `4.1234999` are
distinct in the source and identical once reported — both become `4.123`. Matching on the
reported value catches collisions that only exist in the data you actually submit.

The low-precision note still reads the *source*: a published value carrying fewer than three
decimals was rounded or typed by hand rather than measured, and that is worth knowing even
though the output is padded to three either way.

---

## Two things worth knowing before you use the numbers

**The mileposts are measured along the road, and they are right.** Worth stating plainly,
because it is the obvious thing to suspect. NCDOT's LRS measures were checked two ways:

*Against the geometry.* Over 776 curved road paths in the mountain counties, the distance
implied by the M values came within **0.28%** of the true along-the-road length, and diverged
from straight-line distance by **17.9%**. The most extreme case is a switchback carrying
2,110 ft of road across only 230 ft of ground — the measures put it at 2,112 ft. A crow-flies
system would have said 230.

*Against the bridges.* Running Locate check over two whole counties — Mecklenburg, dense and
urban, and Buncombe, mountainous — the reported milepoint lands a median of **about a foot**
from the structure. In Mecklenburg all 1,232 bridges came in under 25 ft. In Buncombe 99.9%
were inside 50 ft, with one outlier at 181 ft.

The small positive bias is expected and correct: NCDOT derives its measures in 3D from LiDAR,
so they include grade and read very slightly longer than flat map distance.

**Mileposts are county-based.** They reset to zero at every county line. The last three digits
of BH06 *are* the county. This is correct for the submission — but it is not the mile marker
sign number, and it is not what Google shows you.

**Concurrent routes do not mean multiple BH06.** Under SNBI, co-signed routes on one deck
(I-277 and US-74, say) produce multiple *route* records under a single highway feature. BH06
and BH07 are reported once per highway *feature*, and only where B.F.02 = C (carried). The
road below the bridge gets none. So a bridge with five routes on it still gets one BH06 — you
just have to pick the right one.

---

## Data sources

All public, no authentication:

```
Bridges          gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Bridges/MapServer/0
Road network     .../NCDOT_RoadCharacteristicsQtr/MapServer/0
County boundary  .../NCDOT_CountyBdy_Poly/MapServer/0
Pin drop         .../NCDOT_Tools/NCDOTIdentifyRouteMilepostUsingPointTool/GPServer
```

Basemap tiles come from Esri's public service. If your network blocks them the map still
works — county lines, bridges and all interaction are drawn locally; only the background
imagery goes missing.

---

Built by Strinteg Corporation.
