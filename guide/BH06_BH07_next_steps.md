# NCDOT BH06 / BH07 — Next Steps

**Bottom line: don't build a GIS, don't build a clicker, don't cold-call NCDOT GIS. Both things you need already exist as public NCDOT web services, and I tested them today.**

---

## 1. NCDOT already built the TxDOT pin-drop tool

`NCDOT_Tools/NCDOTIdentifyRouteMilepostUsingPointTool` — a public ArcGIS geoprocessing
service, published 8/6/2025:

> *"Returns the route/milepost on an NCDOT route at a user specified map point."*

That is literally the TxDOT capability. It's not in the map viewer UI, which is why nobody
found it — it's a service endpoint. It takes **up to 1,000 points per job** (batch, not
one-at-a-time clicking) and returns `RID` + `MEAS` plus concurrent routes 2–6.

I ran three Charlotte bridges through it. It matched NCDOT's published bridge mileposts to
six decimals.

## 2. BH06 and BH07 are already populated for ~98% of bridges

`NCDOT_Bridges/MapServer/0` is a public layer with **23,022 bridges**, and it already carries:

| Field | = | Coverage |
|---|---|---|
| `RTE_ID` | BH06 LRS Route ID (11-digit) | 22,519 populated, 503 = `'NA'` |
| `MP` | BH07 LRS Milepoint (full precision) | same 503 missing |

The 503 gaps are ferries, closed routes, and non-state-maintained structures — not a
systematic hole.

**So the "16,000 bridges" problem is mostly a data-transfer problem, not a data-collection
problem.** Nobody has to click anything 16,000 times.

---

## 3. What I actually built and ran

`ncdot_bh0607.py` — three modes, no ArcGIS license, no login:

- `pull` — dump the statewide table with BH06/BH07 and SNBI validation flags
- `locate` — batch any bridge points through the pin-drop tool
- `compare` — run both and flag every disagreement (the QC run)

**Live test, Mecklenburg County (the hardest case — urban, stacked interchanges), 1,282 bridges:**

```
1,282 bridges | agree 1,095 (85.4%) | needs review 184 | not located 3
runtime ~4 min  →  16,000 bridges ≈ 50 min
```

## 4. The one real technical catch — and the fix

Your instinct about urban bridges was right, but the failure mode is not what you expected.
It isn't "5 routes tied to one bridge." It's this:

**A pin drop returns the nearest route, which at a grade separation is the road *underneath*,
not the road *carried*.**

Bridge 590019 carries US-21; the pin tool returned SR-5544 — the street below it. Offset
0.0000 mi, because the point sits on top of both. That accounts for essentially all 136
route mismatches. TxDOT's tool has the identical limitation; a human is silently fixing it
there every time they read the popup.

**The fix, which I tested and it went 12 for 12:** don't ask for the nearest route, ask for
*every* route within ~150 ft, then pick the one that matches the bridge's `F_CARRIED` string
using the 11-digit decode from your LRS Route ID guide.

```
carries "NC27"     → class 3, number 0027, inventory 0 → 30000027060  ✓
carries "I85 SBL"  → class 1, number 0085, 3rd digit 4 (non-inventory southbound) → 10400085060  ✓
```

Exact decode match → auto-accept. Ambiguous → human review queue. That turns 16,000 bridges
into a few hundred eyeballs, not 16,000.

---

## 4b. Why BH07 looks low — NCDOT mileposts are COUNTY-based

They look low because they reset to zero at every county line. Verified against the road
network:

| Route | Gaston | Mecklenburg | Cabarrus | Rowan | Davidson | Guilford |
|---|---|---|---|---|---|---|
| I-85 | 0 → 19.4 | 0 → 21.2 | 0 → 14.1 | 0 → 19.4 | 0 → 22.5 | 0 → 21.0 |

I-85 is ~234 miles across NC, but **no county segment ever exceeds that county's own width.**
Same for I-40 (0 → 30.2 Buncombe, 0 → 27.7 Wake, 0 → 12.8 Durham).

Corroborating numbers:
- **Max route measure anywhere in NC: 84.2 mi** — and that's the I-485 beltway, which loops
  entirely inside Mecklenburg.
- **Zero of 23,022 bridges have MP ≥ 100.** 31% are under 1.0, because 12,269 bridges sit on
  secondary (SR) routes, which are only a few miles long inside a county.
- The milepost hatching layer you found carries `RteId` + `Milepost` on the *same*
  county-based system — so your hack was reading the right scale.

**This is correct for the submission.** BH06's last three digits *are* the county code, so
BH07 has to be measured on that county-scoped route. It's self-consistent, and HPMS carries
the same IDs.

### ⚠️ But this is the trap — and it may already be in your data

**County LRS milepoint ≠ the mile marker sign.** Interstate mile markers in NC are
*statewide*: I-85 signs run 0 at the SC line to ~234 at the VA line. A bridge in Mecklenburg
sitting next to a sign reading **MILE 38** has an LRS milepoint of **8.5**.

Anyone who coded BH07 off mile marker signs, Google, or the "route milepost" readout is
producing wrong numbers — **and the error grows the further the bridge is from the county
line.** This is very likely the two-numbers-on-one-popup thing you and the team hit (the
"2.8 vs 26.08" case): one is the county LRS measure, the other isn't.

**Worth checking what's already been coded before anyone does more of it.** A bridge whose
BH07 exceeds its county's route length is provably wrong, and that's a one-query test.

## 4c. Do multi-route bridges get multiple BH06/BH07? Mostly **no** — and that's good news

SNBI's data structure is three levels deep, and the level BH06/BH07 sits on is the one people
get wrong:

```
BRIDGE
 └─ FEATURE   (B.F.01 = H01, H02, H03…; B.F.02 = C carried / B below)
     ├─ ROUTE record(s)   (B.RT…)  ← THIS is what repeats for concurrent routes
     └─ HIGHWAY record    (B.H…)   ← BH06 / BH07 live here, ONE per highway feature
```

From the spec, §4.2 Routes:

> *"Each highway feature identified in Item B.F.01 has at least one associated route record.
> A highway feature has multiple route records **only if multiple routes with route numbers
> share the highway feature**."*

And §4.3 Highways: *"The items in this subsection are reported for each highway **feature**."*

So the three cases resolve like this:

| Situation | How many BH06/BH07? |
|---|---|
| I-277 and US-74 co-signed on the same deck | **One.** The extra designations go in the *Route* records (B.RT), not B.H. |
| Bridge carries US-21, spans I-77 underneath | **One** — for US-21 only. The road below gets none. |
| One structure carrying two physically separate highway roadways | **Two** — genuinely multiple features. Rare. |

**The route underneath gets no LRS route ID at all.** That's exactly what the validation rule
you read out says — *report when B.F.01 begins with H and B.F.02 = C* — where **C = "Carried
on bridge"** and **B = "Below bridge."** FHWA's own over/under crosswalk is explicit:
B.H.06 and B.H.07 are assigned only to the H01 feature, the highway carried on the bridge.

**So the workload doesn't multiply.** Roughly one BH06/BH07 per bridge, not five.

### But it makes the carried-vs-under fix mandatory, not optional

If the road underneath must *never* be the answer, and the pin-drop tool returns the nearest
route — which at a grade separation is the road underneath — then the naive approach is wrong
in precisely the way that matters. The `F_CARRIED` matcher isn't a refinement, it's the
requirement.

### Sizing the concurrency problem — it's much smaller than feared

Across all 23,022 bridges, `F_CARRIED` names more than one route on **1,012 bridges (4.4%)**.
Not "all the urban ones." And on 911 of those (90%), NCDOT's published BH06 is already one of
the routes named as carried.

That leaves **101 bridges** where the published BH06 isn't any route the bridge is recorded as
carrying → `review_concurrency.csv`. Some are stale `F_CARRIED` strings rather than bad LRS
(e.g. 280515 reads "US52, NC8S" but is coded I-285 — that stretch *was* redesignated), but
some look wrong (130015 reads "US64, NC18 BUS." and is coded SR-1300). Either way it's a
101-row eyeball, not 16,000.

When routes are concurrent, NCDOT's pick skews US (460) > Interstate (345) > NC (126) >
ramp (61) > SR (10). Any of them passes validation as long as it's in HPMS — which is the
next section.

## 5. Risks worth flagging to Brian now

1. **The HPMS exposure is 3,984 bridges — bigger than I first thought.** Full breakdown in
   `review_hpms_risk.csv`:

   | Count | Why it may fail *"LRS ID not found in HPMS"* |
   |---|---|
   | 1,244 | non-inventory **southbound** route (3rd digit 4) |
   | 1,204 | class 5 **non-system** — municipal/private |
   | 960 | non-inventory **westbound** route (3rd digit 6) |
   | 503 | no LRS route assigned (`RTE_ID = 'NA'`) |
   | 85 | non-inventory **counterclockwise** (3rd digit 9) |

   **The non-inventory directional routes (2,289 total) are the new find.** HPMS generally
   carries one record per *inventory* direction, so a southbound-only or westbound-only route
   ID may simply not exist in the HPMS extract FHWA validates against. Worth testing against
   NCDOT's actual HPMS submittal *before* March rather than discovering it in the error report.
   If they do fail, the fix is usually to report the inventory-direction route ID instead
   (3rd digit 0) with the corresponding measure.

2. **The 11-digit format itself is not the risk.** The only BH06 checks are non-null,
   ≤120 characters, and present in HPMS. NCDOT's 11-digit ID clears the length check with
   109 characters to spare. Brian can stop waiting on FHWA for that.

3. **Three decimals is a *format* requirement, not an accuracy requirement.** `.750` passes.
   The 8-digit cap is a non-issue — the largest possible value in NC is 84.221, i.e. 5
   digits. No bridge can trip it. Take the full precision the services hand you anyway.

4. **Structure locations are stale.** NCDOT's 8/3/2026 release notes say no structure
   locations were updated this quarter. If a bridge is mislocated (your Charlotte
   fifteen-year example), the pin drop confidently returns the wrong route. The QC run
   surfaces these — a large offset or a route that can't be reconciled with `F_CARRIED`
   is a location error, not a milepost error. **That's a bonus deliverable for Brian.**

---

## 6. Suggested sequence

| # | Step | Effort |
|---|---|---|
| 1 | Full statewide `pull` — hand Brian BH06/BH07 for 22,519 bridges | ~10 min |
| 2 | Add the F_CARRIED decode matcher to `locate` | half a day |
| 3 | Full statewide `compare` QC run | ~1 hr unattended |
| 4 | Triage the review queue (est. a few hundred) | 1–2 days |
| 5 | Settle the class-5 / HPMS policy question with Brian + FHWA | needs a decision |
| 6 | Ship, plus a mislocated-structures list as a freebie | — |

Steps 1–4 are a week of work, not a five-month wait. And step 1 alone probably closes most
of the March gap by itself.

**The one thing still worth an email to NCDOT GIS:** ask whether they'll expose the pin-drop
tool in the public map viewer UI. That's a nice-to-have now, not a blocker — you don't need
them to ship anything for you to make the March deadline.

---

## Endpoints (all public, no auth)

```
Bridges     https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Bridges/MapServer/0
Pin tool    https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Tools/
            NCDOTIdentifyRouteMilepostUsingPointTool/GPServer
Road char.  https://gis11.services.ncdot.gov/arcgis/rest/services/
            NCDOT_RoadCharacteristicsQtr/MapServer/0   (hasM=true, RouteID + BeginMp1/EndMp1,
                                                        RouteID2–6 for concurrencies)
Hatching    https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_MilePostHatching/MapServer
            (goes down to 0.01 mi, not just 0.1 — layer 4)
```

Also there: `NCDOT_Tools/NCDOTReturnRouteTool` (route geometry by county + route number) and
`NCDOT_Locators/NCDOT_StructuresLocator` (geocode straight to a structure).
