# As-measured detour length

**Status, 13 October 2026: measured statewide and live in the tool.** All
19,676 NCDOT bridges, culverts and pipes, both modes, on a self-hosted North Carolina graph built from the
OpenStreetMap extract of 12 October. Results and the findings they produced are
in *Statewide run* at the end. Everything above that section is the design work
that got there, kept because the reasons matter.

## Can the current architecture carry it?

Yes — for both measurements, and most of what it needs is already built. One
piece of new infrastructure is required, and the measurement only becomes
trustworthy if each value carries a validity test. Both are set out below.
Everything here was measured, not reasoned about; the runs are named.

## The two quantities

**Bypass detour (road ON the bridge).** Standing on one side of the structure,
unable to cross it, how far to reach the other side. **The road underneath stays
open** and the detour may use it — which is why the deck is blocked edge by edge
rather than as an area. An area block would cut the road below as well, and at a
grade separation dropping down, passing under and coming back up is a real
detour.

**Collapse detour (road UNDER the bridge).** The road beneath is obstructed; how
far from one side of it to the other. **The deck above stays open** and the
detour may cross on it, which matters wherever an interchange lets traffic leave
the lower road, cross over and rejoin.

Treating the two obstructions as independent is a deliberate modelling choice. A
span that has actually fallen takes out both roads at once; measuring them
separately gives the shortest honest detour for each and avoids compounding one
closure into the other. It is worth stating on the submittal rather than leaving
implied.

Neither is a size or capacity question. No bridge along either detour is checked
for clearance, posting or width — the instruction was minimum distance only.

### What gets blocked

| | blocked | left open |
|---|---|---|
| bypass | this crossing's deck(s), including a twin or express-lane deck running with it | the road(s) beneath, every other structure |
| collapse | every roadway at ground level under the span, all carriageways and ramps | the deck above, the carried road's own approaches |

Two refinements were needed to get that boundary right, both found by a wrong
answer rather than by inspection:

- **The carried road's own approaches sit inside the footprint.** Just past the
  abutments the carried road is at grade, so a footprint test alone reads it as a
  road passing beneath, and the tool then reported a "road below" detour for the
  road on the bridge. The discriminator that works is **name disagreement with
  the deck** — the deck at 590028 carries Moores Chapel Road, so a ground edge
  also named Moores Chapel Road is its approach, while I-85 is genuinely beneath.
  Heading is the fallback where OSM has no name, and it alone is not enough at
  high skew.
- **A divided road beneath needs every carriageway blocked.** Blocking two named
  carriageways at 590067 still let the route hop 34 m onto a parallel lane for
  0.01 mi. Enumerating every ground edge inside the footprint fixes it.

## What the architecture already provides

1. **Which road is carried and which pass beneath** — the feature engine already
   resolves this per structure, with NCDOT route IDs, and it is the hard part.
   The twin-deck and road-beneath cases are already pinned by `features.test.js`.
2. **The ingest pattern** — edge function, table, `*_client` view, and
   `trigger_ingest(source, body)` cursor resume. The traffic work (B.H.09–11)
   proved this shape on 1.2M rows, including recovery from a stalled hand-off.
3. **Source precedence** — the `source` enum ordering
   (REVIEWED > DERIVED > PUBLISHED > PROPOSED) gives a measured value a home as
   DERIVED, standing beside NCDOT's published code rather than overwriting it.
   Where the two disagree, the disagreement becomes a finding. That is the
   tool's existing pattern, not a new one.
4. **The dimensions needed to build the footprint** — the SNBI layer carries
   `StructureLength`, `BridgeDeckWidth` and `FedSkew`. These are *not* in
   `BFIELDS` today and must be added to the fetch.

## What is new

### A routing engine that can be told a span is gone

OSRM — used for the units study — **cannot do this**. It has no avoid or exclude
primitive; `exclude` only accepts profile classes (motorway, toll, ferry).

Valhalla can, two different ways, and **both are needed**:

| primitive | blocks | correct for |
|---|---|---|
| `exclude_locations` | the single nearest edge | the **bypass** case |
| `exclude_polygons` | every edge intersecting an area | the **collapse** case |

The distinction is not cosmetic. For the bypass case an area block would also
cut the road *beneath* the bridge, and at a grade separation a detour may
legitimately pass under it. For the collapse case an edge block is not enough:
at 590067 blocking the carriageway moved the route laterally by 34 m onto a
parallel one and added 0.01 mi. Debris covers an area, so the block must be an
area.

Where both succeeded they agreed exactly — 12.57, 12.49, 12.34 and 11.88 mi at
four offsets on 110102.

### The road graph cross-checks NCDOT

Valhalla's `/locate` with a radius returns, for every edge at a crossing, a
`bridge` flag, heading, classification and a correlated point on that edge. This
is what separates the deck from the road beneath, and it independently
corroborates the inventory: OSM bridge-edge lengths came out 229 / 164 / 248 ft
against NCDOT's `StructureLength` of 220 / 198 / 227 ft.

### Anchor placement is the measurement's definition, not a detail

Blocking is edge-level, so the two endpoints must lie beyond the blocked span.
Three findings, each from a failed run:

- Endpoints placed *on* the blocked edge return "no path" every time.
- The value drifts with offset — 12.72 mi at 150 ft from the structure falling to
  11.88 mi at 2,640 ft, because the endpoints move toward the detour itself. The
  faithful answer is the **minimum viable offset**, just clear of the structure.
- On a freeway there is no way off between the last ramp and the bridge, so a
  short offset is genuinely unroutable. I-85 beneath 590028 reported NO DETOUR
  at 0.5 and 1 mi and only resolved at 2 mi. The honest anchors are therefore the
  **nearest diversion points**, found by crawling outward along the road
  (0.5, 1, 2, 4 mi) until a route exists — which is also what an authority
  actually closes.

### Every value needs a validity test

Without one the measurement is silently wrong rather than absent. Each test below
was added because it caught a real error:

1. **Anchors must be opposed** — the open route between them must be within about
   1.8x their straight-line separation. This caught an anchor on the opposite
   carriageway that had produced a 4.66 mi "straight line" across a 0.10 mi span,
   and a trace that gave a 16 mi baseline for a half-mile gap.
2. **The open route must actually use the blocked span** — measured as
   point-to-segment distance from each blocked point to the route's path. Doing
   this against the route's *vertices* instead is wrong and rejects good
   measurements: Valhalla returns a generalized shape, 14 points over half a
   mile, so a route running directly over a blocked point reads as 79 m away.
   Against the path it reads 0 m.
3. **Blocking must lengthen the route** — a blocked route shorter than the open
   one means the block missed, and a negative "additional travel" was exactly how
   that surfaced.
4. **Keep probing outward.** A freeway has no exit between the last ramp and the
   bridge, so the first probe distance returning no path is not an answer. Only
   after every probe out to 8 miles has been blocked is NO DETOUR reported.
5. **Trace only as far as needed.** Tracing the road 12 miles out to place a
   quarter-mile anchor lets the traced path leave the road entirely; the anchor
   then lands on a different highway. Tracing to roughly three times the probe
   distance keeps it on the road, and recovered 590045 from UNMEASURED to a
   clean +3.72 mi.

A value failing any test is reported as UNMEASURED with the reason, never as a
number.

## Measured results

**Bypass**, against NCDOT's coded value. Both NCDOT layers agree exactly on
these — `DETOUR_LEN` on the bridge layer and `DetourLength` on the SNBI layer are
the same data; only the federal file differs.

| structure | over | code | measured around | additional |
|---|---|---|---|---|
| 490058 | Tuckasegee River | 4 | 4.61 mi | 4.54 mi |
| 110102 | Johns River | 12 | 12.71 mi | 12.64 mi |
| 460008 | Lumber River | 14 | 15.36 mi | 15.28 mi |

These track the code in **miles** considerably more tightly than the earlier
nearest-crossing proxy did, which independently strengthens the units finding in
`detour-length-units.md`.

**Both modes**, at grade separations, with the road below open to the bypass and
the deck open to the collapse:

| structure | carried road, deck blocked | road beneath, ground blocked |
|---|---|---|
| 590028 SR1601 over I-85 | +5.77 mi | I-85 N +1.35, S +1.79 |
| 590067 SR1625 over I-85 | +5.28 mi | +0.01 both ways — parallel route at the site |
| 590019 US21 over I-77 | +3.29 mi | I-77 N +0.43, S +0.23 |
| 590048 I-277 SBL over I-77 | +1.99 mi | I-77 N +0.80, S +0.19; ramps +2.44 / +0.18 |
| 590045 I-77 NBL over SR1128 | +0.11 mi — see below | Westinghouse Blvd +3.72 mi |
| 590046 I-77 SBL over SR1128 | +0.02 mi — see below | Westinghouse Blvd +3.72 mi |

The twin structures 590045 and 590046 return the **same** figure for the road
beneath, which is a consistency check passing: one roadway under two decks is one
closure.

Their bypass figures are the open question. Blocking the whole crossing rather
than the single deck changed nothing, so the short detour is not a hop onto the
twin — there is a genuine parallel path beside I-77 at that location. A detour
shorter than the structure's own span should nonetheless be flagged for review
rather than published quietly.

**The collapse column is not comparable to NCDOT's code.** The coded item
describes the route carried; only the bypass column can be checked against it.

## Scale, and the one real constraint

14,262 bridge structures; 3,280 with a highway beneath. At roughly 3 route calls
per bypass and 4–12 per road beneath (the crawl), a statewide pass is on the
order of 10^5 calls. **The public Valhalla instance cannot be used for that** —
it is a courtesy service with no SLA. A North Carolina OSM extract self-hosted
behind the ingest function removes the limit and the dependency, and makes the
result reproducible at a known graph vintage.

Recommended shape, matching the traffic work exactly: precompute statewide into a
table with a vintage, serve it through a client view, and recompute on demand
only for a dropped pin, whose point is by definition not in the table.

## What this is not

It is **not B.H.17**. B.H.17 is NCDOT's published coded item for the carried
route; this is a derived measurement standing beside it. The collapse detour has
no SNBI item at all. Keeping them separate is what lets a disagreement be
reported instead of hidden.

It also does not answer whether an oversize or overweight vehicle can use the
detour. That is B.H.12–B.H.16 (clearances and widths), a separate group.

## Statewide run — 13 October 2026

Self-hosted Valhalla on the OSM North Carolina extract of 12 October. The graph
built in 173 seconds. Against the public instance, the same code gave identical
results to the hundredth of a mile on the three reference crossings, about 40x
faster. The full pass took about 18 minutes on two cores. Pipeline:
`tools/detour/` in the repo, re-runnable when the map updates.

### Results

| road on the bridge (bypass) | count | share |
|---|---|---|
| measured | 12,372 | 86.7% |
| no detour — far side reachable only over this bridge | 1,066 | 7.5% |
| bypass at the site | 639 | 4.5% |
| unmeasured, with reason | 185 | 1.3% |

Road beneath (collapse), only where NCDOT records a highway beneath: 5,339
measured, 1,101 bypass at the site, 410 unmeasured, 7 no detour. Median
additional travel when the road beneath closes: 2.06 mi; 90th percentile 6.23 mi.

### What changed in the method, and why

Each of these was found by running a sample and looking at what failed:

- **NCDOT decides what gets measured; the map only measures it.** 72% of
  structures are waterway-only by NCDOT's coding. Looking for "roads beneath" in
  the map found driveways near creek bridges. A road beneath is now sought only
  where NCDOT records a highway beneath. The reverse case, NCDOT saying a highway
  is there and the map finding none, is reported as its own finding.
- **Untagged bridges.** 14% of a sample had the road in the map but no bridge
  tag on it, which is common for small creek crossings. The nearest road segment
  is blocked instead, and with no junction between the bridge and the segment
  ends that is the same closure. 2,272 decks were inferred this way and are
  flagged `deck_inferred`. This is never done where NCDOT records a highway
  beneath: at 780170, a closed SR1360 over US 220, the nearest road is US 220
  itself.
- **Dead ends.** 1,575 structures first failed because the traced anchors never
  crossed the bridge. Re-anchored at the deck's own ends, 940 proved to be
  bridges that are the only way to the far side (NO DETOUR), 619 measured
  normally, and 16 stayed unmeasured.

### Findings to take to NCDOT

**Units: settled.** Reading NCDOT's code as miles fits better than reading it as
kilometres on 95% of 11,005 structures. From code 10 upward, the median
measured-to-code ratio is 1.03-1.04. The field is in miles.

**Code 1 behaves like a default, not a measurement.** It is on 5,087 structures,
36% of the state. On those, the measured additional travel runs a median 2.4x
the code, 193 have no detour at all, and 337 have a bypass at the site. Agreement
improves steadily with the code:

| code | n | median measured / code | within +/-50% |
|---|---|---|---|
| 1 | 4,489 | 2.42 | 24% |
| 2 | 1,950 | 1.99 | 27% |
| 3-5 | 3,026 | 1.40 | 51% |
| 6-9 | 1,283 | 1.11 | 73% |
| 10-19 | 545 | 1.04 | 75% |
| 20-98 | 263 | 1.03 | 80% |

**Code 99 mostly means a dead end.** Of 1,225 structures coded 99, 777 (63%) are
measured as NO DETOUR, found independently. 337 have a measurable detour, median
5.0 mi, which is worth asking NCDOT about: either 99 means more than "no detour",
or those detours use roads NCDOT doesn't count.

Questions for the Structures Maintenance Unit: how code 1 is assigned; what 99
means precisely; and whether B.H.17 will be submitted from this field.

### Still open

- **Pin drop, live.** A pin on a known structure can show that structure's
  measured values. Measuring at an arbitrary point needs a routing service
  running continuously, which is a hosting decision.
- **Graph vintage.** Results are pinned to the 12 October 2026 extract. Re-run
  when the map updates materially.
- **Migration 0042.** Written and committed. It had not yet reached the database
  as of this writing, because `apply_migration` timed out four times without
  executing.

## Culverts and pipes, and the tool — later the same day

**Culverts and pipes added.** The first run covered NCDOT's bridge layer only:
14,262 structures out of the 23,022 the tool lists. A live end-to-end test in
Burke County caught the gap. Every bridge was measured, but 55 culverts and pipes
showed "not measured". The 5,414 culverts and pipes statewide were then run
through the same pipeline on the same graph: 99.3-99.5% answered, and 5,019 of
the decks were inferred, since culverts are rarely tagged in the map. From code
10 upward the median measured-to-coded ratio is 1.00 across 229 of them, so the
inference holds. Railroad bridges, walkways and signs carry no road and are
deliberately left out.

**Combined, 19,676 structures:** 17,320 measured, 1,383 no detour, 752 bypass at
the site, 221 unmeasured (1.1%). With culverts included the units fit is 89% as
miles across 15,385 structures, against 95% for bridges alone, because culverts
are mostly short detours where miles and kilometres sit close together. From code
10 up the median ratio is unchanged at 1.03. Code 1: 7,132 structures, 36%,
median 2.3x. Code 99: 1,005 of 1,579 (64%) measured as dead ends.

**In the tool.** B.H.17 (`DETOUR_LEN`) is read from the bridge layer and shown
beside the measurement:

- in a Detour length section of the bridge panel
- in two numeric table columns
- in eight CSV columns
- in the pin popup, which gives the bridge's own detour on its carried road
  and the road-beneath detour on a road under it

Four findings are weighted so detour never outshouts BH06/BH07. Three warnings
where the network contradicts the code:

- a detour coded where the bridge is the only way across (377)
- a 99 with a way around (551)
- a 0 with more than 2 miles to go (346)

And one note for a gap of more than half and more than 5 miles (1,986).

A new test suite, `detour.test.js`, has 61 assertions, and the full regression is
470 assertions on each of three builds, all passing. The built tool was also
run live against NCDOT and the database.
