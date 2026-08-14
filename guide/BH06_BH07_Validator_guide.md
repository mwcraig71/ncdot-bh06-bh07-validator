# NCDOT SNBI BH06 / BH07 Validator — user guide

A single HTML file. Double-click it. Nothing to install, no ArcGIS licence, and no login needed
to read anything.

The bridges you are testing are read live from NCDOT's own public ArcGIS services, so they stay
current as NCDOT republishes each quarter. Everything they are tested *against* — county
boundaries, the SNBI inventory, FHWA's HPMS submittal, and every route's true extent — is
loaded into a database on a schedule and read from there. Your machine no longer pulls it.

---

## Signing in, and what it is for

**Reading needs no account.** Anyone can open the tool, run any scope, run every check, filter,
look at the map, and export the CSV. That is deliberate: every figure it reads is already
published by NCDOT and FHWA, and the tool being useful without a login is the point of it.

**Recording a decision needs an account.** Statuses, notes, corrected BH06/BH07 values and
cleared findings are review work with your name on them, so you sign in first. Open
**Settings → Reviewer**, type your work email, and press **Email me a sign-in link**. There is no
password to choose, remember, or share.

Your name comes from the account, not from a text box. The database overwrites it from your
sign-in token as the record is written, so a correction cannot be signed with somebody else's
name — and the display name is your account's name or the part of your address before the `@`,
never the whole address, because it appears on a public page.

### There used to be a password gate. It is gone, and that is an improvement.

The old version hashed two passwords into the HTML file itself. That reads like protection and
is not: the file runs on your machine, so opening it in a text editor and deleting the check
defeated it in seconds. Worse, it invited someone to reuse a real password in a file that then
gets emailed around.

What decides anything now is the database. An anonymous visitor can read and nothing else. A
signed-in reviewer can write reviews and corrections, and **cannot** alter what NCDOT publishes.
Nobody — signed in or not — can delete anything: a correction supersedes, a cleared finding is
restored by a later event, and both leave the original in place with a name and a date on it.

Forcing the "signed in" flag from the browser console will put the buttons back on screen and
achieve nothing at all, because the buttons were never what was being checked.

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
| `gis11.services.ncdot.gov` | the bridges being tested, and route geometry on the map | nothing works — this one is essential |
| the Supabase project | everything the bridges are tested against | checks that need reference data cannot run |
| six tile hosts, below | background map imagery only | **cosmetic, and it self-heals** |

`geo.dot.gov` used to be on this list, for the HPMS test. It is not any more: HPMS is loaded
into the database by a scheduled job, so a reviewer's machine never contacts FHWA.

Blocked background tiles are the usual complaint, and they are not a real problem. The
background can come from any of six independent hosts, and **only one of them has to be
reachable**:

| Provider | Host |
|---|---|
| Esri | `server.arcgisonline.com` |
| Esri mirror | `services.arcgisonline.com` |
| USGS National Map | `basemap.nationalmap.gov` |
| NC OneMap | `services.nconemap.gov` |
| CARTO | `basemaps.cartocdn.com` |
| NCDOT | `gis11.services.ncdot.gov` |

The tool opens on **Esri imagery**, and the automatic fallback is aerial-first — a blocked host
should cost you a provider, not the kind of map you were looking at. County outlines and names
switch to white over any aerial basemap so they stay readable.

That last row is the important one. NCDOT publishes no tile cache, so the tool renders a road
basemap live from the same server the bridge data comes from — meaning **if the tool works at
all, a background map is available**.

When tiles stop arriving, the tool works down that list on its own, changing host each time
rather than trying another style on a host that is already refused, and tells you which one it
landed on. You can also pick any of them by hand under **Basemap** in the left panel, where each
is labelled with its host. Only if every one is refused does it fall back to drawing county
outlines, and even then bridges, checks, filters, the table and every export keep working.

If you want to ask IT to allow one, `basemap.nationalmap.gov` is usually the easiest to get
approved — it is a federal `.gov`, needs no key, and carries both topographic and aerial.

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

**Pin drop** lives on the map, top centre — arm it and click anywhere to read the route and
milepoint at that spot. Read the label carefully: it reports **the road at the point you
clicked**, which at a grade separation is usually the road *underneath*, not the road the bridge
carries. If a bridge is open, the popup says which of that bridge's features the road you clicked
actually is — so a milepoint of 46.958 in the popup and 2.672 in the panel is not a contradiction,
it is I-485 below and I-85 above.

Everything else lives behind **Settings**: signing in, the review file (save, open, merge),
HPMS, the Locate tolerance, the vintage of the reference data, Diagnostics and the NCDOT table
export. Each individual check is in there too, if you want to re-run just one.

Two switches in Settings worth knowing:

- **Load HPMS automatically** — on by default, and it reads only the counties your scope needs.
  This used to be a fetch from FHWA that could take a hundred requests; it is now one read of
  the ingested submittal and takes about as long as a page of search results.
- **Run the per-structure passes** — on by default. Locate, Resolve carried and Fill missing
  query the road network one structure at a time, so on very large scopes the tool asks before
  starting them.

## Filtering on the table itself

Every column in the results table has a filter box under its heading. They match against
**what you can see in the cell**, which matters because several columns are not fields
anywhere — the decoded route label, the findings, the suggested correction. Typing `county`
under Findings finds every row with a county-code finding.

| You type | You get |
|---|---|
| `SR1138` | rows whose cell contains it |
| `!SR1138` | rows whose cell does **not** |
| `-` | rows where the cell is empty |
| `>100` | numeric columns: over 100 |
| `<=0.5` | 0.5 or under |
| `1-2` | between 1 and 2 |
| `0.227` | that value, at three decimals |

On **Offset ft** and **BH07 milepoint**, `-` means nothing was ever measured — useful for
finding what Locate could not reach.

Filters combine across columns, and the row count above the table tells you how many are on.
**Export CSV takes the filtered rows, not the whole view** — filtering down to twelve rows and
getting 1,282 in the file would be a trap. Clicking a heading still sorts; the boxes do not
interfere. **Clear filters** in the left panel clears these too.

## On a phone — field mode

Below 860px the tool becomes a different application, because somebody standing under a bridge
is not doing the same job as somebody working a county list at a desk.

**What is gone.** The filter panel, the tab strip and the severity legend. An inspector at a
structure does not need a survey of everything wrong in the county; they need this bridge. The
map fills the screen and the markers no longer carry BH06/BH07 status colours.

**Where it starts.** It asks the phone where you are, centres there, works out which county you
are standing in — a proper point-in-polygon test, not a bounding box, which is what used to
answer *Gaston* for a point in Mecklenburg — loads that county, and opens the nearest structure.
If that structure is one of a twin pair, the bar names the sister and how far away it is,
because 40 to 120 ft is inside a phone's own fix accuracy and the tool will not pretend to
know which deck you are standing on.

**The panel leads with the answer.** BH06 and BH07 for this bridge, at the top. Then every
other feature on and under it, each with its own BH06 and BH07. The review paperwork — notes,
status, corrected values — is demoted to the bottom.

**The table is still there**, off the bottom of the screen. Pull the tab up to see it.

**Offline.** Opening a bridge caches the whole county — structures, features, routes and the
county outline — into the phone's own storage, plus map imagery for the area around you. Roughly
4 MB of data and about 92 image tiles per bridge from cold. Switch the connection off and every
structure in that county still validates.

### Adding, correcting and removing, in the field

**Add new feature** sits at the end of the feature list. It creates the feature and arms the
pin at it, so the next thing you do is point at the roadway on the map.

**The pin asks before it writes.** When the pin is aimed at a feature, clicking the map does
not fill the feature in. It shows you what it found — the route, the milepoint, the road name —
and asks *is this the road you meant?* Yes writes it; try again re-arms the pin. NCDOT's tool
returns the *nearest* route, and at an interchange the nearest route is frequently not the one
you were pointing at, so the confirmation is the point rather than a formality.

**Removing a feature is a request, not a delete.** If a roadway in the list is not there — the
derivation invented it, it is a duplicate, it was rebuilt away — you can ask for it to be
removed and say why. The feature **stays in every list and every export**, marked *removal
requested*, until an approver decides. Being wrong about a value costs one number; being wrong
about whether a roadway exists costs its whole highway record — the clearances, the traffic,
everything reported beneath the bridge.

**Everything you submit is queued.** New values and removal requests go into a queue for
approval rather than straight into the published data. They are held on the phone, so they
survive closing the browser or losing signal, and go out when the connection returns. Only
designated approvers can accept them.

## The four scopes

| Scope | What you get |
|---|---|
| **Single bridge** | One bridge, fully decoded. Partial numbers match, so `5900` finds every 5900-series bridge. |
| **All bridges on a route** | Type `I-40`, `US74`, `SR1300`, or a full 11-digit ID. Optionally pin it to one county. |
| **All bridges in a county** | The natural working unit — LRS mileposts are county-scoped. |
| **All bridges statewide** | 23,022 bridges in about 8 seconds. |

## What each check does

### Deep check

The client-side rules run instantly. **Deep check** is the extra pass: it looks up how long each
route actually is in that county, then flags every milepoint that falls outside the route's real
extent.

Those extents are measured from NCDOT's road network by the quarterly load — **386,644 routes,
every one of them** — so the check is a lookup rather than a live measurement.

That is the check that catches the most damaging error — **a statewide mile marker number
entered where the county LRS measure belongs.** NC interstate signs run the length of the
state (I-85 goes to about 234), but the LRS measure resets to zero at every county line and
never exceeds that county's width. A bridge on I-85 in Mecklenburg reading 38 is provably
wrong; the route only runs to 21.155 there.

Runs automatically as part of Run all checks, and is now fast enough that there is no reason to
turn it off: a county is two requests, and statewide is a few dozen.

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

**Pin drop** sits on the map itself, top centre — above the map rather than in a corner, because the bridge panel opens over the right-hand side and used to cover it. Arm it and click anywhere. This calls NCDOT's own
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

## Features — a bridge is not one row of BH06/BH07

Click a bridge and the panel lists its **features**: every roadway on it and every roadway under
it, each with its own BH06, BH07 and findings.

NCDOT's submittal holds no roadways-below at all, so the ones beneath are **measured** the moment
you open the bridge — one request, about a second, and then held for the rest of the session.
There is nothing to run first. (**Settings → Expand features** does the same thing for a whole
county at once, for an export.)

Bridge 590819 is the clearest example. It carries **I-85 in both directions on one deck**, and
three more roadways pass beneath it. That is five features, five BH06/BH07 pairs, one bridge
number. You still search for 590819 and you still get one row in the table — the row is the
structure. What you review is the features underneath it.

Each feature shows:

- **B.F.01 designation** (H01, H02…) and **B.F.02 location** — carried on the bridge, or below it
- its own BH06 and BH07, with your corrections tested in place of the published values
- its **route records** (R01, R02…) — the designations signed on that roadway
- how it was found, and at what angle it crosses the deck

**A road below the bridge gets no BH06.** It gets a highway record — the clearances and the
traffic underneath are reported — but the LRS Route ID belongs to whichever structure *carries*
that road. If a below feature has a BH06, the tool says so, and says it is B.F.02 that excludes
it. That is a different finding from the one where **B.H.18** names another bridge as the carrier,
because the remedy is different: one is a value that should not be there at all, the other is a
value that belongs on somebody else's record.

**Co-signed routes do not multiply features.** I-77 and US-21 on one deck are one feature with
two route records and one BH06/BH07 pair. Reported as two features, the state reports the same
length of road twice.

### Triage — which bridges actually need you

NCDOT names N roadways beneath; the tool measures M. What matters is whether they agree, and for
most bridges they do. The **Features** filter in the left panel sorts the whole county by that:

| | |
|---|---|
| **Lists agree** | every named roadway found, nothing else beneath. Nothing to do. |
| **Named ones found** | the named roadways now have routes and milepoints; nothing has looked for unnamed ones yet. |
| **Feature list is short** | a roadway passes beneath that Feature Crossed does not name. |
| **Named, not found** | NCDOT names a roadway nothing in the LRS answers to — often a private drive. |
| **Both ways** | both of the above on one structure. |
| **Highway below, unnamed** | ServiceUnder says a highway is beneath and the text names nothing. Measurement is the only source these will ever have. |

Pick **Anything needing a look** to get just the disagreements. That is the work queue, and it is
far shorter than the list of bridges with roadways beneath.

One thing to expect: a **divided highway beneath is two roadways**, each with its own clearances
and traffic, and Feature Crossed almost always names it once — "US74" over two carriageways,
"I485" over two. The tool marks the second one as a carriageway of a road already named rather
than as a missing road, so it does not crowd out the genuine omissions.

### Two ways to fill in a roadway the tool cannot resolve

**Resolve named features** (Settings) pulls only the routes NCDOT names beneath the bridges in
your scope — 40 routes covers all of Mecklenburg — and resolves them in one pass, in seconds,
rather than querying once per bridge.

**The pin drop, aimed at a feature.** Open a bridge, find a roadway beneath with no route, and
click *Pick this roadway on the map*. The pin arms, you click the road where it runs under the
bridge, and NCDOT's own route/milepost tool fills that feature in — recorded with your name and
the date, so an export can say where the number came from.

### Two things NCDOT's own reports get wrong

**Carried features come first.** Every carried roadway is numbered before the first roadway
beneath. 590819's report numbers a carried roadway **H05**, after three below features.

**Route designations restart at R01 inside each feature.** 590819's report runs **R01 through
R05** straight across all five features, so "R03" does not tell you which route it is until you
also know which feature it sits in.

The tool numbers both correctly, records what the document said, and flags the difference. It
does not quietly rewrite the report, because the fact that the report disagreed is itself worth
keeping.

---

## Sister structures, and why the tool refuses some roads

NCDOT publishes bridges as a single point, not an outline. So any question of the form "what is
under this bridge" has to start from a circle around that point — and **twin decks carrying the
two directions of a divided highway sit 40 to 120 ft apart.** In Mecklenburg alone there are
**122 such pairs**. A plain circle around the northbound structure contains the southbound
structure's road, and would report the road *next to* the bridge as the road *under* it.

The tool does three things instead, and a road has to pass all three:

1. **It rebuilds the deck.** The structure's length, deck width and skew give a rectangle
   oriented along the road it carries. A sister deck 51 ft from a 45 ft-wide deck is outside it.
2. **It checks the crossing angle against the recorded skew.** Skew is measured from square, so a
   structure with 20° of skew should be crossed at 70°. On 590819 that predicted 70° and the two
   I-485 carriageways came in at 69.8° and 68.4°. A road running *parallel* to the deck is not
   crossing it. Note there is no fixed "too parallel" cutoff — on a 70° skew a real crossing runs
   only 20° off parallel, and a fixed rule would throw away the most skewed bridges in the state.
3. **It asks whether a neighbour carries it.** If another bridge number nearby has that road as
   its own BH06, the road belongs to that bridge. This one needs no geometry at all, so it still
   works when the dimensions are missing.

When a bridge is one of a sister pair the panel says so, names the other bridge, and explains
that routes carried on it are excluded on purpose. That matters: a road correctly refused looks
exactly like a road the tool never found, and you should be able to tell them apart.

**A road under a twin pair belongs to both.** Both structures report it, and that is correct —
it is not a duplicate and the tool does not treat it as one.

If a structure has no recorded length, deck width or skew, the tool falls back to the plain
circle, marks everything it finds **low confidence**, and sends it to you rather than accepting
it. Confirm those before they go anywhere.

---

## Approvals — deciding what the field submitted

Everything an inspector submits from a phone is a **proposal**. It changes nothing until
somebody accepts it. **Approvals**, next to Settings in the toolbar, is where that happens: it
replaces the results table and leaves the map where it is, because the thing you most want
beside a proposal is the bridge it is about.

**The queue is public. Deciding is not.** Anyone can open it and see what was submitted, by
whom, and what was decided — the provenance of a public submittal is public. Accepting and
rejecting need a designated approver account.

### The screen checks the proposal before you do

Each feature's proposals are shown together, with the verdict underneath. Every proposal is run
through the same rules the tool applies to NCDOT's own published values:

- **Is BH06 even reportable here?** A BH06 proposed on a roadway that runs *beneath* the
  structure fails BH06-4 outright — a road passing under does not get a route ID at all.
- **Is the route the right shape, in the right county?** Eleven digits, and the county code in
  the ID has to match the county the structure is in.
- **Is it in the HPMS submittal?** BH06-3, where HPMS is loaded.
- **Does the milepoint fall inside the route?** Measured against the route's published extent,
  so `30.100` on a route that runs 0.000 to 21.155 is called out as being off the end of it.
- **Does it put you at the bridge?** The tool walks the route's own geometry to the proposed
  milepoint and reports the distance from the structure in feet. This is the check FHWA does
  not run.

A green tick, an amber question mark and a red cross carry the same meaning they do everywhere
else in the tool, and the whole card takes the colour of the worst thing on it. A proposal that
corrects only BH07 is still tested, on the route the feature already has.

A **removal request** is the exception: nothing measures the absence of a road, so the screen
says so and points you at the bridge.

### Deciding

**Accept** writes a REVIEWED value, which is what every check and every export then reads.
NCDOT's published value is never overwritten — it stays underneath, and withdrawing the
decision restores it exactly.

**Reject** needs a reason, always. The inspector who submitted it has to be able to read why,
and the reason is kept with the decision.

**Accept all values here** takes every value proposal on one structure at once, since a single
field visit usually produces several. If any of them failed the checks it says so and asks
again. Removal requests are deliberately excluded: a value can be corrected again tomorrow, but
a withdrawn feature takes its clearances and its traffic with it.

A removal is accepted or refused on its own. Accepting **withdraws** the feature rather than
deleting it, so the record of what was reported and who removed it survives.

### Approvers

The bottom of the screen lists who currently holds the role, when it was granted and by whom,
and how many decisions they have made — plus anyone whose role was revoked, with the reason.
Revoked, never deleted: "who could approve what, when" has an answer for any date in the past.

An approver can **appoint** another one by work email. It has to be an email rather than a name
because the account has to already exist — signing in once is what creates it, and an
appointment should not be able to invent a person. **The last approver cannot be revoked**, by
anyone including the service key, because a queue nobody can decide is worse than an approver
nobody wanted.

The *first* approver is granted from the Supabase dashboard with the service key. Somebody has
to be trusted first, and it should not be whoever signs in first.

**Field mode has no Approvals button.** An inspector submits and somebody else decides; putting
both halves in one pair of hands on one phone would defeat the point of having a queue.

---

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

### Your correction is what gets tested

The moment you enter a corrected BH06 or BH07, **every check re-runs against your value instead
of NCDOT's**. The row's findings, the colour of its map dot and the summary counts all move
immediately. That is the point: the corrected value is the one you would submit, so it is the
one that has to pass.

It cuts both ways, and deliberately so. A correction that fixes the problem clears the finding
in front of you. A correction that is itself wrong — a county digit off, a milepoint past the
end of the route, a route ID that collides with another bridge's — fails, loudly, right there.
Corrections used to be stored, exported and never tested; a bad one went to NCDOT unchallenged.

Wherever a corrected value appears it carries a small blue **REV** tag, and the bridge panel
shows both numbers: yours in full size, NCDOT's struck through beneath it. You never have to
work out which number a finding is about.

Two things worth knowing:

- Every corrected row carries the note **"Validated on a reviewer's correction"**. It is not a
  fault. It exists so a corrected row can never be mistaken for a clean published one, and so
  you can filter the checklist for every correction and review the corrections themselves.
- If you had run **Locate**, the measured distance was measured against the *old* value. Change
  either number and that distance is dropped and the row reads **re-locate** rather than showing
  you a stale figure about a value that no longer exists. Run Locate again to measure the new one.

This is separate from clearing a finding, and the two should not be confused. A correction
changes *what is tested*. Clearing changes *whether a finding still counts*. Use a correction
when the value is wrong; use **clear this finding** when the value is right and the check is not.

*Fill missing* writes its derived values into these same fields, which means derived BH06/BH07
values are now tested too — including the low-confidence ones it warns you to confirm.

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

Review files are stamped `version: 2`. Files written by an earlier copy of the tool open
normally — the tool just tells you that their corrections were never validated and have now been
tested for the first time, so expect the finding counts to move when you open one.

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

All public, no authentication.

**Read live, from your machine** — the bridges under test, and the geometry the map draws:

```
Bridges          gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Bridges/MapServer/0
Road geometry    .../NCDOT_RoadCharacteristicsQtr/MapServer/0
Pin drop         .../NCDOT_Tools/NCDOTIdentifyRouteMilepostUsingPointTool/GPServer
```

**Read from the database** — everything the bridges are tested against, loaded by a scheduled
job rather than by you:

| What | From | Reloaded |
|---|---|---|
| County boundaries, and the SAP/FIPS crosswalk | NCDOT_CountyBdy_Poly | quarterly |
| The SNBI inventory | NCDOT_DynamicStructures, all eight layers | quarterly |
| Route extents for Deep check | NCDOT_RoadCharacteristicsQtr | quarterly |
| The HPMS submittal for BH06-3 | FHWA | annually |

**Settings → Data** shows each one's vintage: the date the service itself reported, and when it
was last loaded. Cite those in a submittal rather than the date you ran the tool. If you know
NCDOT has republished since the last load, **Reload from NCDOT now** asks the server to re-read;
it takes a few minutes and needs you signed in, because it is recorded against your account.

One vintage worth noticing: the structures service reports **2020**, while the bridge layer
reports the current quarter. That gap is NCDOT's, not the tool's, and it is why condition
ratings can look older than you expect.

Basemap tiles come from whichever of six hosts this network permits — Esri, an Esri mirror,
USGS National Map, NC OneMap, CARTO, or a road basemap rendered live off gis11 itself. The tool
falls through them automatically and you can force one under **Basemap**. If every one is
blocked the map still works: county lines, bridges and all interaction are drawn locally, and
only the background imagery goes missing.

---

Built by Strinteg Corporation.
