"""Second chance for bypass rows that failed 'the open path does not use the
blocked span'. Anchor at the deck's own ends instead of tracing the road.
If the two sides cannot reach each other with the deck closed, while the open
route does cross it, the far side is reachable only over this bridge: that is
NO DETOUR, not UNMEASURED."""
import sys, json; sys.path.insert(0, '.')
import localengine as le, detour_probe as dp, runner as rn
le.use_local()

def ends_fallback(s):
    lat, lon = s['_lat'], s['_lon']
    L = float(s['StructureLength'] or 0) or 50.0
    W = float(s['BridgeDeckWidth'] or 0) or rn.W_DEFAULT_FT
    mine, ground, poly = dp.deck_and_obstruction(lat, lon, L, W)
    inferred = False
    if not mine:
        e = rn.infer_deck(lat, lon, s)
        if e is None: return None
        mine, inferred = [e], True
    block = [dp.corr(e) for e in mine]
    sh = dp.edge_shape_dir(mine[0])
    if len(sh) < 2: return None
    last = None
    for step in (15, 40, 80, 150):
        A, B = dp.past_ends(sh, step)
        r, why = dp.measure(A, B, block)
        if r:
            r['probe_mi'] = round(step / 1609.34, 2); r['_inferred'] = inferred; r['_how'] = 'deck ends'
            return r
        if why == 'blocked':
            # the open route crossed the span (measure checked that before blocking) and
            # nothing else connects the two sides
            return {'verdict': 'NO DETOUR', '_inferred': inferred, '_how': 'deck ends',
                    'why': 'the far side is reachable only over this bridge (dead end)'}
        last = why
    return {'verdict': 'UNMEASURED', '_inferred': inferred, 'why': last or 'no usable anchors at the deck ends'}
