# Pushing this to GitHub

I couldn't do it from the Cowork session. The GitHub token there is yours (`mwcraig71`) but the
session is bound to repositories that were connected when it started, and none were — creating
one returns *"sessions are bound to their configured repositories"* and every repo probe returns
403. So the repository is fully prepared here instead, committed and ready.

Two ways to finish it.

---

## Option A — from your machine (about a minute)

If you have the GitHub CLI:

```bash
cd ncdot-bh06-bh07-validator
gh repo create ncdot-bh06-bh07-validator --public --source=. --remote=origin --push
```

Without the CLI: create an empty repo at <https://github.com/new> named
`ncdot-bh06-bh07-validator` — **no README, no .gitignore, no licence**, since this folder
already has them — then:

```bash
cd ncdot-bh06-bh07-validator
git remote add origin https://github.com/mwcraig71/ncdot-bh06-bh07-validator.git
git branch -M main
git push -u origin main
```

## Option B — connect the repo to Cowork and I'll push it

Create the empty repo on GitHub, connect it to a Cowork session, and I can commit and push
directly from then on, including future changes.

---

## Turning on the website

Once pushed:

**Settings → Pages → Source: Deploy from a branch → Branch: `main`, folder: `/docs` → Save.**

Live in a minute or two at:

```
https://mwcraig71.github.io/ncdot-bh06-bh07-validator/
```

Update the link at the top of `README.md` once you have it.

For a Strinteg address instead, add a `CNAME` file in `docs/` containing e.g.
`tools.strinteg.com`, then point that hostname at GitHub Pages with a CNAME DNS record. HTTPS is
issued automatically.

## After it's live

Open it and press **Diagnostics** in Settings. It probes all three data services from the new
origin and reports what's reachable — a two-second confirmation that the deployment is sound.

---

## Two decisions still open

**Licence.** There is deliberately no `LICENSE` file. Without one the default is
*all rights reserved* — anyone can read the code, nobody may reuse it. That's usually the right
default for a company. If you'd rather people could reuse it (MIT is the usual choice for a tool
like this), say so and I'll add it.

**Repository name.** `ncdot-bh06-bh07-validator` is descriptive but narrow. If Strinteg is
likely to publish more of these, `strinteg-bridge-tools` with this as a subfolder may age better.
Worth deciding before the URL is in circulation.
