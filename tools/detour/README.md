# As-measured detour length — statewide pipeline

Measures, for every NCDOT bridge structure:

- **bypass** — the road *on* the bridge. The deck is blocked; the road beneath stays
  open, so a detour may drop down, pass under and come back up.
- **collapse** — each road *under* the bridge, only where NCDOT records a highway
  beneath. The ground under the span is blocked; the deck stays open.

Minimum distance only. Results load into `detour_measured` (migration 0042).
This is not B.H.17 — see `as-measured-detour-feasibility.md`.

## Re-running when the map updates

```bash
pip install pyvalhalla==3.9.1
# 1. a North Carolina extract from download.geofabrik.de (~430 MB)
valhalla_build_config --mjolnir-tile-dir ./tiles --mjolnir-tile-extract ./tiles.tar --mjolnir-concurrency 2 > valhalla.json
valhalla_build_tiles -c valhalla.json north-carolina-latest.osm.pbf     # ~3 min on 2 cores
# 2. the structures (pages on exceededTransferLimit, checks the total)
python3 pull_structures.py
# 3. the pass, one worker per core; resumable - a killed worker picks up where it stopped
VALHALLA_CONFIG=valhalla.json python3 runner.py 0 2 & VALHALLA_CONFIG=valhalla.json python3 runner.py 1 2
# 4. second chance at the deck's own ends for anchor-placement failures
python3 repair_all.py        # writes results_final.jsonl
python3 analyse.py
```

Set `VINTAGE` in `runner.py` to the extract's date.

## First run — 13 October 2026, OSM extract of 12 October

14,262 structures, ~18 minutes on two cores.

| road on the bridge | count | |
|---|---|---|
| measured | 12,372 | 86.7% |
| no detour (far side reachable only over this bridge) | 1,066 | 7.5% |
| bypass at the site | 639 | 4.5% |
| unmeasured, with reason | 185 | 1.3% |

Against NCDOT's coded value, read as miles (median measured additional travel ÷ code):

| code | n | median | within ±50% |
|---|---|---|---|
| 1 | 4,489 | 2.42 | 24% |
| 2 | 1,950 | 1.99 | 27% |
| 3–5 | 3,026 | 1.40 | 51% |
| 6–9 | 1,283 | 1.11 | 73% |
| 10–19 | 545 | 1.04 | 75% |
| 20–98 | 263 | 1.03 | 80% |

Closer to the code as miles than as kilometres on 95% of 11,005 structures.
