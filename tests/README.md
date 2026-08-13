# Tests

`cache.test.js` is the reference-data cache suite. It mocks every NCDOT and FHWA
endpoint, counts outbound requests, and asserts that widening or narrowing the
scope does not re-pull anything already in memory. It also pins the structures
service's 1,000-row page cap — the one place the app must not use the 2,000 that
works everywhere else.

```bash
npm install playwright leaflet
node tests/cache.test.js dist/NCDOT_BH06_BH07_Validator.html
node tests/cache.test.js docs/index.html
```

Eleven assertions; all should pass on all three builds.

`basemap.test.js` blocks tile hosts one at a time and asserts the map finds another
one — Esri → Esri mirror → USGS → CARTO → NCDOT-rendered → county outlines. It also
checks the Web Mercator envelope the NCDOT export layer builds for each tile, and
that a host outside the automatic chain can still be chosen by hand.

```bash
node tests/basemap.test.js dist/NCDOT_BH06_BH07_Validator.html
```

`corrections.test.js` proves a reviewer's corrected BH06/BH07 is actually validated:
that a wrong correction fails, a right one clears the finding it was meant to fix,
withdrawing one restores the published verdict exactly, corrections feed the
duplicate pre-pass, a changed value invalidates the cached Locate offset, and both
v1 and v2 review files round-trip. It also pins CSV column alignment — the header
declared `OFFSET_FT` and the rows never emitted it, which shifted every later column
by one.

```bash
node tests/corrections.test.js dist/NCDOT_BH06_BH07_Validator.html
```

All three suites mock every endpoint, so none needs network access to NCDOT, FHWA or
any tile host.
