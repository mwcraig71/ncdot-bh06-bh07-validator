# Where AADT should come from

**You are right that the bridge record is not the source.** Measured against NCDOT's live
services on 14 August 2026, in Mecklenburg County.

---

## The short version

**Use the NCDOT Traffic Survey AADT station file.** Current release: **2024 values, published
September 2025**, 48,687 stations statewide, keyed on the **11-digit LRS Route ID** — the same
key BH06 already validates against.

Everything else in the chain is downstream of it. The AADT on the bridge record is a copy of a
station value, taken at some unrecorded moment, and left there.

---

## The evidence

**The bridge record is a copy, not a source.** Of 355 Mecklenburg structures where the bridge
record carries an AADT and there is a count station on the same route within half a mile:

| | |
|---|---|
| bridge AADT **exactly equal** to the station's | **295 of 355 (83%)** |
| median difference | **0.0%** |
| within 10% | 87% |
| out by more than half | 18 |

An 83% exact match is not a coincidence and not an independent measurement. NCDOT's bridge
AADT *is* the station value. The question is only ever **which year's**.

**And the bridge record does not say which year.** There is no AADT year on NCDOT's published
bridge layer — B.H.11 has nothing to read from. The station file carries a separate column for
every year from 2002 to 2024, so the year is not inferred, it is stated.

**Half the inventory has no AADT at all.**

| | |
|---|---|
| NC structures in the published inventory | 23,022 |
| carrying any AADT | **12,006 (52%)** |
| Mecklenburg structures | 1,282 |
| Mecklenburg structures with no AADT | **826 (64%)** |

**Meanwhile the station file is nearly complete and nearly current.** Of 1,941 Mecklenburg
stations, **1,940 carry a 2024 value**. All 1,941 are flagged active.

---

## The four candidates, and what each is actually for

### 1. NCDOT AADT stations — the primary source

`NCDOT__2024_AADT_Stations_published_September_2025` (ArcGIS Online, NCDOT org)

- 48,687 stations; 2024 values published September 2025; series back to 2002
- **`Route` is the 11-digit LRS Route ID** — verified, e.g. `40002459060` = SR 2459, Mecklenburg
- **Values are two-way totals**, all lanes both directions. Confirmed in NCDOT's own file
  description, and worth pinning down: it is the question that decides whether a number is
  wrong or merely differently defined
- `Coll_Cycle` says whether a station is counted on an odd year, even year, annually, or on a
  six-year supplemental cycle — so a blank year means *not counted*, not *no traffic*
- `Active` distinguishes the live monitoring inventory from retired stations
- These are the numbers NCDOT submits to FHWA, so HPMS and the NBI are both downstream of them

**Limitation:** points, not segments. A bridge has to be associated with a station — which the
next layer solves.

### 2. NCDOT AADT traffic segmentation — the association, not the value

`NCDOT_AADT_Traffic_Segmentation` (layers 1–3: secondary, primary, interstate)

- 47,071 segments carrying `RouteID`, `BeginMP`, `EndMP`, `AADT`, `AADTT`, `SU_AADT`, `MU_AADT`,
  `SU_PCT`, `MU_PCT`, and **`TMS_ID`**
- Linear-referenced on the same route-and-milepoint system the tool already walks, so a bridge's
  BH06/BH07 pair lands in a segment directly — no spatial guessing
- **`TMS_ID` resolves to a station's `LocationID` 97.8% of the time** (1,344 of 1,374 in
  Mecklenburg), so the segment tells you *which station governs this piece of road*

**But its values are stale.** Last edited 6 November 2023. On bridge 590114, the segment reads
79,500 where its own station reads 84,000 for 2023 and 86,500 for 2024.

**So: take the geometry and the `TMS_ID` from the segments, take the number from the station
file.** That is the pattern — segments answer *which station*, stations answer *what and when*.

### 3. NCDOT probe-estimated AADT — for the roads nobody counts

`NCDOT_AADT_ProbeEstimated_2023`

- **1,210,860 segments**, `RouteID` + `BegMP`/`EndMP`, with `Estimated`, `Lower_95_P` and
  `Upper_95_P` — a modelled AADT from probe data *with a 95% confidence interval on every value*
- Covers the secondary and non-system roads that have no count station at all

This is what answers the 826 Mecklenburg bridges with nothing. An estimate of 3,380 with a
stated range of 2,400–5,200 is a usable number provided it is labelled as an estimate. The
confidence interval is the reason it can be used honestly.

### 4. HPMS and the NBI — derived, and last in the queue

Both are submittals *made from* the station data, on an annual cycle with a reporting lag. HPMS
is the right source for a national comparison or a cross-state check. Neither should be the
source of a value NCDOT itself publishes more currently and more completely.

---

## What this means for B.H.09, B.H.10 and B.H.11

- **B.H.09 (AADT)** — station value for the year, associated by `TMS_ID` off the segment
  containing the feature's BH06/BH07. Falls back to the probe estimate, labelled as one.
- **B.H.10 (truck AADT)** — the segmentation carries `AADTT`, `SU_AADT` and `MU_AADT`; there is
  a parallel `NCDOT_AADTT_Traffic_Segmentation` service. Same staleness caveat.
- **B.H.11 (year of AADT)** — this is the item that makes the case. The station file states the
  year; the bridge record has no year field at all. Any B.H.11 currently being reported from the
  bridge record is unverifiable by construction.

And the same trap as BH06/BH07 applies: all three are **per highway feature**. A road passing
beneath a bridge has its own AADT, and a bridge record with one AADT field cannot hold it.

---

## One caution before acting on this

The station values are two-way totals. If any downstream consumer expects directional volumes
on a divided facility, converting is a decision with a rule behind it, not an arithmetic halving
— which is exactly the class of error that put an interchange exit number in BH07 on 590819.

---

*Measured 14 August 2026 against NCDOT's published services. Strinteg Corporation.*
