# Publishing the validator to the web

`docs/` is the whole of the front end. One HTML file, no build step, no server code. Upload it
and it works.

There is a back end now — a Supabase project holding the reference data and the review record —
but it is already deployed and the page talks to it directly. Publishing the page does not
involve it.

---

## All three builds are the same code

There used to be a "public" build with the password gate stripped out. There is no gate in any
build any more, so there is nothing to strip: `dist/`, the artifact copy and `docs/index.html`
contain identical application code, and `docs/index.html` differs only by carrying public-page
metadata (title, description, social preview, favicon).

That matters for deployment because it removes the class of bug where the published copy behaves
differently from the one you tested.

## What decides who may do what

Not the page. Postgres.

- Anyone who opens the URL can run every scope, every check, every filter, and export the CSV.
  Every input is already published by NCDOT and FHWA.
- Recording a decision — a status, a note, a corrected BH06/BH07, a cleared finding — needs a
  signed-in account. Sign-in is a link emailed to the reviewer; there is no password anywhere in
  the system.
- No client, signed in or not, can write what NCDOT publishes, and none can delete anything.

The anon key is printed in the page. That is what it is for: it identifies the project, and what
it can actually do is decided by row level security, where anon has `SELECT` and nothing else.
Treating it as a secret would be a misunderstanding of what it is — and the refusal is asserted
from a real anon session over HTTPS in `supabase/tests/anon_api_test.sh`, not inferred from
reading the policies.

## Where to put it

Anywhere that serves static files over HTTPS. In rough order of least effort:

| Host | Notes |
|---|---|
| **GitHub Pages** | Free for a public repo. Point Pages at `docs/` and it is live. |
| **Cloudflare Pages** | Free. Drag the folder onto the dashboard, live in about a minute. Custom domain and HTTPS included. Reads `_headers`. |
| **Netlify** | Free, same drag-and-drop. Also reads `_headers`. |
| **Your existing strinteg.com server** | Drop `index.html` at something like `/tools/bh06/`. IIS, Apache, nginx or a WordPress host's static directory — it is just a file. |

A suggested URL: `tools.strinteg.com/bh06` or `strinteg.com/tools/bh06`.

## Requirements

HTTPS, and nothing else. No Node, no PHP, no environment variables.

The visitor's browser talks to two hosts, plus tiles:

| Host | For | If unreachable |
|---|---|---|
| `gis11.services.ncdot.gov` | the bridges under test, and route geometry for the map | essential |
| `drstmntdbmacdplhjvmx.supabase.co` | county boundaries, SNBI inventory, HPMS, route extents, and the review record | the checks that need reference data cannot run |
| six tile hosts (Esri, Esri mirror, USGS National Map, NC OneMap, CARTO, gis11) | background map tiles | cosmetic — **any one** is enough, the tool falls through them on its own, and if all are blocked it draws county outlines instead |

`geo.dot.gov` used to be on this list. It is not any more: the HPMS submittal is loaded into the
database by a scheduled job, so no reviewer's machine contacts FHWA.

**All of these were tested and confirmed to allow cross-origin requests from any HTTPS origin,
including the POST preflight the heavier checks need.** Nothing needs proxying.

## After you publish

Open it and press **Diagnostics** in Settings. It probes each service from wherever the page is
now and reports what is reachable — a two-second check that the deployment is sound. It also
reports how many reference-data sources have been loaded, which catches "the page is up but the
project is not reachable from here".

---

## Keeping it current

Two different cadences, and it is worth keeping them apart:

**The data** refreshes itself. Bridges are read live from NCDOT on every run. The reference data
is reloaded quarterly by scheduled jobs in the database — the schedule is in migration `0019`.
**Settings → Data** shows the vintage of each source, and a signed-in reviewer can ask for a
reload between quarters with **Reload from NCDOT now**.

**The page** only changes when the tool changes. Rebuild with `python3 src/build.py` and
re-upload `docs/index.html`.
