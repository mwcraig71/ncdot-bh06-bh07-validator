"""Write the Figure 102 turn-point results (fig102.py) as JSON files for the
repository, which the database loads by fetching them from GitHub, as the
routes were (see export_routes.py and README.md).

usage: export_turns.py <out_dir> <fig102_dir>

One row per stored route. Files hold 2,000 rows each, sorted by structure.
Rows kept at the bridge ends carry only their key and `how`.
"""
import sys, os, json, glob, collections

KEYS = ('ja', 'jb', 'detour_mi', 'original_mi', 'extra_mi', 'detour_path',
        'original_path', 'detour_steps', 'original_steps')

out_dir, src = sys.argv[1], sys.argv[2]
rows, stats = {}, collections.Counter()
for f in sorted(glob.glob(os.path.join(src, 'fig102_*.jsonl'))):
    for ln in open(f):
        r = json.loads(ln); stats[r['how']] += 1
        rec = {'brdg_nbr': r['brdg_nbr'], 'mode': r['mode'], 'seq': r['seq'], 'how': r['how']}
        if r['how'].startswith('turn_points'): rec.update({k: r[k] for k in KEYS})
        rows[(r['brdg_nbr'], r['mode'], r['seq'])] = rec
os.makedirs(out_dir, exist_ok=True)
for old in glob.glob(os.path.join(out_dir, 'turns_*.json')): os.remove(old)
ordered = [rows[k] for k in sorted(rows)]
n = 0
for i in range(0, len(ordered), 2000):
    with open(os.path.join(out_dir, f'turns_{i // 2000 + 1:02d}.json'), 'w') as f:
        json.dump(ordered[i:i + 2000], f, separators=(',', ':'))
    n += 1
print(f'{len(ordered)} rows in {n} files;', dict(stats))
