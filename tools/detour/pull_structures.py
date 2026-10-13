import json,urllib.request,urllib.parse,sys
S="https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Structures/NCDOT_DynamicStructures/MapServer/0/query"
F="ObjectID,StructureNumber,County,FacilityCarried,FeatureIntersected,ServiceUnder,StructureLength,BridgeDeckWidth,FedSkew,DetourLength,Latitude,Longitude"
def q(params):
    u=S+"?"+urllib.parse.urlencode(params)
    return json.loads(urllib.request.urlopen(u,timeout=120).read())
total=q({"where":"1=1","returnCountOnly":"true","f":"json"})["count"]
rows=[];off=0;pages=0
while True:
    j=q({"where":"1=1","outFields":F,"returnGeometry":"true","outSR":"4326","orderByFields":"ObjectID",
         "resultOffset":off,"resultRecordCount":1000,"f":"json"})
    if "error" in j: sys.exit("ERROR "+json.dumps(j["error"]))
    fs=j.get("features",[]); pages+=1
    for f in fs:
        a=f["attributes"]; g=f.get("geometry") or {}
        a["_lat"]=g.get("y"); a["_lon"]=g.get("x"); rows.append(a)
    off+=len(fs)
    # the ONLY trustworthy "more data" signal is exceededTransferLimit
    if not fs or not j.get("exceededTransferLimit"): break
json.dump(rows,open("structures.json","w"))
ids=[r["StructureNumber"] for r in rows]
print(f"count endpoint says {total}; pulled {len(rows)} in {pages} pages; distinct structure numbers {len(set(ids))}")
print("MATCH" if len(rows)==total else "MISMATCH - DO NOT PROCEED")
print("missing geometry:",sum(1 for r in rows if r['_lat'] is None))
print("missing length:",sum(1 for r in rows if not r['StructureLength']))
print("missing width :",sum(1 for r in rows if not r['BridgeDeckWidth']))
