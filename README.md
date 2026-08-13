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

## A reviewer's correction is what gets validated

Enter a corrected BH06 or BH07 in the bridge panel and every check re-runs against **that**
value instead of NCDOT's published one — findings, map colour and summary counts all move.
Corrections used to be stored and exported without ever being tested, so a correction that was
itself wrong reached NCDOT unchallenged.

A correction that fixes the problem clears the finding. A correction that is wrong fails, in
front of the person who just typed it. Corrected values carry a **REV** tag everywhere they
appear, and the panel shows the published number struck through beside them, so which number a
finding refers to is never a question. A corrected row also carries a standing note, so it can
never be mistaken for a clean published one.

This stays strictly separate from clearing a finding: a correction changes *what is tested*,
clearing changes *whether a finding counts*.

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
tests/    request-counting cache suite and basemap-fallback suite (Playwright, all endpoints mocked)
supabase/ database schema as migrations, plus the round-trip verification script
```

## The database

The browser tool holds review work in a file each reviewer keeps. That is the right answer for
one person and the wrong one for a team feeding a March submittal, so the same model now exists
as a Postgres schema on Supabase — see [`supabase/README.md`](supabase/README.md).

The design decision worth knowing from outside: **value sources are rows, not columns.**
`feature_values` is keyed on `(feature, field, source)` where source is PUBLISHED, DERIVED or
REVIEWED, so a derivation pass writes only its own row and structurally cannot overwrite a
reviewer's correction. Precedence is the enum's declaration order and is resolved once, in a
view, rather than re-implemented wherever a value is read.

## The background map has six sources, and needs only one

It opens on Esri aerial imagery, and the fallback order is aerial-first.
Agency networks block Esri's tile host often enough that treating it as the only option was a
mistake. The tool now falls through six independent hosts — Esri, an Esri mirror, USGS National
Map, NC OneMap, CARTO, and a road basemap rendered live off `gis11` — changing **host** at each
step rather than trying another style on one that is already refused. Any single reachable host
is enough, and the last of them is the same server the bridge data comes from, so a background
map is available wherever the tool works at all. Each source is also selectable by hand under
**Basemap**, labelled with its host, and **Diagnostics** probes all six and says which answered.

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
| `server.arcgisonline.com`, `services.arcgisonline.com`, `basemap.nationalmap.gov`, `services.nconemap.gov`, `basemaps.cartocdn.com` | background map tiles — cosmetic, and **any one** suffices; the tool falls through them automatically. NCDOT roads rendered off `gis11` are the final fallback, so a background is available wherever the data is |

## Sign-in, and what it is for

There is no password gate any more, in any build. There used to be one, and it was worse than
nothing: it hashed a password into downloadable JavaScript, where View Source, deleting the
check, or calling the functions from the console all defeated it in seconds — while reading
enough like protection to tempt someone into reusing a real password in a file that publishes
it.

Reviewers now sign in with a link emailed to them, and **the reviewer's name is no longer
something anyone types**. It comes from the account, and the database overwrites it from the
request's token on the way in, so a correction cannot be signed with someone else's name.

Signing in changes what the interface *draws*. It does not grant anything. Authority is the
token, checked by Postgres: anonymous visitors get `SELECT` and nothing else, a signed-in
reviewer gets the review surface and never `PUBLISHED`, and no client role can delete anything
at all. Forcing the signed-in flag from the browser console gets the buttons back and achieves
nothing, which is the point of having moved the rules to the server — and is asserted by the
test suite rather than assumed.

## A note on the builds

`dist/NCDOT_BH06_BH07_Validator.html` carries its mapping library, fonts and auth client inside
the file. That's the copy to email to staff and the one that survives a locked-down agency
network. All three builds now contain exactly the same application code; `docs/index.html`
differs only in carrying public-page metadata.
