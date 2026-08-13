# Bridge 590819 — BH06 and BH07, feature by feature

**I-85 over I-485, Mecklenburg County, Division 10.** Routine element inspection of
24 September 2025, checked against NCDOT's published Road Characteristics LRS on
13 August 2026.

Every number in the "NCDOT's LRS" column was measured, not looked up: the tool
reconstructs the deck footprint, finds which roadways cross it, and reads the
milepoint off each route's own geometry at the structure's coordinates. The
measurement on the carried route lands **0 ft** from the point NCDOT publishes for
this bridge, and returns 2.672 against NCDOT's published 2.672.

---

## The short version

**All five features have a wrong BH07, and all four populated BH06 values are wrong.**

The errors are not random. They are two systematic substitutions:

- **BH07 has been filled in with the interchange exit number.** The two carried
  features read 30.100 — I-85 **exit 30**. The three features below read 10.000 —
  I-485 **exit 10**. NCDOT's own ramp names at this interchange confirm both:
  *Exit 30a South Pineville*, *Exit 30b North Greensboro*, *Exit 10a I-85 N*,
  *Exit 10b South Gastonia*. An exit number is not an LRS milepoint.

- **BH06 has been filled in with a 5-digit legacy route stub, not the LRS Route
  ID.** `10085` and `10485` are route class plus number. NCDOT's LRS Route ID is
  11 digits — class, qualifier, **inventory direction**, five-digit number,
  **three-digit county**. Both of the missing pieces matter here, because this
  structure has two carriageways of each facility beneath and above it, and the
  county is what makes the milepoint mean anything.

---

## Feature by feature

| B.F.01 | B.F.02 | Feature | Report BH06 | Report BH07 | NCDOT's LRS | Verdict |
|---|---|---|---|---|---|---|
| H01 | C | I85NBL | `10085` | `30.100` | **`10000085060` @ 2.672** | both wrong |
| H02 | B | I485N | `10485` | `10.000` | **`10800485060` @ 46.958** | both wrong; BH06 should not be reported at all |
| H03 | B | I485S | `10485` | `10.000` | **`10900485060` @ 18.694** | both wrong; BH06 should not be reported at all |
| H04 | B | I485S RAMP | *(blank)* | `10.000` | **`80005455060` @ 0.943** *(or `80005794060` @ 0.941)* | BH07 wrong; blank BH06 is correct for a below feature |
| H05 | C | I85SBL | `10085` | *(blank)* | **`10400085060` @ 18.466** | BH06 wrong; BH07 missing entirely |

### The single most serious one

**H01: BH07 = 30.100.** I-85 runs **0.000 to 21.155** in Mecklenburg. A milepoint of
30.1 is not merely wrong, it is outside the route's existence in that county — and
it passes every FHWA submittal check, because none of them compares the milepoint
to the route. This is the failure the Deep check exists for. The true value is
**2.672**, and 30.100 − 2.672 ≈ 27.4, which is where I-85 crosses from Gaston into
Mecklenburg. The statewide mile marker was entered where the county measure belongs.

### The two that look right and are not

**H02 and H03 are identical** — same BH06, same BH07 — for two roadways heading in
opposite directions. They cannot be. I-485's two carriageways are separate LRS
routes measured in opposite directions around the loop, and at this structure they
are 28 miles apart in measure:

```
I-485 clockwise  (Inner, northbound here)  46.958
I-485 counter-cw (Outer, southbound here)  18.694
                                           ------
                                           65.652   = the loop's length in Mecklenburg (65.6–65.7)
```

The same arithmetic holds above the deck:

```
I-85 northbound   2.672
I-85 southbound  18.466
                 ------
                 21.138   = I-85's length in Mecklenburg (21.155)
```

Two independent confirmations that all four measurements are right: opposing
carriageways of one facility must sum to its length in the county, and both pairs
do, to within 0.02 and 0.07 miles.

**H05 has no BH07 at all.** If the header value of 30.1 was intended to serve both
carried features, note that the correct values are 2.672 and 18.466 — nothing like
each other, and neither like 30.1.

---

## Structural findings, independent of the values

**The feature designations are out of crosswalk order.** The report numbers
H01 carried, H02–H04 below, **H05 carried**. Every carried feature is numbered
before the first below feature; a carried roadway in fifth position, after three
roadways beneath it, is not a numbering a reviewer can read down.

**The route designations do not restart.** B.RT.01 restarts at R01 inside every
feature. This report runs **R01 through R05 continuously** across the five
features, so "R03" does not identify a route until you also know which feature it
sits in. The tool numbers them correctly *and* records what the document said, so
the disagreement survives rather than being quietly overwritten.

**BH06 is reported on two features below the bridge.** H02 and H03 carry a value;
H04 does not. Under BH06-4 a roadway passing beneath does not get a BH06 at all —
its highway record describes the clearances and the traffic below, and the route ID
belongs to whichever structure carries it. The report is inconsistent with itself
on this point, which is worth raising on its own: two of the three below features
were coded one way and the third the other.

---

## One thing the report has that the tool did not

Until this pass, **590819 was not being checked at all.** The ingest created a
highway feature only where the bridge layer's ServiceOn = 1, and 590819 is coded
**6 — overpass at an interchange**. So did 1,281 other structures, plus 1,286
highway-with-pedestrian, 12 third-level and two others: **2,582 structures that
carry a highway had no feature and therefore no BH06 or BH07 under test.** An
interchange overpass is about the most highway-carrying thing there is. That rule
is now the full NBI set (1, 4, 5, 6, 7, 8), the backfill has run, and 590819 now
carries its published `10000085060 @ 2.672`.

## One thing the tool has that the report does not

The tool finds **two** ramps beneath this structure — `80005455060` and
`80005794060`, both crossing at the angle the recorded 20° skew predicts. The
report has one ramp feature. That is a reviewer's decision, not the tool's, and it
is presented as a candidate rather than asserted.

---

*Measured against NCDOT_RoadCharacteristicsQtr, published 28 June 2026, and
NCDOT_Bridges, published 15 March 2026. Strinteg Corporation.*
