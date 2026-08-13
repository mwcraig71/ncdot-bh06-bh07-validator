# NCDOT SNBI BH06 / BH07 Validator

Validates the two SNBI items most likely to fail a North Carolina bridge submission —
**BH06 (LRS Route ID)** and **BH07 (LRS Milepoint)** — for any bridge, route, county, or all
23,022 structures statewide.

Runs entirely in the browser. One HTML file, no install, no login, no ArcGIS licence, nothing
uploaded anywhere. All data is read live from NCDOT's and FHWA's public services, so it follows
NCDOT's quarterly republishing on its own.

**→ [Open the tool](https://mwcraig71.github.io/ncdot-bh06-bh07-validator/)**
*(edit this link once Pages is live)*

Built by [Strinteg Corporation](https://strinteg.com).

---

## What it checks

**FHWA submittal rules** — the ones that actually fail on submission:

| Rule | Test |
|---|---|
| BH06-1 | Not null, ≤120 characters, required where a highway is carried |
| BH06-3 | Route ID must appear in the state's HPMS submittal to FHWA |
| BH06-4 | Not reported where B.H.18 shows the feature is carried on another bridge |
| BH07-1 | Valid numeric value |
| BH07-2 | 8 digits maximum |

**That is the entire FHWA check set.** Nothing in it tests whether the milepoint is anywhere
near the route — a statewide mile marker number, or the measure of the road underneath, submits
perfectly clean. So the tool adds a second group of checks for values that pass FHWA and are
still wrong:

- **Locate check** — walks the route's own geometry to the reported milepoint and measures how
  far that lands from the structure. Distance follows the road, around every curve.
- **Deep check** — flags milepoints outside the route's real extent in that county.
- **Resolve carried** — triages "BH06 is not a carried route" into fixable, stale description,
  or needs-a-human.
- **Fill missing** — derives BH06/BH07 where there are none, and refuses to guess where no
  highway is carried on the structure.
- Duplicate route+milepoint pairs, routes that don't exist, county-code mismatches,
  non-inventory directions, and more.

## Reference data is read once

Bridges are re-queried every run, because that is the thing you are asking about.
Everything behind them is not. County boundaries, the SNBI structure inventory,
FHWA's HPMS submittal and route geometry are each pulled once for the scope that
needed them and reused for the rest of the session — a county pull answers every
single-bridge lookup inside that county, and a statewide pull answers everything.

Queries are scoped to what is being asked, too. A single-bridge lookup asks for
one structure number in one layer: **one request**, where it used to trigger a
full statewide pull of all eight structure layers before showing a single result.

**Settings → Data cache** shows what is in memory and offers one button to drop
it all and re-read, for when NCDOT republishes while the page is open.

## Some things it established along the way

- **NCDOT's mileposts are correct.** Measured against the road network they track along-the-road
  distance to within 0.28%, and diverge from straight-line by 17.9%. Across two whole counties
  the published milepoint lands a median of about **one foot** from the structure.
- **Mileposts are county-scoped** — they reset to zero at every county line and are *not* the
  mile marker sign number. The last three digits of BH06 are the county.
- **HPMS carries no ramps.** All 721 ramp-carried bridges fail BH06-3, and no amount of
  correcting route IDs changes that.
- **The "23,022 bridges" population is really ~18,000.** The bridge layer also holds 2,853 sign
  structures and 2,025 pipes, which are not NBI structures.
- Concurrent routes on one deck still get a **single** BH06/BH07 — the extra designations are
  route records under one highway feature.

## Repository layout

```
docs/     the published site (GitHub Pages serves this folder)
dist/     downloadable builds — self-contained, works offline and on locked-down networks
src/      tool_template.html + build.py — everything is generated from these
guide/    user guide, deployment notes, and the original findings brief
data/     the 213,475 NC HPMS route IDs, and review queues
tools/    a Python CLI for the same checks, for bulk/offline work
tests/    request-counting cache suite (Playwright, all endpoints mocked)
```

## Building

```bash
npm install leaflet@1.9.4 @fontsource/oswald @fontsource/open-sans
python3 src/build.py
```

Produces the three builds. `src/tool_template.html` is the only file to edit — everything else
is generated.

## Data sources

All public, no authentication, and all confirmed to allow cross-origin requests from any HTTPS
origin:

| Host | For |
|---|---|
| `gis11.services.ncdot.gov` | bridges, road network with LRS measures, county boundaries, NCDOT's own route/milepost tool |
| `geo.dot.gov` | FHWA's published HPMS submittal |
| `server.arcgisonline.com` | background map tiles (cosmetic — the tool draws county outlines if blocked) |

## A note on the two builds

`dist/NCDOT_BH06_BH07_Validator.html` carries a two-password gate and its mapping library
inside the file. That's the copy to email to staff and the one that survives a locked-down
agency network.

`docs/index.html` has **no gate and no password code at all** — deliberately. A gate in
downloadable JavaScript protects nothing and misleads, and there is nothing to protect here:
every input is already published by NCDOT and FHWA, and all review work stays in a file on the
visitor's own machine.
