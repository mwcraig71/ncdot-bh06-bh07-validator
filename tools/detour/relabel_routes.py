"""Recompute the road-by-road steps of exported routes from their stored
measuring points and closed points, without re-running the measurement.

usage: relabel_routes.py <routes_dir> <worker> <nworkers>   (run from a run dir)

Used once, on 15 October 2026, after the first export numbered Valhalla's ramp
manoeuvres wrongly. Each route is re-asked between the same two points with the
same closure; its length must equal the stored one to within 0.001 mi or the
row is left unchanged and reported. Only the steps are replaced.
"""
import sys, os, json, glob
sys.path.insert(0, '.')
import routes                                   # also points the engine at the local graph

d, wk, nw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
files = sorted(glob.glob(os.path.join(d, 'routes_*.json')))[wk::nw]
for f in files:
    rows, bad = json.load(open(f)), 0
    for r in rows:
        try:
            o_mi, _, o_st = routes.directions(r['a'], r['b'])
            c_mi, _, c_st = routes.directions(r['a'], r['b'], r['block'])
        except Exception as ex:
            bad += 1; print(f"{r['brdg_nbr']} {r['mode']} {r['seq']}: no route ({str(ex)[:60]})", flush=True); continue
        if abs(o_mi - float(r['open_mi'])) > 0.001 or abs(c_mi - float(r['around_mi'])) > 0.001:
            bad += 1; print(f"{r['brdg_nbr']} {r['mode']} {r['seq']}: lengths moved", flush=True); continue
        r['open_steps'], r['closed_steps'] = o_st, c_st
    with open(f, 'w') as out: json.dump(rows, out, separators=(',', ':'))
    print(f'{os.path.basename(f)}: {len(rows)} rows, {bad} left unchanged', flush=True)
