#!/usr/bin/env python3
"""
As-measured detour length - measurement prototype.

Backs the finding in as-measured-detour-feasibility.md. Two measurements, one
routine, two modes:

  bypass   the deck is blocked, the road underneath stays open
  collapse the ground under the span is blocked, the deck stays open

Routing is Valhalla. Both of its block primitives are used deliberately:
exclude_locations blocks a single edge (bypass), exclude_polygons blocks an area.
OSRM cannot do either - it has no avoid/exclude of any kind.

Entry points:
  detour_both(lat, lon, structure_length_ft, deck_width_ft)
  bypass_v3 / collapse_v4          single mode
  detour_for2                      adaptive-reach variant, preferred

Earlier variants (bypass_v2, collapse_v2/v3, span_detour, diversion_detour) are
kept deliberately: each failed in an instructive way and the doc cites them. Later
definitions win in Python, so the preferred paths above are what execute.

Every returned value carries a verdict. UNMEASURED with a reason is a valid
outcome and must never be rendered as a number. See the validity tests in
measure() and passes_through().

NOTE: V points at the public Valhalla instance, which is a courtesy service with
no SLA. A statewide pass is ~10^5 route calls and must run against a self-hosted
North Carolina extract instead.
"""
import json,math,urllib.request,os
V="https://valhalla1.openstreetmap.de"
def post(path,body):
    req=urllib.request.Request(V+path,data=json.dumps(body).encode(),
        headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(req,timeout=60).read())
M_PER_FT=0.3048
def dest(lat,lon,brg,m):
    R=6371000.0; b=math.radians(brg); p1=math.radians(lat); l1=math.radians(lon); d=m/R
    p2=math.asin(math.sin(p1)*math.cos(d)+math.cos(p1)*math.sin(d)*math.cos(b))
    l2=l1+math.atan2(math.sin(b)*math.sin(d)*math.cos(p1), math.cos(d)-math.sin(p1)*math.sin(p2))
    return math.degrees(p2), math.degrees(l2)

def locate(lat,lon,costing="auto"):
    return post("/locate",{"locations":[{"lat":lat,"lon":lon}],"costing":costing,"verbose":True})[0]

def bridge_edge(lo):
    """the snapped edge flagged as a bridge, preferring the forward direction"""
    es=[e for e in lo.get('edges',[]) if e['edge'].get('bridge')]
    if not es: return None
    es.sort(key=lambda e:(not e['edge'].get('forward'), e['distance']))
    return es[0]

def footprint(lat,lon,brg,length_ft,width_ft,pad_ft=25,wpad_ft=20):
    """rectangle over the deck: along = structure length, across = deck width"""
    L=(length_ft+2*pad_ft)*M_PER_FT/2.0
    W=(width_ft+2*wpad_ft)*M_PER_FT/2.0
    ring=[]
    for dl,dw in ((+1,+1),(+1,-1),(-1,-1),(-1,+1)):
        p=dest(lat,lon,brg,dl*L); p=dest(p[0],p[1],(brg+90)%360,dw*W)
        ring.append([round(p[1],7),round(p[0],7)])   # lon,lat
    ring.append(ring[0])
    return [ring]

def route(a,b,exclude_poly=None,exclude_locs=None,costing="auto"):
    body={"locations":[{"lat":a[0],"lon":a[1]},{"lat":b[0],"lon":b[1]}],
          "costing":costing,"directions_options":{"units":"miles"}}
    if exclude_poly: body["exclude_polygons"]=exclude_poly
    if exclude_locs: body["exclude_locations"]=[{"lat":p[0],"lon":p[1]} for p in exclude_locs]
    try:
        j=post("/route",body)
        s=j['trip']['summary']
        return {"mi":s['length'],"min":s['time']/60.0}
    except urllib.error.HTTPError as ex:
        d=ex.read().decode()[:200]
        return {"err":d}

def decode(s,prec=1e6):
    pts=[];i=0;lat=0;lon=0
    while i<len(s):
        for idx in range(2):
            shift=0;result=0
            while True:
                b=ord(s[i])-63;i+=1
                result|=(b&0x1f)<<shift;shift+=5
                if b<0x20:break
            d=~(result>>1) if result&1 else result>>1
            if idx==0: lat+=d
            else: lon+=d
        pts.append((lat/prec,lon/prec))
    return pts

def hav(a,b):
    R=6371000.0
    p1,p2=math.radians(a[0]),math.radians(b[0])
    dp=p2-p1; dl=math.radians(b[1]-a[1])
    x=math.sin(dp/2)**2+math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(math.sqrt(x))

def shape_len(pts):
    return sum(hav(pts[i],pts[i+1]) for i in range(len(pts)-1))

def locate_r(lat,lon,radius=40,costing="auto"):
    return post("/locate",{"locations":[{"lat":lat,"lon":lon,"radius":radius}],
                           "costing":costing,"verbose":True})[0]

def corr(e): return (e['correlated_lat'],e['correlated_lon'])

def angdiff(a,b):
    d=abs((a-b)%360)
    return min(d,360-d)

def classify(lat,lon,radius=40):
    """split the roads at a crossing into the deck(s) and the road(s) beneath"""
    lo=locate_r(lat,lon,radius)
    es=lo.get('edges',[])
    if not es: return None,[]
    decks=[e for e in es if e['edge'].get('bridge')]
    if not decks: return None,[]
    deck=min(decks,key=lambda e:e['distance'])
    dh=deck['heading']
    # a road beneath: not a bridge, and not running parallel to the deck
    unders=[e for e in es if not e['edge'].get('bridge')
            and angdiff(e['heading'],dh)>25 and angdiff(e['heading'],(dh+180)%360)>25]
    out=[];seen=set()
    for e in sorted(unders,key=lambda e:e['distance']):
        k=str(e['edge_info'].get('names'))+str(round(e['heading']/10))
        if k in seen: continue
        seen.add(k); out.append(e)
    return deck,out

def collapse(lat,lon,deck_w_ft,pad_ft=120,tries=(0,200,500,1200,3000)):
    """detour for the road UNDER the bridge, if the span fell onto it"""
    deck,unders=classify(lat,lon)
    if deck is None: return {"err":"no bridge edge in the road graph at this point"}
    if not unders:   return {"err":"no roadway found beneath this structure"}
    block=[corr(deck)]+[corr(u) for u in unders]
    res=[]
    for u in unders:
        h=u['heading']; nm=str(u['edge_info'].get('names'))
        got=None
        for extra in tries:
            half=(deck_w_ft/2.0+pad_ft+extra)*M_PER_FT
            up=dest(lat,lon,(h+180)%360,half); dn=dest(lat,lon,h,half)
            base=route(up,dn); det=route(up,dn,exclude_locs=block)
            if 'mi' in base and 'mi' in det and det['mi']>base['mi']*1.2:
                got={"road":nm,"under":det['mi'],"direct":base['mi'],
                     "extra":det['mi']-base['mi'],"pad":pad_ft+extra}; break
            if 'mi' in base and 'mi' in det:
                got={"road":nm,"under":det['mi'],"direct":base['mi'],
                     "extra":det['mi']-base['mi'],"pad":pad_ft+extra,"note":"bypass at site"}; break
        res.append(got or {"road":nm,"err":"no path around the collapse"})
    return {"deck":str(deck['edge_info'].get('names'))[:40],"beneath":res}

def proj_idx(shape,lat,lon):
    """index of the shape vertex nearest a point"""
    best=0;bd=1e18
    for i,p in enumerate(shape):
        d=hav(p,(lat,lon))
        if d<bd: bd=d;best=i
    return best,bd

def walk(shape,i0,dist_m,forward=True):
    """a point dist_m along the polyline from vertex i0; clamps at the end"""
    rem=dist_m; i=i0
    while 0<=i<len(shape)-1 if forward else i>0:
        j=i+1 if forward else i-1
        seg=hav(shape[i],shape[j])
        if seg>=rem and seg>0:
            f=rem/seg
            return (shape[i][0]+(shape[j][0]-shape[i][0])*f,
                    shape[i][1]+(shape[j][1]-shape[i][1])*f), True
        rem-=seg; i=j
    return shape[-1 if forward else 0], False

def edge_shape_dir(e):
    """the edge's shape oriented in the direction of travel"""
    sh=decode(e['edge_info']['shape'])
    return sh if e['edge'].get('forward',True) else sh[::-1]

def collapse2(lat,lon,deck_w_ft,pad_ft=150):
    deck,unders=classify(lat,lon)
    if deck is None: return {"err":"no bridge edge in the road graph here"}
    if not unders:   return {"err":"no roadway beneath"}
    block=[corr(deck)]+[corr(u) for u in unders]
    need=(deck_w_ft/2.0+pad_ft)*M_PER_FT
    res=[]
    for u in unders:
        nm=str(u['edge_info'].get('names'))
        sh=edge_shape_dir(u)
        cl=corr(u); i0,snap=proj_idx(sh,cl[0],cl[1])
        dn,okd=walk(sh,i0,need,True)
        up,oku=walk(sh,i0,need,False)
        base=route(up,dn); det=route(up,dn,exclude_locs=block)
        row={"road":nm,"clamped":(not okd) or (not oku)}
        if 'mi' in base and 'mi' in det:
            row.update(around=det['mi'],direct=base['mi'],extra=det['mi']-base['mi'])
        else: row["err"]=base.get('err',det.get('err',''))[:60]
        res.append(row)
    return {"deck":str(deck['edge_info'].get('names'))[:38],"beneath":res}

def bearing(a,b):
    p1,p2=math.radians(a[0]),math.radians(b[0]); dl=math.radians(b[1]-a[1])
    y=math.sin(dl)*math.cos(p2)
    x=math.cos(p1)*math.sin(p2)-math.sin(p1)*math.cos(p2)*math.cos(dl)
    return (math.degrees(math.atan2(y,x))+360)%360

def past_ends(shape,step_m=60):
    """points just beyond each end of an edge, continuing its own bearing"""
    b0=bearing(shape[1],shape[0])        # outward at the start
    b1=bearing(shape[-2],shape[-1])      # outward at the end
    return dest(shape[0][0],shape[0][1],b0,step_m), dest(shape[-1][0],shape[-1][1],b1,step_m)

def off_edge(p,blocked_pt,tol_m=30):
    """is p on a road, and not the blocked edge"""
    lo=locate_r(p[0],p[1],25)
    es=lo.get('edges',[])
    if not es: return False
    return es[0]['distance']<tol_m

def span_detour(block_edge,block_pts,steps=(60,120,250,500)):
    """route around one blocked edge, from just past one end to just past the other"""
    sh=edge_shape_dir(block_edge)
    edge_mi=shape_len(sh)/1609.34
    for st in steps:
        A,B=past_ends(sh,st)
        base=route(A,B); det=route(A,B,exclude_locs=block_pts)
        if 'mi' in base and 'mi' in det and det['mi']>base['mi']*1.05:
            return {"around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
                    "edge_mi":edge_mi,"step_m":st}
        if 'mi' in base and 'mi' in det:
            return {"around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
                    "edge_mi":edge_mi,"step_m":st,"note":"no detour needed - alternative at the site"}
    return {"err":"no path with this span blocked","edge_mi":edge_mi}

def anchor_ok(p,want_names,want_head,tol_m=25,head_tol=40):
    lo=locate_r(p[0],p[1],25); es=lo.get('edges',[])
    if not es: return False,"no road at the anchor"
    e=min(es,key=lambda x:x['distance'])
    if e['distance']>tol_m: return False,f"anchor {e['distance']:.0f} m off any road"
    nm=set(x.lower() for x in (e['edge_info'].get('names') or []))
    if want_names and nm and not (nm & want_names): return False,f"anchor landed on {list(nm)[:1]}"
    if angdiff(e['heading'],want_head)>head_tol and angdiff(e['heading'],(want_head+180)%360)>head_tol:
        return False,"anchor faces the wrong way"
    return True,""

def span_detour_v(block_edge,block_pts,steps=(60,120,250,500),slack=1.8):
    sh=edge_shape_dir(block_edge)
    edge_mi=shape_len(sh)/1609.34
    names=set(x.lower() for x in (block_edge['edge_info'].get('names') or []))
    head=block_edge['heading']
    last="no usable anchors"
    for st in steps:
        A,B=past_ends(sh,st)
        okA,wa=anchor_ok(A,names,head); okB,wb=anchor_ok(B,names,head)
        if not (okA and okB): last=(wa or wb); continue
        crow=hav(A,B)/1609.34
        base=route(A,B)
        if 'mi' not in base: last="no baseline path"; continue
        if base['mi']>max(0.15,crow*slack):
            last=f"baseline {base['mi']:.2f} mi for a {crow:.2f} mi gap - anchors not on one path"
            continue
        det=route(A,B,exclude_locs=block_pts)
        if 'mi' not in det:
            return {"edge_mi":edge_mi,"verdict":"NO DETOUR","why":"no route exists with this span closed"}
        return {"around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
                "edge_mi":edge_mi,"step_m":st,
                "verdict":"ok" if det['mi']>base['mi']*1.05 else "bypass at site"}
    return {"edge_mi":edge_mi,"verdict":"UNMEASURED","why":last}

def route_shape(a,b,exclude_locs=None,costing="auto"):
    body={"locations":[{"lat":a[0],"lon":a[1]},{"lat":b[0],"lon":b[1]}],
          "costing":costing,"directions_options":{"units":"miles"},
          "shape_format":"polyline6"}
    if exclude_locs: body["exclude_locations"]=[{"lat":p[0],"lon":p[1]} for p in exclude_locs]
    try:
        j=post("/route",body); t=j['trip']
        sh=[]
        for leg in t['legs']: sh+=decode(leg['shape'])
        return {"mi":t['summary']['length'],"shape":sh}
    except urllib.error.HTTPError as ex:
        return {"err":ex.read().decode()[:120]}

def cum(shape):
    c=[0.0]
    for i in range(len(shape)-1): c.append(c[-1]+hav(shape[i],shape[i+1]))
    return c

def at_dist(shape,c,m):
    for i in range(1,len(c)):
        if c[i]>=m:
            f=(m-c[i-1])/max(1e-9,(c[i]-c[i-1]))
            return (shape[i-1][0]+(shape[i][0]-shape[i-1][0])*f,
                    shape[i-1][1]+(shape[i][1]-shape[i-1][1])*f)
    return shape[-1]

def diversion_detour(lat,lon,under,block_pts,probe_mi=(0.25,0.5,1,2,4,8),reach_mi=12):
    """walk outward along the road beneath until a way around the closure exists"""
    h=under['heading']
    dn_far=dest(lat,lon,h,reach_mi*1609.34)
    up_far=dest(lat,lon,(h+180)%360,reach_mi*1609.34)
    fwd=route_shape(corr(under),dn_far)          # downstream along the road
    bwd=route_shape(up_far,corr(under))          # upstream, arriving at the crossing
    if 'err' in fwd or 'err' in bwd: return {"verdict":"UNMEASURED","why":"could not trace the road"}
    fs=fwd['shape']; fc=cum(fs)
    bs=bwd['shape'][::-1]; bc=cum(bs)            # reversed: index 0 at the crossing
    for d in probe_mi:
        m=d*1609.34
        if m>fc[-1] or m>bc[-1]: break
        B=at_dist(fs,fc,m); A=at_dist(bs,bc,m)
        base=route(A,B)
        if 'mi' not in base: continue
        det=route(A,B,exclude_locs=block_pts)
        if 'mi' not in det: continue
        if det['mi']>base['mi']*1.05:
            return {"verdict":"ok","around":det['mi'],"direct":base['mi'],
                    "extra":det['mi']-base['mi'],"probe_mi":d}
        return {"verdict":"bypass at site","around":det['mi'],"direct":base['mi'],
                "extra":det['mi']-base['mi'],"probe_mi":d}
    return {"verdict":"NO DETOUR","why":f"none within {reach_mi} mi of the crossing"}

# ---- blocking only the obstruction ---------------------------------------
# Bypass : the deck is gone, the road underneath still works.
# Collapse: the span is on the road below; the road below is gone, the deck
#           above is intact and may be used to get across.

def edges_at(lat,lon,radius=70):
    lo=locate_r(lat,lon,radius)
    out=[];seen=set()
    for e in lo.get('edges',[]):
        nm=str(e['edge_info'].get('names'))
        k=(nm,e['edge'].get('bridge'),round(e['heading']/15),round(e['correlated_lat'],5))
        if k in seen: continue
        seen.add(k); out.append(e)
    return out

def in_poly(pt,ring):
    """pt=(lat,lon); ring is [[lon,lat],...] closed"""
    x,y=pt[1],pt[0]; inside=False
    for i in range(len(ring)-1):
        x1,y1=ring[i]; x2,y2=ring[i+1]
        if (y1>y)!=(y2>y):
            xi=x1+(y-y1)*(x2-x1)/((y2-y1) or 1e-12)
            if x<xi: inside=not inside
    return inside

def deck_and_obstruction(lat,lon,L_ft,W_ft,pad_ft=15,wpad_ft=20,radius=70):
    """returns (deck edges of THIS structure, edges on the ground under it, footprint)"""
    es=edges_at(lat,lon,radius)
    decks=[e for e in es if e['edge'].get('bridge')]
    if not decks: return None,None,None
    dh=min(decks,key=lambda e:e['distance'])['heading']
    poly=footprint(lat,lon,dh,L_ft,W_ft,pad_ft,wpad_ft); ring=poly[0]
    # this structure's deck: elevated, inside the footprint, running with the deck
    mine=[e for e in decks if in_poly(corr(e),ring)
          and (angdiff(e['heading'],dh)<=25 or angdiff(e['heading'],(dh+180)%360)<=25)]
    # the obstruction: everything at ground level inside the footprint
    ground=[e for e in es if not e['edge'].get('bridge') and in_poly(corr(e),ring)]
    return mine,ground,poly

def bypass_v2(lat,lon,L_ft,W_ft,pad_ft=75,tries=(0,150,400,900,2000)):
    """road ON the bridge. Only the deck is blocked - the road below stays open."""
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if not mine: return {"verdict":"UNMEASURED","why":"no deck for this structure in the road graph"}
    dh=mine[0]['heading']
    block=[corr(e) for e in mine]
    names=set(x.lower() for x in (mine[0]['edge_info'].get('names') or []))
    for extra in tries:
        half=(L_ft/2.0+pad_ft+extra)*M_PER_FT
        A=dest(lat,lon,dh,+half); B=dest(lat,lon,dh,-half)
        okA,wa=anchor_ok(A,names,dh); okB,wb=anchor_ok(B,names,dh)
        if not(okA and okB): continue
        base=route(A,B); det=route(A,B,exclude_locs=block)
        if 'mi' not in base: continue
        if 'mi' not in det:
            return {"verdict":"NO DETOUR","why":"the far side is reachable only over this bridge",
                    "blocked":len(block)}
        return {"verdict":"ok" if det['mi']>base['mi']*1.05 else "bypass at site",
                "around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
                "blocked":len(block),"under_left_open":len(ground)}
    return {"verdict":"UNMEASURED","why":"no valid anchors on the carried road"}

def collapse_v2(lat,lon,L_ft,W_ft,probe_mi=(0.25,0.5,1,2,4,8),reach_mi=12):
    """road UNDER the bridge. The ground under the span is blocked; the deck stays open."""
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if mine is None: return {"verdict":"UNMEASURED","why":"no deck in the road graph"}
    if not ground:   return {"verdict":"NONE","why":"no roadway under the span"}
    block=[corr(e) for e in ground]            # the deck is NOT in this list
    dh=mine[0]['heading'] if mine else None
    # one answer per distinct roadway direction beneath
    reps=[];seen=set()
    for e in sorted(ground,key=lambda e:e['distance']):
        nm=str(e['edge_info'].get('names')); k=(nm,round(e['heading']/30))
        if k in seen: continue
        seen.add(k); reps.append(e)
    out=[]
    for u in reps:
        h=u['heading']; nm=str(u['edge_info'].get('names'))
        fwd=route_shape(corr(u),dest(lat,lon,h,reach_mi*1609.34))
        bwd=route_shape(dest(lat,lon,(h+180)%360,reach_mi*1609.34),corr(u))
        if 'err' in fwd or 'err' in bwd:
            out.append({"road":nm,"verdict":"UNMEASURED","why":"could not trace the road"}); continue
        fs=fwd['shape']; fc=cum(fs); bs=bwd['shape'][::-1]; bc=cum(bs)
        row=None
        for d in probe_mi:
            m=d*1609.34
            if m>fc[-1] or m>bc[-1]: break
            A=at_dist(bs,bc,m); B=at_dist(fs,fc,m)
            base=route(A,B); det=route(A,B,exclude_locs=block)
            if 'mi' not in base or 'mi' not in det: continue
            if det['mi']>base['mi']*1.05:
                row={"road":nm,"verdict":"ok","around":det['mi'],"direct":base['mi'],
                     "extra":det['mi']-base['mi'],"probe_mi":d,"blocked":len(block)}; break
            row={"road":nm,"verdict":"bypass at site","around":det['mi'],"direct":base['mi'],
                 "extra":det['mi']-base['mi'],"probe_mi":d,"blocked":len(block)}
        out.append(row or {"road":nm,"verdict":"NO DETOUR","why":f"none within {reach_mi} mi"})
    return {"beneath":out,"blocked":len(block),"deck_open":len(mine)}

def names_of(e): return set(x.lower() for x in (e['edge_info'].get('names') or []))

def split_under(mine,ground):
    """ground edges that genuinely pass BENEATH, not the carried road's own approaches.
       Name disagreement is the discriminator; heading is the fallback."""
    dn=set();  dh=mine[0]['heading'] if mine else 0
    for e in mine: dn |= names_of(e)
    out=[]
    for e in ground:
        en=names_of(e)
        if en and dn:
            if en & dn: continue                       # same road as the deck carries
            out.append(e); continue
        if angdiff(e['heading'],dh)>25 and angdiff(e['heading'],(dh+180)%360)>25:
            out.append(e)
    return out

def anchor_pair(lat,lon,u,d_mi,reach_mi=12,cache={}):
    h=u['heading']; key=(round(corr(u)[0],6),round(corr(u)[1],6),round(h))
    if key not in cache:
        f=route_shape(corr(u),dest(lat,lon,h,reach_mi*1609.34))
        b=route_shape(dest(lat,lon,(h+180)%360,reach_mi*1609.34),corr(u))
        if 'err' in f or 'err' in b: cache[key]=None
        else:
            fs=f['shape']; bs=b['shape'][::-1]
            cache[key]=(fs,cum(fs),bs,cum(bs))
    c=cache[key]
    if not c: return None
    fs,fc,bs,bc=c; m=d_mi*1609.34
    if m>fc[-1] or m>bc[-1]: return None
    return at_dist(bs,bc,m), at_dist(fs,fc,m)

def collapse_v3(lat,lon,L_ft,W_ft,probe_mi=(0.25,0.5,1,2,4,8),slack=1.8):
    """road UNDER the bridge is blocked; the deck above stays usable."""
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if mine is None: return {"verdict":"UNMEASURED","why":"no deck in the road graph"}
    unders=split_under(mine,ground)
    if not unders: return {"verdict":"NONE","why":"no roadway passes under the span"}
    block=[corr(e) for e in unders]              # deck deliberately absent
    reps=[];seen=set()
    for e in sorted(unders,key=lambda e:e['distance']):
        k=(str(sorted(names_of(e))),round(e['heading']/30))
        if k in seen: continue
        seen.add(k); reps.append(e)
    out=[]
    for u in reps:
        nm=str(u['edge_info'].get('names')); why="no usable anchors"; row=None
        for d in probe_mi:
            ab=anchor_pair(lat,lon,u,d)
            if not ab: why="road could not be traced"; continue
            A,B=ab; crow=hav(A,B)/1609.34
            ok1,w1=anchor_ok(A,names_of(u),u['heading'])
            ok2,w2=anchor_ok(B,names_of(u),u['heading'])
            if not(ok1 and ok2): why=w1 or w2; continue
            base=route(A,B)
            if 'mi' not in base: why="no baseline path"; continue
            if base['mi']>max(0.2,crow*slack):
                why=f"baseline {base['mi']:.2f} mi for a {crow:.2f} mi gap"; continue
            det=route(A,B,exclude_locs=block)
            if 'mi' not in det:
                row={"road":nm,"verdict":"NO DETOUR","why":"no way around with the deck available"}; break
            if det['mi']<base['mi']*0.98:
                why=f"blocked route shorter than open one ({det['mi']:.2f} vs {base['mi']:.2f})"; continue
            row={"road":nm,"verdict":"ok" if det['mi']>base['mi']*1.05 else "bypass at site",
                 "around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
                 "probe_mi":d,"lanes":len(block)}; break
        out.append(row or {"road":nm,"verdict":"UNMEASURED","why":why})
    return {"beneath":out,"lanes_blocked":len(block),"deck_left_open":len(mine)}

def passes_through(shape,pts,tol_m=35):
    """does this route actually use the obstruction?"""
    return min((min(hav(p,q) for q in shape) for p in pts), default=1e9)<=tol_m

def measure(A,B,block,slack=1.8,tol_m=35):
    """one validated detour measurement between two anchors"""
    crow=hav(A,B)/1609.34
    base=route_shape(A,B)
    if 'mi' not in base: return None,"no open path between the anchors"
    if base['mi']>max(0.2,crow*slack):
        return None,f"open path {base['mi']:.2f} mi for a {crow:.2f} mi gap - anchors not opposed"
    if not passes_through(base['shape'],block,tol_m):
        return None,"the open path does not use the blocked span"
    det=route(A,B,exclude_locs=block)
    if 'mi' not in det: return None,"blocked"
    if det['mi']<base['mi']*0.98:
        return None,f"blocked path shorter than open one ({det['mi']:.2f} vs {base['mi']:.2f})"
    return {"around":det['mi'],"direct":base['mi'],"extra":det['mi']-base['mi'],
            "verdict":"ok" if det['mi']>base['mi']*1.05 else "bypass at site"},""

def collapse_v4(lat,lon,L_ft,W_ft,probe_mi=(0.25,0.5,1,2,4,8)):
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if mine is None: return {"verdict":"UNMEASURED","why":"no deck in the road graph"}
    unders=split_under(mine,ground)
    if not unders: return {"verdict":"NONE","why":"no roadway passes under the span"}
    block=[corr(e) for e in unders]
    reps=[];seen=set()
    for e in sorted(unders,key=lambda e:e['distance']):
        k=(str(sorted(names_of(e))),round(e['heading']/30))
        if k in seen: continue
        seen.add(k); reps.append(e)
    out=[]
    for u in reps:
        nm=str(u['edge_info'].get('names')); row=None; why="no usable anchors"; blocked_all=True
        for d in probe_mi:
            ab=anchor_pair(lat,lon,u,d)
            if not ab: why="road could not be traced"; continue
            r,w=measure(*ab,block)
            if r: r.update(road=nm,probe_mi=d,lanes=len(block)); row=r; break
            if w!="blocked": blocked_all=False
            why=w
        if row: out.append(row)
        elif blocked_all and why=="blocked":
            out.append({"road":nm,"verdict":"NO DETOUR","why":"no way around within 8 mi, deck available"})
        else: out.append({"road":nm,"verdict":"UNMEASURED","why":why})
    return {"beneath":out,"lanes_blocked":len(block),"deck_left_open":len(mine)}

def bypass_v3(lat,lon,L_ft,W_ft,pad_ft=75,tries=(0,150,400,900,2000)):
    """road ON the bridge; only the deck is blocked, the road below stays open."""
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if not mine: return {"verdict":"UNMEASURED","why":"no deck for this structure in the road graph"}
    dh=mine[0]['heading']; block=[corr(e) for e in mine]
    under_open=len(split_under(mine,ground))
    why="no usable anchors"; blocked_all=True
    for extra in tries:
        half=(L_ft/2.0+pad_ft+extra)*M_PER_FT
        A=dest(lat,lon,dh,+half); B=dest(lat,lon,dh,-half)
        r,w=measure(A,B,block)
        if r: r.update(pad_ft=pad_ft+extra,under_open=under_open); return r
        if w!="blocked": blocked_all=False
        why=w
    if blocked_all: return {"verdict":"NO DETOUR","why":"the far side is reachable only over this bridge","under_open":under_open}
    return {"verdict":"UNMEASURED","why":why}

def pt_seg_m(p,a,b):
    """distance from p to segment ab, in metres, local flat approximation"""
    la=math.radians((a[0]+b[0])/2)
    kx=111320.0*math.cos(la); ky=110540.0
    px,py=(p[1]-a[1])*kx,(p[0]-a[0])*ky
    bx,by=(b[1]-a[1])*kx,(b[0]-a[0])*ky
    d2=bx*bx+by*by
    t=0.0 if d2==0 else max(0.0,min(1.0,(px*bx+py*by)/d2))
    dx,dy=px-t*bx,py-t*by
    return math.sqrt(dx*dx+dy*dy)

def dist_to_path(p,shape):
    if len(shape)<2: return min((hav(p,q) for q in shape),default=1e9)
    return min(pt_seg_m(p,shape[i],shape[i+1]) for i in range(len(shape)-1))

def passes_through(shape,pts,tol_m=35):
    return min((dist_to_path(p,shape) for p in pts),default=1e9)<=tol_m

# ---- one routine, two modes ----------------------------------------------
# The only difference between the two measurements is what is blocked and
# which road you walk along. Everything else - anchors, validity, verdict -
# is shared.

def _trace(lat,lon,e,reach_mi=12,cache={}):
    h=e['heading']; key=(round(corr(e)[0],6),round(corr(e)[1],6),round(h),reach_mi)
    if key not in cache:
        f=route_shape(corr(e),dest(lat,lon,h,reach_mi*1609.34))
        b=route_shape(dest(lat,lon,(h+180)%360,reach_mi*1609.34),corr(e))
        cache[key]=None if ('err' in f or 'err' in b) else (f['shape'],cum(f['shape']),
                                                            b['shape'][::-1],cum(b['shape'][::-1]))
    return cache[key]

def walk_anchors(lat,lon,e,d_mi):
    t=_trace(lat,lon,e)
    if not t: return None
    fs,fc,bs,bc=t; m=d_mi*1609.34
    if m>fc[-1] or m>bc[-1]: return None
    return at_dist(bs,bc,m), at_dist(fs,fc,m)

def detour_for(road,block,lat,lon,probes):
    """walk outward along `road` until a validated detour around `block` appears"""
    why="no usable anchors"; all_blocked=True; tried=False
    for d in probes:
        ab=walk_anchors(lat,lon,road,d)
        if not ab: why="road could not be traced"; continue
        tried=True
        r,w=measure(*ab,block)
        if r: r.update(probe_mi=d); return r
        if w!="blocked": all_blocked=False
        why=w
    if tried and all_blocked:
        return {"verdict":"NO DETOUR","why":"no way around within %g mi"%probes[-1]}
    return {"verdict":"UNMEASURED","why":why}

def detour_both(lat,lon,L_ft,W_ft):
    mine,ground,poly=deck_and_obstruction(lat,lon,L_ft,W_ft)
    if not mine: return {"err":"no deck for this structure in the road graph"}
    unders=split_under(mine,ground)
    deck_block=[corr(e) for e in mine]
    und_block=[corr(e) for e in unders]
    res={"on":None,"under":[]}
    # road ON the bridge: the deck is gone, the road below stays open
    res["on"]=detour_for(mine[0],deck_block,lat,lon,(0.05,0.1,0.25,0.5,1,2,4))
    res["on"]["under_left_open"]=len(unders)
    # road UNDER: the ground under the span is gone, the deck stays usable
    reps=[];seen=set()
    for e in sorted(unders,key=lambda x:x['distance']):
        k=(str(sorted(names_of(e))),round(e['heading']/30))
        if k in seen: continue
        seen.add(k); reps.append(e)
    for u in reps:
        r=detour_for(u,und_block,lat,lon,(0.1,0.25,0.5,1,2,4,8))
        r["road"]=str(u['edge_info'].get('names') or ['(ramp / unnamed)'])
        r["lanes_blocked"]=len(und_block); r["deck_left_open"]=len(mine)
        res["under"].append(r)
    return res

def walk_anchors2(lat,lon,e,d_mi):
    """trace only as far as needed, so the traced path stays on this road"""
    t=_trace(lat,lon,e,reach_mi=max(1.0,round(d_mi*3,2)))
    if not t: return None
    fs,fc,bs,bc=t; m=d_mi*1609.34
    if m>fc[-1] or m>bc[-1]: return None
    return at_dist(bs,bc,m), at_dist(fs,fc,m)

def detour_for2(road,block,lat,lon,probes):
    why="no usable anchors"; all_blocked=True; tried=False
    for d in probes:
        ab=walk_anchors2(lat,lon,road,d)
        if not ab: why="road could not be traced"; continue
        tried=True
        r,w=measure(*ab,block)
        if r: r.update(probe_mi=d); return r
        if w!="blocked": all_blocked=False
        why=w
    if tried and all_blocked: return {"verdict":"NO DETOUR","why":"no way around within %g mi"%probes[-1]}
    return {"verdict":"UNMEASURED","why":why}
