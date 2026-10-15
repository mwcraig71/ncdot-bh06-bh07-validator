"""Write the captured routes as JSON files for the repository, which the
database then loads by fetching them from GitHub - no load token leaves it.

usage: export_routes.py <out_dir> <run_dir> [<run_dir> ...]

Only routes whose status is 'ok' (they reproduced the published distances to
within 0.01 mi) are written. Files hold 2,000 rows each, sorted by structure,
so a re-run changes only the files whose structures changed.

Loading, as the database owner (SQL editor or the Supabase MCP), per file N:
  select net.http_get(url := 'https://raw.githubusercontent.com/mwcraig71/'
         'ncdot-bh06-bh07-validator/main/data/detour_routes/routes_NN.json',
         timeout_milliseconds := 60000);            -- returns a request id
  insert into detour_route (...) select ... from jsonb_to_recordset(
         (select content::jsonb from net._http_response where id = <request id>)) ...
  on conflict (brdg_nbr, mode, seq) do update ...
The full statement is in tools/detour/README.md.
"""
import sys, os, json, glob, collections

VINTAGE = 'OSM north-carolina-261012'
RUN_ID = 20261015
KEYS = ('brdg_nbr', 'mode', 'seq', 'a', 'b', 'block', 'open_mi', 'around_mi',
        'open_path', 'closed_path', 'open_steps', 'closed_steps')

out_dir, runs = sys.argv[1], sys.argv[2:]
rows, stats = {}, collections.Counter()
for d in runs:
    for f in sorted(glob.glob(os.path.join(d, 'routes_*.jsonl'))):
        for ln in open(f):
            r = json.loads(ln); st = r.get('status', '?')
            stats[st.split(':')[0]] += 1
            if st != 'ok': continue
            rec = {k: r[k] for k in KEYS}; rec['graph_vintage'] = VINTAGE; rec['run_id'] = RUN_ID
            rows[(r['brdg_nbr'], r['mode'], r['seq'])] = rec
os.makedirs(out_dir, exist_ok=True)
for old in glob.glob(os.path.join(out_dir, 'routes_*.json')): os.remove(old)
ordered = [rows[k] for k in sorted(rows)]
n = 0
for i in range(0, len(ordered), 2000):
    n += 1
    with open(os.path.join(out_dir, f'routes_{n:02d}.json'), 'w') as f:
        json.dump(ordered[i:i + 2000], f, separators=(',', ':'))
print(json.dumps({'rows': len(ordered), 'files': n, **stats}))
