# Publishing the validator to the web

The `web/` folder is the whole thing. One HTML file, no build step, no server code, no
database. Upload it and it works.

---

## The password system is gone from the web build — deliberately

The downloadable copy still has its two-password gate, because on a file someone emails around
it does a real job: it stops a casual double-click and it keeps *clear findings* with the people
who own that decision.

On a public URL that same gate is worse than nothing:

- Anyone can View Source, read the code, delete the gate, or just call the app's functions from
  the browser console.
- A SHA-256 of a short password sitting in publicly downloadable JavaScript is crackable offline
  with a wordlist in seconds. **If anyone had reused a real password there, publishing it would
  have leaked that password.**
- The "download a configured copy" flow can't work on a hosted page — you'd have to re-upload
  the file every time you changed a password.

So the web build has no gate, no password code and no crypto in it at all. Everyone who opens it
gets every action, including clearing findings.

**That is safe here, and it's worth understanding why.** There is no shared state. Every figure
the tool reads is already published by NCDOT and FHWA, and all review work — notes, statuses,
cleared findings — lives in memory and in a JSON file the visitor saves to their own machine.
One person clearing findings cannot affect anyone else's session, because there is nothing
between them. There is genuinely nothing to protect.

If that ever changes — a shared review database, several people working one county at once —
that needs a real backend with real accounts, and the gate should be enforced there, never in
the page.

---

## Where to put it

Anywhere that serves static files over HTTPS. In rough order of least effort:

| Host | Notes |
|---|---|
| **Cloudflare Pages** | Free. Drag the `web/` folder onto the dashboard and it's live in about a minute. Custom domain and HTTPS included. Reads `_headers`. |
| **Netlify** | Free, same drag-and-drop. Also reads `_headers`. |
| **GitHub Pages** | Free for a public repo. Commit `web/` and enable Pages. |
| **Your existing strinteg.com server** | Drop `index.html` at something like `/tools/bh06/`. Works on IIS, Apache, nginx or a WordPress host's static directory — it's just a file. |
| **Azure Static Web Apps** | Free tier. Worth it only if you later want Microsoft 365 sign-in. |

A suggested URL: `tools.strinteg.com/bh06` or `strinteg.com/tools/bh06`.

## Requirements

HTTPS, and nothing else. No Node, no PHP, no database, no environment variables.

The visitor's browser talks directly to three services:

| Host | For | If unreachable |
|---|---|---|
| `gis11.services.ncdot.gov` | bridges, road network, county boundaries | essential |
| `geo.dot.gov` | the FHWA HPMS submittal (BH06-3) | every other check still runs |
| `server.arcgisonline.com` | background map tiles | cosmetic — the tool draws county outlines instead |

**All three were tested and confirmed to allow cross-origin requests from any HTTPS origin,
including the POST preflight the heavier checks need.** Nothing needs proxying.

## After you publish

Open it and press **Diagnostics** in Settings. It probes each service from wherever it is now
and reports what's reachable — a two-second check that the deployment is sound.

---

## What visitors get

A tool that validates BH06 and BH07 for any NC bridge, route, county or the whole state against
FHWA's published rules, NCDOT's live LRS and FHWA's own HPMS submittal — running entirely in
their browser, with nothing uploaded anywhere.

Since every input is public data and the output is a QC finding, this doubles as a public
demonstration of the work. The page carries a description and social preview text for that
reason.

## Keeping it current

There's no data to refresh — it reads NCDOT live, so it follows their quarterly republishing on
its own. Re-upload `index.html` only when the tool itself changes.
