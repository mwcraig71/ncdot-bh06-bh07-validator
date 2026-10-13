import json, collections, statistics as st, math, glob
S = {str(s['StructureNumber']).strip(): s for s in json.load(open('structures.json'))}
rows = [r for ln in open('results_final.jsonl') for r in json.loads(ln)]
done = {r['brdg_nbr'] for r in rows}
print(f"{len(done):,} of {len(S):,} structures, {len(rows):,} rows\n")
c = collections.Counter((r['mode'], r['verdict']) for r in rows)
for mode in ('bypass', 'collapse'):
    tot = sum(v for (m, _), v in c.items() if m == mode)
    print(f"{mode}: {tot:,} rows")
    for (m, v), n in sorted(c.items(), key=lambda x: -x[1]):
        if m == mode: print(f"   {v:15} {n:7,}  {100*n/tot:5.1f}%")
print("\ndecks inferred:", sum(1 for r in rows if r['mode']=='bypass' and r['deck_inferred']))
print("top unmeasured reasons (bypass):")
for k, v in collections.Counter(r['reason'] for r in rows if r['mode']=='bypass' and r['verdict']=='unmeasured').most_common(5):
    print(f"   {v:6,}  {k}")

# ---- the units question, statewide ------------------------------------------
B = [r for r in rows if r['mode']=='bypass' and r['verdict'] in ('ok','bypass_at_site')]
pairs = []
for r in B:
    code = S[r['brdg_nbr']]['DetourLength']
    if code is None: continue
    pairs.append((int(code), r['around_mi'], r['additional_mi'], r['verdict']))
print(f"\nbypass measured with an NCDOT code: {len(pairs):,}")
cc = collections.Counter(p[0] for p in pairs)
print("   code 0 (bypass at site):", cc[0], "  code 99:", cc[99])
real = [p for p in pairs if 1 <= p[0] <= 98 and p[3]=='ok' and p[1] >= 1.0]
print(f"   codes 1-98 with a measured detour >= 1 mi: {len(real):,}")
for label, idx in (("around (path length)", 1), ("additional travel", 2)):
    rm = [p[idx]/p[0] for p in real if p[idx] > 0]
    rk = [p[idx]/(p[0]*0.621371) for p in real if p[idx] > 0]
    gm = lambda xs: math.exp(st.mean(math.log(x) for x in xs))
    closer_m = sum(1 for p in real if p[idx] > 0 and abs(math.log(p[idx]/p[0])) < abs(math.log(p[idx]/(p[0]*0.621371))))
    w50m = sum(1 for x in rm if 0.5 <= x <= 1.5); w50k = sum(1 for x in rk if 0.5 <= x <= 1.5)
    print(f"\n   measured {label} / code")
    print(f"      read as MILES: median {st.median(rm):.2f}  geo-mean {gm(rm):.2f}  within +/-50%: {w50m:,} ({100*w50m/len(rm):.0f}%)")
    print(f"      read as KM   : median {st.median(rk):.2f}  geo-mean {gm(rk):.2f}  within +/-50%: {w50k:,} ({100*w50k/len(rk):.0f}%)")
    print(f"      closer to 1 as miles on {closer_m:,} of {len(rm):,} ({100*closer_m/len(rm):.0f}%)")
# does code 0 agree with "bypass at site"?
z = [p for p in pairs if p[0]==0]
if z:
    print(f"\n   code 0: measured additional travel median {st.median([p[2] for p in z]):.2f} mi; "
          f"{sum(1 for p in z if p[2] < 1):,} of {len(z):,} under 1 mi")
n99 = [r for r in rows if r['mode']=='bypass' and S[r['brdg_nbr']]['DetourLength']==99]
if n99:
    v = collections.Counter(r['verdict'] for r in n99)
    m = [r['around_mi'] for r in n99 if r['around_mi'] is not None]
    print(f"   code 99: verdicts {dict(v)}; measured around median {st.median(m):.1f} mi" if m else "")
