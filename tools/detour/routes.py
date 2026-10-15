"""Keep the route behind every measured detour, so it can be drawn and checked.

usage: routes.py <run_dir> <worker> <nworkers>

The statewide pass (runner.py + repair_all.py) kept only distances. This pass
repeats the same measurement for each structure - same graph, same anchors,
same blocked edges, so the same answer - and this time keeps, for the open and
the closed route between the two measuring points:

  - the path, as an encoded polyline (precision 6, simplified to ~2 m), and
  - the roads it uses in order, with the distance on each.

Every captured measurement is compared with the distance already published in
results_final.jsonl. A route is only kept if it reproduces that distance to
within 0.01 mi; anything else is reported, never silently replaced.

Output: routes_<worker>.jsonl, one line per measured detour.
"""
import sys, os, json, time
sys.path.insert(0, '.')
import localengine as le, detour_probe as dp, runner as rn, repair
le.use_local()

# --- capture the anchors and blocked points of each successful measurement ---
_real_measure = dp.measure
CAPTURED = []
def _capturing_measure(A, B, block, *a, **k):
    r, why = _real_measure(A, B, block, *a, **k)
    if r: CAPTURED.append((A, B, list(block)))
    return r, why
dp.measure = _capturing_measure

RAMP_TYPES = {17, 18, 19, 20, 21}      # Valhalla: ramp straight/right/left, exit right/left

def step_name(m):
    """What a driver would read: the road's names, or for a ramp with no name
    of its own, what its sign says - exit number, where it goes, toward what."""
    names = m.get('street_names') or []
    if names: return ' / '.join(names)
    if m.get('type') in RAMP_TYPES:
        sg = m.get('sign') or {}
        txt = lambda k: [e.get('text') for e in sg.get(k) or [] if e.get('text')]
        num, branch, toward = txt('exit_number_elements'), txt('exit_branch_elements'), txt('exit_toward_elements')
        label = ('exit ' + num[0] + ' ramp' if num else 'ramp')
        if branch: label += ' to ' + ' / '.join(branch[:2])
        elif toward: label += ' toward ' + ' / '.join(toward[:2])
        return '(' + label + ')'
    return '(unnamed road)'

def directions(A, B, block=None):
    body = {"locations": [{"lat": A[0], "lon": A[1]}, {"lat": B[0], "lon": B[1]}],
            "costing": "auto", "directions_options": {"units": "miles"}}
    if block: body["exclude_locations"] = [{"lat": p[0], "lon": p[1]} for p in block]
    j = dp.post("/route", body)
    leg = j['trip']['legs'][0]
    steps = []
    for m in leg['maneuvers']:
        L = float(m.get('length') or 0)
        if L <= 0: continue
        name = step_name(m)
        if steps and steps[-1]['n'] == name: steps[-1]['mi'] += L
        else: steps.append({'n': name, 'mi': L})
    for s in steps: s['mi'] = round(s['mi'], 3)
    return j['trip']['summary']['length'], dp.decode(leg['shape']), steps

def simplify(pts, tol_m=2.0):
    """Douglas-Peucker on a local flat projection; keeps the ends."""
    if len(pts) < 3: return pts
    import math
    lat0 = math.radians(pts[0][0]); kx = 111320 * math.cos(lat0); ky = 110540
    P = [((p[1]) * kx, (p[0]) * ky) for p in pts]
    keep = [False] * len(P); keep[0] = keep[-1] = True
    stack = [(0, len(P) - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = P[i]; bx, by = P[j]; dx, dy = bx - ax, by - ay; L2 = dx * dx + dy * dy
        best, bi = -1, -1
        for k in range(i + 1, j):
            px, py = P[k]
            t = 0 if L2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
            d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best: best, bi = d, k
        if best > tol_m:
            keep[bi] = True; stack += [(i, bi), (bi, j)]
    return [p for p, k in zip(pts, keep) if k]

def encode(pts, prec=1e6):
    out = []; plat = plon = 0
    for lat, lon in pts:
        ilat, ilon = int(round(lat * prec)), int(round(lon * prec))
        for v in (ilat - plat, ilon - plon):
            v = ~(v << 1) if v < 0 else (v << 1)
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1f)) + 63)); v >>= 5
            out.append(chr(v + 63))
        plat, plon = ilat, ilon
    return ''.join(out)

def rp(p): return [round(p[0], 6), round(p[1], 6)]

def capture_structure(s, stored_rows):
    """Re-run the measurement exactly as the statewide pass did, collecting the
    anchors of each successful measurement in row order."""
    CAPTURED.clear()
    rows = rn.measure_structure(s)
    caps = list(CAPTURED)
    # the deck-ends retry, for the bypass rows repair_all.py re-measured
    b = rows[0]; sb = stored_rows[0]
    if b['verdict'] == 'unmeasured' and sb['verdict'] in ('ok', 'bypass_at_site'):
        CAPTURED.clear()
        r = repair.ends_fallback(s)
        if r and CAPTURED:
            rows[0] = rn.row(sb['brdg_nbr'], 'bypass', 0, r, road=b['road'], heading=b['heading'])
            caps = [CAPTURED[-1]] + caps
    return rows, caps

def main():
    run_dir, wk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    os.chdir(run_dir)
    S = {str(s['StructureNumber']).strip(): s for s in json.load(open('structures.json'))}
    stored = {}
    for ln in open('results_final.jsonl'):
        rows = json.loads(ln); stored[rows[0]['brdg_nbr']] = rows
    todo = sorted(bn for bn, rows in stored.items()
                  if any(r['verdict'] in ('ok', 'bypass_at_site') for r in rows))[wk::nw]
    path = f'routes_{wk}.jsonl'
    done = set()
    if os.path.exists(path):
        for ln in open(path):
            try: done.add(json.loads(ln)['brdg_nbr'])
            except Exception: pass
    t0 = time.time(); n = 0
    with open(path, 'a') as f, open(f'routes_{wk}.log', 'a') as log:
        for bn in todo:
            if bn in done: continue
            try:
                rows, caps = capture_structure(S[bn], stored[bn])
                okrows = [r for r in rows if r['verdict'] in ('ok', 'bypass_at_site')]
                st = {(r['mode'], r['seq']): r for r in stored[bn]}
                for r, (A, B, block) in zip(okrows, caps):
                    want = st.get((r['mode'], r['seq']))
                    rec = {'brdg_nbr': bn, 'mode': r['mode'], 'seq': r['seq']}
                    if not want or want['verdict'] not in ('ok', 'bypass_at_site'):
                        rec['status'] = 'not in published run'; f.write(json.dumps(rec) + '\n'); continue
                    open_mi, open_pts, open_steps = directions(A, B)
                    clos_mi, clos_pts, clos_steps = directions(A, B, block)
                    d_open = abs(open_mi - want['direct_mi']); d_clos = abs(clos_mi - want['around_mi'])
                    rec.update(status='ok' if max(d_open, d_clos) <= 0.01 else 'distance differs',
                               open_mi=round(open_mi, 3), around_mi=round(clos_mi, 3),
                               want_open=want['direct_mi'], want_around=want['around_mi'],
                               a=rp(A), b=rp(B), block=[rp(p) for p in block],
                               open_path=encode(simplify(open_pts)), closed_path=encode(simplify(clos_pts)),
                               open_steps=open_steps, closed_steps=clos_steps)
                    f.write(json.dumps(rec) + '\n')
                if len(caps) != len(okrows):
                    log.write(f'{bn}: {len(caps)} captures for {len(okrows)} measured rows\n')
            except Exception as ex:
                f.write(json.dumps({'brdg_nbr': bn, 'status': 'error: ' + str(ex)[:200]}) + '\n')
            finally:
                dp._trace.__defaults__[-1].clear()
            f.flush(); n += 1
            if n % 200 == 0:
                log.write(f'{time.strftime("%H:%M:%S")} {n + len(done)}/{len(todo)} ({n / (time.time() - t0):.2f}/s)\n'); log.flush()
        log.write(f'{time.strftime("%H:%M:%S")} DONE {n + len(done)}/{len(todo)}\n')

if __name__ == '__main__':
    main()
