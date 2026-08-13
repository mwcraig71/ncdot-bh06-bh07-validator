#!/usr/bin/env python3
"""
ncdot_bh0607.py  -- Batch BH06 (LRS Route ID) / BH07 (LRS Milepoint) for NC bridges.

Uses two PUBLIC NCDOT ArcGIS REST services (no login, no ArcGIS license):

  1. NCDOT_Bridges/MapServer/0            -> statewide bridge points, already carries
                                             RTE_ID (11-digit) and MP for most bridges.
  2. NCDOT_Tools/NCDOTIdentifyRouteMilepostUsingPointTool/GPServer
                                          -> "drop a pin, get route + milepost",
                                             same thing TxDOT's map does. Async GP job,
                                             up to 1000 points per submit. Also returns
                                             concurrent routes 2-6 for multi-route bridges.

Modes:
  pull    : dump the whole statewide bridge table (BH06/BH07 as NCDOT publishes it)
  locate  : send bridge points through the GP tool to compute route+milepoint fresh
  compare : do both and flag disagreements  <-- this is the QC run

Usage:
  python ncdot_bh0607.py pull    --out bridges.csv
  python ncdot_bh0607.py pull    --county MECKLENBURG --out meck.csv
  python ncdot_bh0607.py locate  --in mypoints.csv --out located.csv
  python ncdot_bh0607.py compare --county MECKLENBURG --out qc.csv
  python ncdot_bh0607.py compare --limit 500 --out qc_sample.csv

Input CSV for `locate` needs columns: BRDG_NBR, LAT_DD, LONG_DD
"""

import argparse, csv, json, sys, time, urllib.parse, urllib.request

BRIDGES = "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Bridges/MapServer/0"
GPTOOL = ("https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Tools/"
          "NCDOTIdentifyRouteMilepostUsingPointTool/GPServer/"
          "Identify%20Route%20Milepost%20Using%20Point%20Tool")
BATCH = 500          # GP tool advertises maximumRecords 1000; 500 is a safe chunk
TIMEOUT = 180

BRIDGE_FIELDS = ("BRDG_NBR,COUNTY,DIVISION,ROUTE,RTE_ID,MP,F_CARRIED,FTR_INTRSC,"
                 "SERVICEON,SERVICEUNDER,MAINT_RESP,FUNC_CLASS,LAT_DD,LONG_DD")


# ---------------------------------------------------------------- http helpers
def _get(url, params, retries=3):
    q = urllib.parse.urlencode(params)
    for a in range(retries):
        try:
            with urllib.request.urlopen(f"{url}?{q}", timeout=TIMEOUT) as r:
                return json.load(r)
        except Exception as e:
            if a == retries - 1:
                raise
            time.sleep(2 * (a + 1))


def _post(url, params, retries=3):
    data = urllib.parse.urlencode(params).encode()
    for a in range(retries):
        try:
            with urllib.request.urlopen(url, data, timeout=TIMEOUT) as r:
                return json.load(r)
        except Exception as e:
            if a == retries - 1:
                raise
            time.sleep(2 * (a + 1))


# ---------------------------------------------------------------- bridge table
def pull_bridges(where="1=1", limit=None):
    """Page the whole statewide bridge layer out of the REST service."""
    out, offset, page = [], 0, 2000
    while True:
        j = _get(f"{BRIDGES}/query", {
            "where": where, "outFields": BRIDGE_FIELDS, "returnGeometry": "false",
            "orderByFields": "OBJECTID", "resultOffset": offset,
            "resultRecordCount": page, "f": "json"})
        feats = j.get("features", [])
        out.extend(f["attributes"] for f in feats)
        sys.stderr.write(f"\r  pulled {len(out)} bridges")
        sys.stderr.flush()
        if limit and len(out) >= limit:
            out = out[:limit]
            break
        if len(feats) < page:
            break
        offset += page
    sys.stderr.write("\n")
    return out


# ---------------------------------------------------------- GP locate (the pin)
def _to_stateplane(lon, lat):
    from pyproj import Transformer
    if not hasattr(_to_stateplane, "T"):
        # NAD83 / North Carolina (ftUS) -- the SR the GP tool expects
        _to_stateplane.T = Transformer.from_crs(4326, 2264, always_xy=True)
    return _to_stateplane.T.transform(lon, lat)


def locate_points(points):
    """points: list of dicts with id, lat, lon. Returns dict id -> result attrs."""
    results = {}
    for i in range(0, len(points), BATCH):
        chunk = points[i:i + BATCH]
        feats = []
        idmap = {}
        for n, p in enumerate(chunk):
            x, y = _to_stateplane(float(p["lon"]), float(p["lat"]))
            feats.append({"geometry": {"x": x, "y": y}, "attributes": {"Id": n}})
            idmap[n] = p["id"]
        fs = {"geometryType": "esriGeometryPoint",
              "spatialReference": {"wkid": 2264},
              "fields": [{"name": "Id", "type": "esriFieldTypeInteger", "alias": "Id"}],
              "features": feats}
        job = _post(f"{GPTOOL}/submitJob",
                    {"PointLocations": json.dumps(fs), "f": "json"})
        jid = job.get("jobId")
        if not jid:
            sys.stderr.write(f"\n  submit failed: {job}\n")
            continue
        st = job
        for _ in range(90):
            time.sleep(2)
            st = _get(f"{GPTOOL}/jobs/{jid}", {"f": "json"})
            if st.get("jobStatus") not in ("esriJobSubmitted", "esriJobExecuting",
                                           "esriJobWaiting", "esriJobNew"):
                break
        if st.get("jobStatus") != "esriJobSucceeded":
            sys.stderr.write(f"\n  job {jid} -> {st.get('jobStatus')}\n")
            continue
        res = _get(f"{GPTOOL}/jobs/{jid}/results/IdentifyRouteMPResults", {"f": "json"})
        for f in res.get("value", {}).get("features", []):
            a = f["attributes"]
            key = idmap.get(a.get("Id"))
            if key is not None:
                results[key] = a
        sys.stderr.write(f"\r  located {len(results)}/{len(points)}")
        sys.stderr.flush()
    sys.stderr.write("\n")
    return results


# ---------------------------------------------------------------- SNBI checks
def snbi_flags(rid, mp):
    """The four things the FHWA submittal actually checks on BH06/BH07."""
    f = []
    if rid in (None, "", "NA"):
        f.append("BH06_MISSING")
    else:
        if len(str(rid)) > 120:
            f.append("BH06_OVER_120_CHAR")
        if not str(rid).isdigit() or len(str(rid)) != 11:
            f.append("BH06_NOT_NCDOT_11DIGIT")
        if str(rid).startswith("5"):
            # class 5 = non-system (municipal / private): usually NOT on the HPMS
            # network, so this is the population most likely to trip "LRS ID not
            # found in HPMS". Confirm before submitting.
            f.append("BH06_NONSYSTEM_CHECK_HPMS")
    if mp in (None, ""):
        f.append("BH07_MISSING")
    else:
        s = f"{float(mp):.3f}"
        if len(s.replace(".", "").replace("-", "")) > 8:
            f.append("BH07_OVER_8_DIGITS")
        if float(mp) < 0:
            f.append("BH07_NEGATIVE")
    return ";".join(f)


def fmt_mp(mp):
    return "" if mp in (None, "") else f"{float(mp):.3f}"


# ---------------------------------------------------------------- concurrency
def concurrent_routes(a):
    """Routes 2-6 the GP tool reports where routes overlap (the urban case)."""
    out = []
    for n in range(2, 7):
        r = a.get(f"Route{n}")
        if r:
            out.append(f"{r}@{a.get(f'BeginMp{n}')}-{a.get(f'EndMp{n}')}")
    return " | ".join(out)


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["pull", "locate", "compare"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--county")
    ap.add_argument("--where", default="1=1")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--in", dest="infile")
    ap.add_argument("--tol", type=float, default=0.005,
                    help="milepoint disagreement tolerance in miles (default .005 = ~26 ft)")
    args = ap.parse_args()

    where = args.where
    if args.county:
        where = f"COUNTY='{args.county.upper()}'"

    # ---- pull -------------------------------------------------------------
    if args.mode == "pull":
        rows = pull_bridges(where, args.limit)
        with open(args.out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["BRDG_NBR", "COUNTY", "F_CARRIED", "FTR_INTRSC",
                        "BH06_LRS_ROUTE_ID", "BH07_LRS_MILEPOINT",
                        "MAINT_RESP", "LAT_DD", "LONG_DD", "FLAGS"])
            for r in rows:
                w.writerow([r.get("BRDG_NBR"), r.get("COUNTY"), r.get("F_CARRIED"),
                            r.get("FTR_INTRSC"), r.get("RTE_ID"), fmt_mp(r.get("MP")),
                            r.get("MAINT_RESP"), r.get("LAT_DD"), r.get("LONG_DD"),
                            snbi_flags(r.get("RTE_ID"), r.get("MP"))])
        print(f"{len(rows)} bridges -> {args.out}")
        return

    # ---- locate -----------------------------------------------------------
    if args.mode == "locate":
        pts = []
        with open(args.infile) as fh:
            for r in csv.DictReader(fh):
                pts.append({"id": r["BRDG_NBR"], "lat": r["LAT_DD"], "lon": r["LONG_DD"]})
        res = locate_points(pts)
        with open(args.out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["BRDG_NBR", "BH06_LRS_ROUTE_ID", "BH07_LRS_MILEPOINT",
                        "ROUTE_NAME", "STREET_NAME", "OFFSET_MI",
                        "CONCURRENT_ROUTES", "FLAGS"])
            for p in pts:
                a = res.get(p["id"], {})
                w.writerow([p["id"], a.get("RID", ""), fmt_mp(a.get("MEAS")),
                            a.get("RouteName", ""), a.get("StreetName", ""),
                            a.get("NEAR_DIST", ""), concurrent_routes(a),
                            snbi_flags(a.get("RID"), a.get("MEAS"))])
        print(f"{len(res)}/{len(pts)} located -> {args.out}")
        return

    # ---- compare (QC) -----------------------------------------------------
    rows = pull_bridges(where, args.limit)
    pts = [{"id": r["BRDG_NBR"], "lat": r["LAT_DD"], "lon": r["LONG_DD"]}
           for r in rows if r.get("LAT_DD") and r.get("LONG_DD")]
    res = locate_points(pts)

    agree = disagree = missing = 0
    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["BRDG_NBR", "COUNTY", "F_CARRIED",
                    "PUB_BH06", "PUB_BH07", "CALC_BH06", "CALC_BH07",
                    "DELTA_MI", "OFFSET_MI", "CONCURRENT_ROUTES", "STATUS", "FLAGS"])
        for r in rows:
            a = res.get(r.get("BRDG_NBR"), {})
            pr, pm = r.get("RTE_ID"), r.get("MP")
            cr, cm = a.get("RID"), a.get("MEAS")
            if not cr:
                status, delta = "NOT_LOCATED", ""
                missing += 1
            elif pr in (None, "", "NA") or pm in (None, ""):
                status, delta = "FILLED_GAP", ""
                disagree += 1
            else:
                delta = abs(float(pm) - float(cm))
                if pr == cr and delta <= args.tol:
                    status = "AGREE"; agree += 1
                else:
                    status = ("ROUTE_MISMATCH" if pr != cr else "MP_MISMATCH")
                    disagree += 1
                delta = f"{delta:.4f}"
            w.writerow([r.get("BRDG_NBR"), r.get("COUNTY"), r.get("F_CARRIED"),
                        pr, fmt_mp(pm), cr or "", fmt_mp(cm), delta,
                        a.get("NEAR_DIST", ""), concurrent_routes(a), status,
                        snbi_flags(cr or pr, cm if cm is not None else pm)])
    tot = len(rows)
    print(f"\n{tot} bridges | agree {agree} ({agree/tot:.1%}) | "
          f"needs review {disagree} | not located {missing}  -> {args.out}")


if __name__ == "__main__":
    main()
