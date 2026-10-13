"""Statewide as-measured detour pass on the local North Carolina graph.

usage: runner.py <worker> <nworkers> [limit]
Each worker takes every nth structure, appends one JSON line per structure to
out_<worker>.jsonl, and skips structures already in that file - so a killed
worker resumes where it stopped.
"""
import sys, os, json, time, traceback
sys.path.insert(0, '.')
import localengine as le, detour_probe as dp
le.use_local()

VINTAGE = 'OSM north-carolina-261012'
RUN_ID  = 20261013
W_DEFAULT_FT = 30.0
BYPASS_PROBES   = (0.05, 0.1, 0.25, 0.5, 1, 2, 4)
COLLAPSE_PROBES = (0.1, 0.25, 0.5, 1, 2, 4, 8)
VERDICT = {'ok':'ok', 'bypass at site':'bypass_at_site',
           'NO DETOUR':'no_detour', 'UNMEASURED':'unmeasured'}

def row(bn, mode, seq, r, road=None, heading=None, width_assumed=False, deck_inferred=False):
    v = VERDICT.get(r.get('verdict'), 'unmeasured')
    ok = v in ('ok', 'bypass_at_site')
    rnd = lambda x: None if x is None else round(float(x), 3)
    return {'brdg_nbr': bn, 'mode': mode, 'seq': seq, 'road': road,
            'heading': None if heading is None else int(round(heading)) % 360,
            'verdict': v,
            'around_mi':     rnd(r.get('around')) if ok else None,
            'direct_mi':     rnd(r.get('direct')) if ok else None,
            'additional_mi': rnd(r.get('extra'))  if ok else None,
            'probe_mi':      r.get('probe_mi') if ok else None,
            'reason':        None if ok else (r.get('why') or 'no reason recorded'),
            'width_assumed': width_assumed, 'deck_inferred': deck_inferred, 'graph_vintage': VINTAGE, 'run_id': RUN_ID}

def road_name(e):
    n = e['edge_info'].get('names') or []
    return ' / '.join(n) if n else '(ramp / unnamed)'

HIGHWAY_BENEATH = lambda s: 'highway' in str(s.get('ServiceUnder') or '').lower()

def infer_deck(lat, lon, s):
    """The map has the road but does not tag the bridge on it. Only safe where
    NCDOT records no highway beneath - otherwise the nearest road may be the
    one underneath (780170: closed SR1360 over US 220, nearest road US 220)."""
    if HIGHWAY_BENEATH(s): return None
    es = [e for e in dp.edges_at(lat, lon, 30) if not e['edge'].get('bridge') and e['distance'] <= 15]
    return min(es, key=lambda e: e['distance']) if es else None

def measure_structure(s):
    bn  = str(s['StructureNumber']).strip()
    lat, lon = s['_lat'], s['_lon']
    L   = float(s['StructureLength'] or 0) or 50.0
    W   = float(s['BridgeDeckWidth'] or 0)
    assumed = W <= 0
    if assumed: W = W_DEFAULT_FT
    closed = 'CLOSED' in str(s.get('FacilityCarried') or '').upper()
    mine, ground, poly = dp.deck_and_obstruction(lat, lon, L, W)
    inferred = False
    if not mine:
        e = infer_deck(lat, lon, s)
        if e is not None:
            mine, inferred = [e], True
    if not mine:
        why = 'carried road closed - no deck for this structure in the road graph' if closed \
              else 'no deck for this structure in the road graph'
        r = {'verdict': 'UNMEASURED', 'why': why}
        return [row(bn, 'bypass', 0, r, width_assumed=assumed),
                row(bn, 'collapse', 0, r, width_assumed=assumed)]
    kw = dict(width_assumed=assumed, deck_inferred=inferred)
    out = [row(bn, 'bypass', 0,
               dp.detour_for2(mine[0], [dp.corr(e) for e in mine], lat, lon, BYPASS_PROBES),
               road=road_name(mine[0]), heading=mine[0]['heading'], **kw)]
    # What passes beneath is NCDOT's call; the map only measures it.
    if not HIGHWAY_BENEATH(s):
        out.append({**row(bn, 'collapse', 0, {'verdict': 'UNMEASURED'}, **kw),
                    'verdict': 'none_beneath',
                    'reason': f"NCDOT records no highway beneath (service under: {s.get('ServiceUnder')})"})
        return out
    unders = dp.split_under(mine, ground) if not inferred else []
    if not unders:
        out.append(row(bn, 'collapse', 0, {'verdict': 'UNMEASURED',
                   'why': 'NCDOT records a highway beneath but none was found under the span in the road graph'}, **kw))
        return out
    blk = [dp.corr(e) for e in unders]
    reps, seen = [], set()
    for e in sorted(unders, key=lambda x: x['distance']):
        k = (str(sorted(dp.names_of(e))), round(e['heading'] / 30))
        if k not in seen: seen.add(k); reps.append(e)
    for i, u in enumerate(reps):
        out.append(row(bn, 'collapse', i, dp.detour_for2(u, blk, lat, lon, COLLAPSE_PROBES),
                       road=road_name(u), heading=u['heading'], **kw))
    return out

def main():
    wk, nw = int(sys.argv[1]), int(sys.argv[2])
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else None
    S = json.load(open('structures.json'))
    S.sort(key=lambda s: s['ObjectID'])
    mine = S[wk::nw][:limit]
    path = f'out_{wk}.jsonl'
    done = set()
    if os.path.exists(path):
        for ln in open(path):
            try: done.add(json.loads(ln)[0]['brdg_nbr'])
            except Exception: pass
    prog = open(f'progress_{wk}.txt', 'a'); t0 = time.time(); n = 0
    with open(path, 'a') as f:
        for s in mine:
            bn = str(s['StructureNumber']).strip()
            if bn in done: continue
            try:
                rows = measure_structure(s)
            except Exception as ex:
                why = {'verdict': 'UNMEASURED', 'why': 'error: ' + str(ex)[:200]}
                rows = [row(bn, 'bypass', 0, why), row(bn, 'collapse', 0, why)]
            finally:
                dp._trace.__defaults__[-1].clear()        # per-structure trace cache, or memory grows
            f.write(json.dumps(rows) + '\n'); f.flush(); n += 1
            if n % 50 == 0:
                prog.write(f'{time.strftime("%H:%M:%S")} worker {wk}: {n + len(done)}/{len(mine)} '
                           f'({n / (time.time() - t0):.2f}/s)\n'); prog.flush()
    prog.write(f'{time.strftime("%H:%M:%S")} worker {wk}: DONE {n + len(done)}/{len(mine)}\n'); prog.close()

if __name__ == '__main__':
    main()
