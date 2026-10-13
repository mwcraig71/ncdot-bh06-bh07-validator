"""Merge both workers' output and give every bypass row that failed on anchor
placement a second chance at the deck's own ends. Writes results_final.jsonl."""
import sys, json, glob, collections; sys.path.insert(0, '.')
import repair, runner as rn
S = {str(s['StructureNumber']).strip(): s for s in json.load(open('structures.json'))}
RETRY = {'the open path does not use the blocked span', 'road could not be traced', 'no usable anchors'}
by = {}
for f in sorted(glob.glob('out_[01].jsonl')):
    for ln in open(f):
        rows = json.loads(ln); by[rows[0]['brdg_nbr']] = rows
stats = collections.Counter()
for bn, rows in by.items():
    b = rows[0]
    retry = b['verdict'] == 'unmeasured' and (b['reason'] in RETRY or b['reason'].startswith('open path ')
                                             or b['reason'].startswith('blocked path shorter'))
    if not retry: continue
    try:
        r = repair.ends_fallback(S[bn])
    except Exception as ex:
        r = {'verdict': 'UNMEASURED', 'why': 'error in deck-ends retry: ' + str(ex)[:150]}
    if r is None: stats['retry: no deck'] += 1; continue
    new = rn.row(bn, 'bypass', 0, r, road=b['road'], heading=b['heading'],
                 width_assumed=b['width_assumed'], deck_inferred=r.get('_inferred', b['deck_inferred']))
    if new['verdict'] == 'unmeasured':
        new['reason'] = f"{b['reason']}; deck-ends retry: {new['reason']}"
    rows[0] = new
    stats['retry -> ' + new['verdict']] += 1
with open('results_final.jsonl', 'w') as f:
    for bn in sorted(by): f.write(json.dumps(by[bn]) + '\n')
print(json.dumps({'structures': len(by), **stats}, indent=1))
