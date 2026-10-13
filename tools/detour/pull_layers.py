import json,urllib.request,urllib.parse,sys
import sys
LAYERS=[int(x) for x in sys.argv[1:]] or [0]
BASE="https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Structures/NCDOT_DynamicStructures/MapServer/"
F="ObjectID,StructureNumber,County,FacilityCarried,FeatureIntersected,ServiceUnder,StructureLength,BridgeDeckWidth,FedSkew,DetourLength,Latitude,Longitude"
def q(params):
    u=globals()["S"]+"?"+urllib.parse.urlencode(params)
    return json.loads(urllib.request.urlopen(u,timeout=120).read())
grand=[]
for LAYER in LAYERS:
    S=BASE+str(LAYER)+"/query"
    total=q({"where":"1=1","returnCountOnly":"true","f":"json"})["count"]
    rows=[];off=0;pages=0
    while True:
        j=q({"where":"1=1","outFields":F,"returnGeometry":"true","outSR":"4326","orderByFields":"ObjectID",
             "resultOffset":off,"resultRecordCount":1000,"f":"json"})
        if "error" in j: sys.exit("ERROR "+json.dumps(j["error"]))
        fs=j.get("features",[]); pages+=1
        for f in fs:
            a=f["attributes"]; g=f.get("geometry") or {}
            a["_lat"]=g.get("y"); a["_lon"]=g.get("x"); a["_layer"]=LAYER; rows.append(a)
        off+=len(fs)
        if not fs or not j.get("exceededTransferLimit"): break
    print(f"layer {LAYER}: count endpoint {total}, pulled {len(rows)} in {pages} pages ->", "MATCH" if len(rows)==total else "MISMATCH - DO NOT PROCEED")
    grand+=rows
ids=[r["StructureNumber"] for r in grand]
print(f"total {len(grand)}, distinct structure numbers {len(set(ids))}, missing geometry {sum(1 for r in grand if r['_lat'] is None)}")
json.dump(grand,open("structures.json","w"))
