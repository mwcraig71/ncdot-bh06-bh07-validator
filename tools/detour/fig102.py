"""Detour length as FHWA SNBI Figure 102 draws it: from the turn points.

usage: fig102.py <routes_dir> <worker> <nworkers> <out_dir>

The statewide measurement (runner.py) put its two measuring points right at the
bridge ends. A driver there has to double back to the nearest turn-off, and
that doubling back was counted as detour. Figure 102 measures between the
points where traffic actually leaves the road and where it rejoins it:

    reported = detour route between the turn points
             - the normal route between the same two points

Turn-off points are where the closed route (stored in data/detour_routes)
leaves the road the bridge carries; turn-back-on points are where it rejoins
it. The first turn off and the last turn back on are tried first. If the route
leaves and rejoins more than once (it turns around, then exits later), each
later turn-off / earlier turn-back-on pair is tried too, and the pair with the
least extra travel is kept - provided the normal route between the two points
still crosses the bridge. A pair whose normal route misses the bridge is not
a detour for anyone using it.

The normal route between the turn points is routed. Where routing from a turn
point cannot be trusted (the point snaps onto the cross road, or a one-way
stretch), along_road() measures it along the road instead: the open route
plus the stretch driven back to each turn point.

Where neither works, the bridge-end figure is kept and says why:
  bridge_ends_local  a shorter way between the turn points skips the bridge,
                     so only traffic between them uses it (a loop road); for
                     that traffic the bridge-end figure is the detour
  bridge_ends        no turn points could be fixed on the route

Output: fig102_<worker>.jsonl, one line per stored route.
"""
import sys, os, json
sys.path.insert(0, '.')
import localengine  # noqa: F401  puts tools/ (detour_probe) on the path
import detour_probe as dp
from routes import step_name, simplify, encode, rp

STAY = {7, 8, 22}          # becomes, continue, stay straight: no turn made
M2MI = 1 / 1609.34

def route(A, B, block=None):
    body = {"locations": [{"lat": A[0], "lon": A[1]}, {"lat": B[0], "lon": B[1]}],
            "costing": "auto", "directions_options": {"units": "miles"}}
    if block: body["exclude_locations"] = [{"lat": p[0], "lon": p[1]} for p in block]
    j = dp.post('/route', body); leg = j['trip']['legs'][0]
    ms = [m for m in leg['maneuvers'] if m.get('type') not in (4, 5, 6)]
    return j['trip']['summary']['length'], dp.decode(leg['shape']), ms

def names(m): return set(m.get('street_names') or [])
def centre(block): return (sum(p[0] for p in block) / len(block), sum(p[1] for p in block) / len(block))
def crosses(shape, block, tol=30.0): return dp.dist_to_path(centre(block), shape) <= tol

def carried(oshape, oms, block):
    """Names of the road the bridge carries: the open route's manoeuvre at the block."""
    c = centre(block); bi = min(range(len(oshape)), key=lambda i: dp.hav(c, oshape[i]))
    om = [m for m in oms if m['begin_shape_index'] <= bi <= m['end_shape_index']] or oms[:1]
    return names(om[0])

def runs(ms, road):
    """[i, j] index ranges of manoeuvres driven on the carried road."""
    on = []
    for k, m in enumerate(ms):
        on.append(bool(names(m) & road) or (k > 0 and on[-1] and m['type'] in STAY))
    out = []; k = 0
    while k < len(on):
        if on[k]:
            j = k
            while j + 1 < len(on) and on[j + 1]: j += 1
            out.append((k, j)); k = j + 1
        else: k += 1
    return out

def steps_of(ms, lo=None, hi=None):
    """Road-by-road list for the manoeuvres starting in shape range [lo, hi)."""
    out = []
    for m in ms:
        b = m['begin_shape_index']
        if lo is not None and b < lo: continue
        if hi is not None and b >= hi: continue
        L = float(m.get('length') or 0)
        if L <= 0: continue
        n = step_name(m)
        if out and out[-1]['n'] == n: out[-1]['mi'] += L
        else: out.append({'n': n, 'mi': L})
    return out

def merge(*lists):
    out = []
    for lst in lists:
        for s in lst:
            if s['mi'] <= 0.0005: continue
            if out and out[-1]['n'] == s['n']: out[-1]['mi'] += s['mi']
            else: out.append(dict(s))
    for s in out: s['mi'] = round(s['mi'], 3)
    return out

def trim(steps, mi, front=True):
    """Drop `mi` miles from the front (or back) of a step list."""
    s = [dict(x) for x in (steps if front else steps[::-1])]
    while s and mi > 0:
        if s[0]['mi'] <= mi: mi -= s[0]['mi']; s.pop(0)
        else: s[0]['mi'] -= mi; mi = 0
    return s if front else s[::-1]

def nearest(path, p): return min(range(len(path)), key=lambda i: dp.hav(p, path[i]))

def near_open(p, oshape, tol=20.0):
    """On the open route strictly between its ends: reaching it from the anchor
    is progress toward the bridge, not doubling back."""
    return dp.dist_to_path(p, oshape) <= tol and dp.hav(p, oshape[0]) > tol and dp.hav(p, oshape[-1]) > tol

def pack(shape, ms, ia, ib, det, orig, opath, osteps, how, first):
    dst = merge(steps_of(ms, ia, ib))
    det = sum(s['mi'] for s in dst)       # Valhalla's own lengths, as around_mi uses
    return {'how': how, 'first': first, 'ja': rp(shape[ia]), 'jb': rp(shape[ib]),
            'detour_mi': round(det, 3), 'original_mi': round(orig, 3), 'extra_mi': round(max(0.0, det - orig), 3),
            'detour_path': encode(simplify(shape[ia:ib + 1])), 'original_path': encode(simplify(opath)),
            'detour_steps': dst, 'original_steps': merge(osteps)}

def turn_points(A, B, block, open_mi):
    L, shape, ms = route(A, B, block)
    _, oshape, oms = route(A, B)
    road = carried(oshape, oms, block)
    R = runs(ms, road); cum = dp.cum(shape)
    offs, ons = [], []
    if not R or R[0][0] != 0: offs.append(0)
    for (i, j) in R:
        if j + 1 < len(ms): offs.append(ms[j + 1]['begin_shape_index'])
        if i > 0: ons.append(ms[i]['begin_shape_index'])
    if not R or R[-1][1] != len(ms) - 1: ons.append(len(shape) - 1)
    best = None; missed_first = None
    for ia in offs:
        for ib in ons:
            if ib <= ia or dp.hav(shape[ia], shape[ib]) < 1: continue
            try: o, osh, oms2 = route(shape[ia], shape[ib])
            except Exception: continue
            first = ia == offs[0] and ib == ons[-1]
            det = (cum[ib] - cum[ia]) * M2MI
            if not crosses(osh, block):
                if first: missed_first = (o, cum[ia] * M2MI, (cum[-1] - cum[ib]) * M2MI)
                continue
            if det - o < -0.02: continue
            if best is None or det - o < best['extra_mi']:
                best = pack(shape, ms, ia, ib, det, o, osh, steps_of(oms2), 'turn_points', first)
    if best: return best
    b = along_road(A, B, block, open_mi, L, shape, ms, oshape, oms)
    if b: return b
    # kept at the bridge ends: is it a loop road (a shorter way skips the bridge)?
    if missed_first:
        o, dA, dB = missed_first; geo = open_mi + dA + dB
        if o < geo - max(0.05, 0.03 * geo): return {'how': 'bridge_ends_local'}
    return {'how': 'bridge_ends'}

def along_road(A, B, block, open_mi, L, shape, ms, oshape, oms):
    road = set().union(*[names(m) for m in oms]) | names(ms[0])
    on = lambda m: bool(names(m) & road) or (not names(m) and not road)
    k = 0; dA = 0.0
    while k < len(ms) and (k == 0 or ms[k]['type'] in STAY or on(ms[k])): dA += ms[k]['length']; k += 1
    if k >= len(ms): return None
    q = len(ms) - 1; dB = 0.0
    while q > k and on(ms[q]): dB += ms[q]['length']; q -= 1
    if q + 1 >= len(ms): return None
    ia = ms[k]['begin_shape_index']; ib = ms[q + 1]['begin_shape_index']
    JA, JB = shape[ia], shape[ib]
    bA = dA > 0.01 and not near_open(JA, oshape); bB = dB > 0.01 and not near_open(JB, oshape)
    if not (bA or bB): return None          # no doubling back: the bridge-end figure already is Figure 102
    orig = open_mi + (dA if bA else -dA) + (dB if bB else -dB); det = L - dA - dB
    if det - orig < 0: return None
    try: o, osh, _ = route(JA, JB)
    except Exception: o = None
    if o is not None and o < orig - max(0.05, 0.03 * orig) and not crosses(osh, block): return None
    # the original route, drawn and listed: back along the road to A, the open route, on from B
    ost = steps_of(oms)
    head = steps_of(ms, None, ia)[::-1] if bA else []
    tail = steps_of(ms, ib, None)[::-1] if bB else []
    if not bA: ost = trim(ost, dA, True)
    if not bB: ost = trim(ost, dB, False)
    p = list(oshape)
    if not bA: p = p[nearest(p, JA):]
    if not bB: p = p[:nearest(p, JB) + 1]
    path = (shape[ia::-1] if bA else []) + p + (shape[:ib - 1:-1] if bB else [])
    return pack(shape, ms, ia, ib, det, orig, path, head + ost + tail, 'turn_points_along_road', True)

def _main():
    import glob, time
    rdir, wk, nw, odir = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    rows = []
    for f in sorted(glob.glob(os.path.join(rdir, '*.json'))): rows += json.load(open(f))
    rows.sort(key=lambda r: (r['brdg_nbr'], r['mode'], r['seq'])); rows = rows[wk::nw]
    path = os.path.join(odir, f'fig102_{wk}.jsonl'); done = set()
    if os.path.exists(path):
        for ln in open(path):
            j = json.loads(ln); done.add((j['brdg_nbr'], j['mode'], j['seq']))
    t0 = time.time(); n = 0
    with open(path, 'a') as f:
        for r in rows:
            key = (r['brdg_nbr'], r['mode'], r['seq'])
            if key in done: continue
            rec = {'brdg_nbr': key[0], 'mode': key[1], 'seq': key[2]}
            try:
                rec.update(turn_points(r['a'], r['b'], r['block'], float(r['open_mi'])))
            except Exception as ex:
                rec.update(how='bridge_ends', error=str(ex)[:200])
            f.write(json.dumps(rec) + '\n'); f.flush(); n += 1
            if n % 1000 == 0:
                print(f'{time.strftime("%H:%M:%S")} {n + len(done)}/{len(rows)} {n / (time.time() - t0):.1f}/s', flush=True)
    print('DONE', flush=True)

if __name__ == '__main__':
    _main()
