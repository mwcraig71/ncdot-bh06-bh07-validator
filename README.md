# NCDOT SNBI BH06 / BH07 Validator

Validates the two SNBI items most likely to fail a North Carolina bridge submission —
**BH06 (LRS Route ID)** and **BH07 (LRS Milepoint)** — for any bridge, route, county, or all
23,022 structures statewide.

Runs in the browser. One HTML file, no install, no ArcGIS licence, nothing uploaded anywhere.
The bridges under test are read live from NCDOT; the reference data they are tested against is
loaded quarterly into a Postgres database by a scheduled job, so a reviewer's machine no longer
has to pull it.

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

## Reference data is loaded on a schedule, not by the reviewer

Bridges are re-queried every run, because they are the thing under test. Everything they are
tested *against* is not. County boundaries, the SNBI structure inventory, FHWA's HPMS submittal
and every route's true extent are pulled quarterly by scheduled Edge Functions and written to
Postgres; the browser reads the result.

That is a different thing from caching them better. The old client asked NCDOT for the same
reference data on every run and then tried to remember what it had already asked for, which is
two problems — the traffic, and the bookkeeping about the traffic. Neither exists now: each of
these is one indexed read, so re-reading is cheaper than deciding whether to.

What it bought, measured on one county:

| | before | after |
|---|---|---|
| a full run, everything on | ~90 s | **9 s** |
| SNBI inventory | 8 paged ArcGIS layer queries | 1 read |
| deep check, 434 routes | 4 statistics queries against the road network | 2 reads |
| HPMS | up to 100 county pulls from `geo.dot.gov` | 1 read |

The route extents are the biggest of these: **386,644 routes**, every one measured from
NCDOT's road network, so "is this milepoint past the end of the route?" is a join rather than a
live measurement. Route geometry for the red overlay is still drawn live and still cached per
route, because it is a map overlay rather than reference data.

**Settings → Data** shows the vintage of each source — what the service itself reported, and
when it was loaded — because that is what an export has to cite. Beside it, one button asks the
server to re-read NCDOT now, for when a republish lands between quarters.

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
tests/    Playwright suites — every endpoint mocked, no network needed
supabase/ database as migrations, the ingest Edge Functions, and the verification scripts
```

## The database

The browser tool holds review work in a file each reviewer keeps. That is the right answer for
one person and the wrong one for a team feeding a March submittal, so the same model now exists
as a Postgres schema on Supabase — see [`supabase/README.md`](supabase/README.md).

It also holds the reference data the tool reads, loaded by five scheduled Edge Functions —
one per source. Ingest writes `PUBLISHED` rows only and upserts them, so a republish cannot
disturb a review; where a republish moves a published value that already carries a review, it
records a **divergence** and resolves nothing, because that is a person's decision.

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
| `gis11.services.ncdot.gov` | the bridges under test, route geometry for the map, NCDOT's own route/milepost tool |
| the Supabase project | everything the bridges are tested against — county boundaries, SNBI inventory, HPMS, route extents |
| `geo.dot.gov` | FHWA's published HPMS submittal — read by the scheduled ingest, **not** by the browser, so it no longer has to be reachable from a reviewer's machine |
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
