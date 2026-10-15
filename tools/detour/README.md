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
python3 pull_structures.py          # layer 0: bridges
python3 pull_layers.py 1 2          # layers 1 and 2: pipes and culverts (run in a separate directory)
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

## Culverts and pipes — same day, same graph

The first run took NCDOT's *Bridge Structures* layer only. The tool lists 23,022
structures, and 5,414 of the ones it missed are culverts (3,389) and pipes (2,025),
which carry roads and get a B.H.17 like any bridge. The rest, railroad bridges,
walkways and signs, carry no road. A live check in Burke County found every
bridge measured and 55 culverts and pipes not, so they were added:

| | pipes | culverts |
|---|---|---|
| measured | 1,847 (91.2%) | 3,101 (91.5%) |
| no detour | 143 | 174 |
| bypass at the site | 24 | 89 |
| unmeasured | 11 | 25 |

Culverts are rarely tagged in the map, so 5,019 of the 5,414 decks were inferred
from the nearest road. That is the case the inference was built for, and it
holds: from code 10 upward the median measured-to-coded ratio is **1.00** across
229 of them.

## Statewide, all three types — 19,676 structures

| road on the bridge | count |
|---|---|
| measured | 17,320 |
| no detour | 1,383 |
| bypass at the site | 752 |
| unmeasured, with reason | 221 (1.1%) |

Units: closer to the code as miles on 89% of 15,385 structures (95% for bridges
alone), median ratio 1.03 from code 10 up. Code 1 sits on 7,132 structures (36%)
at a median 2.3x the code. Code 99 matches a measured dead end on 1,005 of 1,579
(64%).

## The route behind each detour (15 October 2026)

The first pass kept only distances. `routes.py` repeats each published
measurement on the same graph (the same anchors and the same blocked edges,
reached through the same code) and keeps what it was measured on: the two
measuring points, the closed points, the open and the closed route as encoded
polylines (precision 6, simplified to about 2 m), and the roads each route
uses, in order, with the distance on each. A route is kept only if it
reproduces the published distances to within 0.01 mi.

```bash
cd <run dir>            # the bridges' run, then the culverts' and pipes'
python3 routes.py . 0 2 & python3 routes.py . 1 2 &       # writes routes_<w>.jsonl
python3 export_routes.py <repo>/data/detour_routes <bridges run dir> <culverts run dir>
```

The tool reads them from table `detour_route` (migration 0046), one bridge at a
time when the bridge is opened. They load without the ingest token: the files
are pushed to the repository and the database fetches each one from GitHub,
as the database owner, in the SQL editor or through the Supabase connector:

```sql
-- 1. ask for the file; note the request id it returns
select net.http_get(url := 'https://raw.githubusercontent.com/mwcraig71/ncdot-bh06-bh07-validator/main/data/detour_routes/routes_01.json',
                    timeout_milliseconds := 60000);
-- 2. once net._http_response has status 200 for that id, load it
insert into detour_route (brdg_nbr, mode, seq, a, b, block, open_mi, around_mi, open_path,
                          closed_path, open_steps, closed_steps, graph_vintage, run_id)
select x.brdg_nbr, x.mode, x.seq, x.a, x.b, x.block, x.open_mi, x.around_mi, x.open_path,
       x.closed_path, x.open_steps, x.closed_steps, x.graph_vintage, x.run_id
  from jsonb_to_recordset((select content::jsonb from net._http_response where id = <request id>))
       as x(brdg_nbr text, mode text, seq smallint, a jsonb, b jsonb, block jsonb, open_mi numeric,
            around_mi numeric, open_path text, closed_path text, open_steps jsonb,
            closed_steps jsonb, graph_vintage text, run_id bigint)
on conflict (brdg_nbr, mode, seq) do update
  set a = excluded.a, b = excluded.b, block = excluded.block, open_mi = excluded.open_mi,
      around_mi = excluded.around_mi, open_path = excluded.open_path,
      closed_path = excluded.closed_path, open_steps = excluded.open_steps,
      closed_steps = excluded.closed_steps, graph_vintage = excluded.graph_vintage,
      run_id = excluded.run_id, loaded_at = now();
```

On 15 October the first export numbered Valhalla's ramp manoeuvres wrongly; `relabel_routes.py`
re-asked each route between its stored points with the same closure and replaced only the road
lists. 24,502 of 24,512 matched to 0.001 mi and were relabelled; the other 10 (stored points are
rounded to 6 decimals, which moved the snap) kept their verified routes, with mislabelled
"(ramp)" steps renamed "(unnamed road)".

Migration 0047 then closes `ingest_detour_route` and the table's write grants,
since nothing writes to it until the next run.

## From the turn points: FHWA SNBI Figure 102 (15 October 2026)

The statewide run measured between two points at the bridge ends. A driver there has to
double back to the nearest turn-off, and that doubling back was counted as detour. Figure 102
measures between the point where traffic turns off the road and the point where it turns back
on: the detour between them, less the normal route between the same two points. In the
figure's example, 2 + 6 + 2 = 10 mi against 6 mi on the original road is a 4-mile detour.

`fig102.py` finds the turn points on each stored closed route, from Valhalla's own manoeuvres:
A is where it first leaves the road the bridge carries (named at the closed point on the open
route), B where it last comes back on. If the route leaves and rejoins more than once (it turns
around, then exits further on), each later turn-off / earlier turn-back-on pair is tried too and
the least extra kept, provided the normal route between the pair still crosses the bridge. The
normal route is routed between the two points; where routing from a turn point cannot be trusted
(it snaps onto the cross road, or a one-way stretch), `along_road()` measures it along the road
instead.

Where neither works, the bridge-end figure is kept and says why:

| Basis | Detours | Share |
|---|---|---|
| `turn_points` | 19,795 | 80.8% |
| `turn_points_along_road` | 1,164 | 4.7% |
| `bridge_ends_local`: a shorter way between the turn points skips the bridge (a loop road), so only local traffic uses it | 1,962 | 8.0% |
| `bridge_ends`: no turn points fixed; often the route never doubles back, so the figure already is Figure 102 | 1,591 | 6.5% |

Median detour, from the bridge ends → from the turn points:

- Road on the bridge (18,072): 3.97 → 1.77 mi.
- Road beneath (6,440): 1.56 → 0.99 mi.

Against NCDOT's code, road on the bridge, read as miles:

| code | n | median ÷ code (turn points) | within ±50% | median ÷ code (bridge ends) |
|---|---|---|---|---|
| 1 | 6,426 | 1.09 | 42% | 2.34 |
| 2 | 2,915 | 0.94 | 61% | 1.90 |
| 3–5 | 4,253 | 0.73 | 59% | 1.34 |
| 6–9 | 1,680 | 0.54 | 51% | 1.07 |
| 10–19 | 710 | 0.52 | 50% | 1.03 |
| 20–98 | 327 | 0.50 | 48% | 1.03 |

Short codes now agree; long codes match the bridge-end measurement, and run about twice the
turn-point one. 140004 (US 17, code 27) is typical. From the bridge ends it is 25.8 mi, because a
driver doubles back 11 mi along US 17 before turning off. From the turn points it is 17.7 mi round
by NC 343 against 12.5 mi on US 17, so 5.2 mi. NCDOT appears to code long detours from the bridge.

The figures were spot-checked on 290 bridges against bridges the owner knows, including 590141
(1.03; NCDOT 1) and 210049 (loop road, kept at 7.1; NCDOT 7).

Run, then export:

```
cd <run dir>; for w in 0 1; do python3 fig102.py <repo>/data/detour_routes $w 2 <out> & done; wait
python3 tools/detour/export_turns.py data/detour_turns <out>
```

Loading (migration 0048 adds the columns), per file NN, as the database owner:

```sql
select net.http_get(url := 'https://raw.githubusercontent.com/mwcraig71/ncdot-bh06-bh07-validator/<commit>/data/detour_turns/turns_NN.json',
                    timeout_milliseconds := 60000);
-- once net._http_response has status 200 for that id:
with x as (
  select * from jsonb_to_recordset((select content::jsonb from net._http_response where id = <request id>))
    as x(brdg_nbr text, mode text, seq smallint, how text, ja jsonb, jb jsonb, detour_mi numeric,
         original_mi numeric, detour_path text, original_path text, detour_steps jsonb, original_steps jsonb)),
r as (
  update detour_route d
     set ja = x.ja, jb = x.jb, turn_detour_mi = x.detour_mi, turn_original_mi = x.original_mi,
         turn_detour_path = x.detour_path, turn_original_path = x.original_path,
         turn_detour_steps = x.detour_steps, turn_original_steps = x.original_steps
    from x where d.brdg_nbr = x.brdg_nbr and d.mode = x.mode and d.seq = x.seq
  returning 1)
update detour_measured m
   set report_basis = x.how,
       report_mi = case when x.how like 'turn_points%' then greatest(0, x.detour_mi - x.original_mi)
                        else m.additional_mi end
  from x where m.brdg_nbr = x.brdg_nbr and m.mode = x.mode and m.seq = x.seq;
```

`report_mi` is computed from the two stored three-decimal figures, so the subtraction the panel
shows is exact.
