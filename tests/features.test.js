/* Feature-level records, and the guard that has to come first.

   Two questions, and the second one is why the first is hard.

   Can the tool tell a road passing BENEATH a structure from a road running
   ALONGSIDE it on a sister deck? NCDOT publishes bridges as points, so every
   spatial test is a buffer, and twin decks sit 40 to 120 ft apart — inside the
   150 ft radius the resolver has always used. Mecklenburg alone holds 122 such
   pairs.

   And can it then express a structure as a set of features rather than a row?
   590819 carries I-85 in both directions on one 156 ft deck and spans three
   roadways. Five features, five sets of BH06/BH07, one bridge number.

   Every endpoint is mocked from geometry captured off NCDOT's live services. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FX=JSON.parse(fs.readFileSync('tests/fx/features.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');

const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

const TWIN={a:'590668',b:'590669'};          /* NC-51 NBL / SBL, 51 ft apart, both over US-74 */
const CROSS=['20000074060','20600074060'];   /* US-74, the road genuinely beneath both */
const CARRIED={'590668':'30000051060','590669':'30400051060'};

const mk=async(b)=>{
  const ctx=await b.newContext({viewport:{width:1600,height:1000}});
  const p=await ctx.newPage();
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/cdn.jsdelivr.net/**',r=>r.fulfill({contentType:'application/javascript',
    body:fs.readFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js','utf8')}));
  await p.route('**/*.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/gis11.services.ncdot.gov/**',async route=>{
    const req=route.request(), u=req.url();
    const pp=new URLSearchParams(req.postData()||''), par=new URLSearchParams(u.split('?')[1]||'');
    const g=pp.get('geometry')||par.get('geometry')||'';
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('Bridges/MapServer/0/query')){
      const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
      return J(off>0?{features:[]}:FX.bridges);
    }
    if(u.includes('RoadCharacteristics')){
      /* the point query the guard makes: serve whichever structure it is standing on */
      const m=/^(-?[\d.]+),(-?[\d.]+)$/.exec(g);
      if(m){
        const lon=+m[1], lat=+m[2];
        let best=null;
        FX.bridges.features.forEach(f=>{
          const a=f.attributes;
          const d=Math.hypot(a.LONG_DD-lon,a.LAT_DD-lat);
          if(best===null||d<best.d) best={d,bn:a.BRDG_NBR};
        });
        if(best&&best.d<0.002) return J(FX.road[best.bn]);
      }
      return J({features:[]});
    }
    return J({features:[]});
  });
  const snbiRows=FX.snbi.map(r=>Object.assign({},r));
  await sbmock(p,{bridges:FX.bridges, snbi:snbiRows});
  return {ctx,p};
};

/* the sbmock fixture serves Mecklenburg SNBI; this suite needs its own five rows */
const patchMock=()=>{
  const src=fs.readFileSync('tests/fx/sbmock.js','utf8');
  if(!/opts\.snbi/.test(src)) throw new Error('fx/sbmock.js needs an opts.snbi override');
};

(async()=>{
  patchMock();
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p.evaluate(()=>loadSNBI());
  await p.waitForTimeout(2500);

  console.log('\nFILE: '+FILE.split('/').pop());
  console.log('scope: '+await p.evaluate(()=>ALL.length)+' structures from the fixture');

  console.log('\n1. Twin pairs are detected and recorded on both rows');
  const tw=await p.evaluate(()=>{const n=twinScan();
    return {n, a:(ALL.find(b=>b.BRDG_NBR==='590668')._twins||[]),
               b:(ALL.find(b=>b.BRDG_NBR==='590669')._twins||[]),
               c:(ALL.find(b=>b.BRDG_NBR==='590819')._twins||[])};});
  ok('590668 knows about its sister',tw.a.map(x=>x.bn).join(),'590669');
  ok('and the relationship is recorded both ways',tw.b.map(x=>x.bn).join(),'590668');
  ok('separation measured',tw.a[0]&&tw.a[0].ft<80&&tw.a[0].ft>20,true);
  console.log('   590668 <-> 590669 at '+(tw.a[0]||{}).ft+' ft, routes '+CARRIED['590668']+' / '+CARRIED['590669']);
  ok('590819 is a single deck, not a pair',tw.c.length,0);

  console.log('\n2. The deck footprint, not a radius');
  const fp=await p.evaluate(()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590668');
    const dim=deckDims(b);
    return {len:dim.len,wid:dim.wid,skew:dim.skew,have:dim.have};});
  console.log('   590668 deck '+fp.len+' x '+fp.wid+' ft, skew '+fp.skew+'deg');
  ok('dimensions came through the SNBI join',fp.have,true);
  ok('a skew of 0 predicts a crossing at 90 degrees',
     await p.evaluate(()=>expectedCrossing(0)),90);
  ok('...and a skew of 70 predicts one at 20, not a rejection',
     await p.evaluate(()=>expectedCrossing(70)),20);

  console.log('\n3. Each structure returns the crossing road, neither returns the other\'s');
  await p.evaluate(()=>deriveFeatures(ALL.filter(b=>['590668','590669','590819'].includes(b.BRDG_NBR))));
  await p.waitForFunction(()=>{const b=ALL.find(x=>x.BRDG_NBR==='590668');return b&&b._feat&&b._feat.length>1;},
    null,{timeout:60000});
  await p.waitForTimeout(600);
  const feat=bn=>p.evaluate(n=>{const b=ALL.find(x=>x.BRDG_NBR===n);
    return (b._feat||[]).map(f=>({des:f.des,loc:f.loc,rid:f.rid,name:f.name,primary:!!f.primary,
      angle:f.angle,expected:f.expected,conf:f.confidence,origin:f.origin}));},bn);
  const fa=await feat('590668'), fb=await feat('590669');
  console.log('   590668: '+fa.map(f=>f.des+' '+f.loc+' '+(f.rid||'-')).join('  |  '));
  console.log('   590669: '+fb.map(f=>f.des+' '+f.loc+' '+(f.rid||'-')).join('  |  '));
  ok('590668 finds US-74 beneath it',
     fa.some(f=>f.loc==='B'&&CROSS.includes(f.rid)),true);
  ok('590669 finds US-74 beneath it too',
     fb.some(f=>f.loc==='B'&&CROSS.includes(f.rid)),true);
  ok('590668 does NOT take its sister\'s carried route',
     fa.some(f=>f.rid===CARRIED['590669']),false);
  ok('590669 does NOT take its sister\'s carried route',
     fb.some(f=>f.rid===CARRIED['590668']),false);

  console.log('\n4. The shared road beneath is not deduplicated');
  const shared=await p.evaluate(()=>{
    const g=n=>(ALL.find(x=>x.BRDG_NBR===n)._feat||[]).filter(f=>f.loc==='B').map(f=>f.rid);
    return {a:g('590668'),b:g('590669')};});
  const both=shared.a.filter(r=>shared.b.includes(r));
  ok('the same road is a feature of both structures',both.length>0,true);
  console.log('   shared beneath: '+both.join(', '));
  ok('and it is not flagged as a duplicate pair',
     await p.evaluate(()=>{
       const f=(ALL.find(x=>x.BRDG_NBR==='590668')._feat||[]).find(x=>x.loc==='B');
       return (f&&f.flags||[]).includes('DUPLICATE_PAIR');}),false);

  console.log('\n5. 590819 — two carried roadways on one deck, three beneath');
  const f819=await feat('590819');
  f819.forEach(f=>console.log('   '+f.des+'  '+f.loc+'  '+(f.rid||'—')+
    (f.angle!=null?'   crosses at '+f.angle+'° (skew predicts '+f.expected+'°)':'   published')+
    '   '+(f.name||'')));
  ok('I-85 southbound is recognised as CARRIED, not as a road beneath',
     (f819.find(f=>f.rid==='10400085060')||{}).loc,'C');
  ok('both I-485 carriageways are beneath',
     ['10800485060','10900485060'].every(r=>f819.some(f=>f.rid===r&&f.loc==='B')),true);
  ok('carried features are numbered before below features',
     f819.filter(f=>f.loc==='C').every(c=>f819.filter(f=>f.loc==='B').every(u=>c.des<u.des)),true);
  ok('H01 is the published carried feature',
     (f819[0]||{}).des+' '+(f819[0]||{}).loc,'H01 C');
  ok('exactly one primary carried feature',f819.filter(f=>f.loc==='C'&&f.primary).length,1);

  console.log('\n6. Route designations restart at R01 inside every feature');
  const routes=await p.evaluate(()=>{const b=ALL.find(x=>x.BRDG_NBR==='590819');
    return (b._feat||[]).map(f=>({des:f.des,r:(f.routes||[]).map(x=>x.des)}));});
  routes.forEach(r=>console.log('   '+r.des+' -> '+r.r.join(', ')));
  ok('every feature starts at R01',routes.every(r=>r.r[0]==='R01'),true);
  ok('no feature reuses a designation from another',
     routes.every(r=>new Set(r.r).size===r.r.length),true);

  console.log('\n7. Concurrency stays one feature with several route records');
  const conc=await p.evaluate(()=>{const b=ALL.find(x=>x.BRDG_NBR==='590207');
    const f=(b._feat||featuresOf(b));
    return {carried:f.filter(x=>x.loc==='C').length, routes:(f[0].routes||[]).map(r=>r.des+'='+r.num),
            text:b.F_CARRIED};});
  console.log('   '+conc.text+'  ->  '+conc.routes.join('  '));
  ok('co-signed routes give ONE carried feature',conc.carried,1);
  ok('...and two route records under it',conc.routes.length,2);

  console.log('\n8. BH06-4 cites which condition excludes the value');
  const b4=await p.evaluate(()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590668');
    const u=(b._feat||[]).find(f=>f.loc==='B');
    if(u) u.rid='20000074060';
    const before=(function(){validateFeature(b,u);return (u.flags||[]).slice();})();
    const c=(b._feat||[]).find(f=>f.loc==='C'&&f.primary);
    c.onBridge='590669'; validateFeature(b,c);
    return {below:before, carried:(c.flags||[])};});
  ok('a BH06 on a below feature is excluded by B.F.02',b4.below.includes('BH06_4_BELOW'),true);
  ok('a BH06 where B.H.18 names another bridge is a different finding',
     b4.carried.includes('BH06_4_ONBRIDGE'),true);
  ok('the two are not the same rule',
     await p.evaluate(()=>RULEMAP.BH06_4_BELOW.d!==RULEMAP.BH06_4_ONBRIDGE.d),true);
  ok('the old merged rule is gone',await p.evaluate(()=>!RULEMAP.BH06_4_REDUNDANT),true);
  console.log('   B.F.02: '+await p.evaluate(()=>RULEMAP.BH06_4_BELOW.t));
  console.log('   B.H.18: '+await p.evaluate(()=>RULEMAP.BH06_4_ONBRIDGE.t));

  console.log('\n9. The drawer expands features under the structure');
  await p.evaluate(()=>select('590819',false));
  await p.waitForTimeout(800);
  const drawer=await p.evaluate(()=>document.getElementById('dr-body').innerText);
  ok('the feature list is drawn',/features/i.test(drawer),true);
  ok('every designation appears',['H01','H02','H03','H04'].every(d=>drawer.includes(d)),true);
  ok('carried and below are labelled',/carried on bridge/i.test(drawer)&&/below bridge/i.test(drawer),true);
  ok('the bridge number is still the row key',
     await p.evaluate(()=>document.querySelectorAll('#tscroll tbody tr').length>0),true);
  await p.evaluate(()=>select('590668',false));
  await p.waitForTimeout(600);
  const d2=await p.evaluate(()=>document.getElementById('dr-body').innerText);
  ok('a sister pair is disclosed rather than silently excluded',/sister pair/i.test(d2),true);
  ok('...naming the other structure',/590669/.test(d2),true);

  console.log('\n10. resolveCarried no longer offers a sister\'s route as a correction');
  const rc=await p.evaluate(async()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590669');
    const naive=neighbourCarrying(b,'30000051060');
    return {ruledBy:naive};});
  ok('590668 is identified as the carrier of 30000051060',rc.ruledBy,'590668');
  console.log('   so the resolver drops it from the candidate list before choosing.');

  console.log('\n11. Missing deck dimensions degrade to review, not to silence');
  const lc=await p.evaluate(()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590668');
    const saved=b._snbi;
    b._snbi=Object.assign({},saved,{structure_length:null,bridge_deck_width:null,fed_skew:null});
    const ctx=deckContext(b,[]);
    const out={have:ctx.have};
    b._snbi=saved;
    return out;});
  ok('with no dimensions the footprint test cannot run',lc.have,false);
  ok('and anything admitted that way is marked low confidence',
     await p.evaluate(()=>RULEMAP.FEATURE_LOW_CONF.sev),'i');

  console.log('\n12. The 590819 report\'s own numbering is flagged, not reproduced');
  /* B.F.01 / B.RT.01 exactly as the 24 Sep 2025 inspection report prints them:
     five features numbered H01..H05 with a carried roadway last, and route
     designations running R01..R05 straight through instead of restarting. */
  const rep=await p.evaluate(()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    b._feat=[
      {des:'H01',reportedDes:'H01',loc:'C',primary:true,name:'I85NBL',rid:'10085',mp:30.100,
       origin:'report',routes:[{des:'R01',reportedDes:'R01',num:'I85NBL',dir:'NB'}]},
      {des:'H02',reportedDes:'H02',loc:'B',primary:true,name:'I485N',rid:'10485',mp:10.000,
       origin:'report',routes:[{des:'R01',reportedDes:'R02',num:'485',dir:'NB'}]},
      {des:'H03',reportedDes:'H03',loc:'B',name:'I485S',rid:'10485',mp:10.000,
       origin:'report',routes:[{des:'R01',reportedDes:'R03',num:'485',dir:'SB'}]},
      {des:'H04',reportedDes:'H04',loc:'B',name:'I485S RAMP',rid:'',mp:10.000,
       origin:'report',routes:[{des:'R01',reportedDes:'R04',num:'485',dir:'SB'}]},
      {des:'H05',reportedDes:'H05',loc:'C',name:'I85SBL',rid:'10085',mp:null,
       origin:'report',routes:[{des:'R01',reportedDes:'R05',num:'I85SBL',dir:'SB'}]}];
    rollUpFeatures(b);
    return {struct:b._struct||[], flags:b._feat.map(f=>({des:f.des,loc:f.loc,sev:f.sev,flags:f.flags}))};});
  console.log('   structure findings: '+rep.struct.join(', '));
  ok('a carried feature after a below feature is flagged',rep.struct.includes('FEATURE_ORDER'),true);
  ok('route designations that ran on are flagged',
     rep.struct.includes('ROUTE_DESIGNATION_CONTINUOUS'),true);
  ok('two features resolving to the same route are flagged',
     rep.struct.includes('CONCURRENCY_SPLIT'),true);
  rep.flags.forEach(f=>console.log('   '+f.des+' '+f.loc+' ['+f.sev+']  '+(f.flags||[]).join(', ')));
  ok('H01 BH06 is not an 11-digit LRS ID',
     (rep.flags[0].flags||[]).includes('BAD_FORMAT'),true);
  ok('H05 carried with no milepoint fails BH07-1',
     (rep.flags[4].flags||[]).includes('BH07_1_NUM'),true);
  ok('the below features that DO carry a BH06 are excluded by B.F.02',
     rep.flags.filter(f=>f.loc==='B'&&(f.flags||[]).includes('BH06_4_BELOW')).length,2);
  ok('...and the one with no BH06 at all is not accused of reporting one',
     (rep.flags[3].flags||[]).includes('BH06_4_BELOW'),false);

  console.log('\n13. Clicking a bridge shows its features, with no batch pass first');
  const {p:p2}=await mk(b);
  const e2=[]; p2.on('pageerror',e=>e2.push(e.message));
  p2.on('dialog',d=>d.accept(''));
  await p2.goto('file://'+FILE); await p2.waitForTimeout(2200);
  await p2.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  await p2.selectOption('#mode','county'); await p2.waitForTimeout(300);
  await p2.selectOption('#arg','MECKLENBURG'); await p2.click('#run');
  await p2.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p2.evaluate(()=>loadSNBI()); await p2.waitForTimeout(2000);
  ok('before opening it, only the published feature is known',
     await p2.evaluate(()=>(ALL.find(x=>x.BRDG_NBR==='590819')._feat||[]).length||1),1);
  await p2.evaluate(()=>select('590819',true));
  await p2.waitForFunction(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');return x&&x._featDone;},
    null,{timeout:40000});
  await p2.waitForTimeout(500);
  const auto=await p2.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
    return {n:(x._feat||[]).length, c:(x._feat||[]).filter(f=>f.loc==='C').length,
            u:(x._feat||[]).filter(f=>f.loc==='B').length,
            txt:document.getElementById('dr-body').innerText};});
  ok('opening it measured the rest',auto.n>1,true);
  console.log('   '+auto.c+' carried, '+auto.u+' below, without touching Expand features');
  ok('...and the panel shows them',/below bridge/i.test(auto.txt),true);
  ok('the count in the header is right',
     new RegExp(auto.c+' carried').test(auto.txt.replace(/\u00b7/g,'·')),true);
  ok('a second open does not measure again',
     await p2.evaluate(async()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
       const n=(x._feat||[]).length; select('590819',true);
       await new Promise(r=>setTimeout(r,600));
       return (x._feat||[]).length===n;}),true);

  console.log('\n14. The pin drop is a measurement, not the bridge\'s BH06');
  const pin=await p2.evaluate(()=>{
    const src=document.documentElement.innerHTML;
    return {oldLabel:/BH06 LRS Route ID<\/div>/.test(src)};});
  ok('the popup no longer calls its answer "BH06 LRS Route ID"',pin.oldLabel,false);
  const src2=fs.readFileSync(FILE,'utf8');
  ok('it says what it actually is',/The road at this point/.test(src2),true);
  ok('...and names the feature when the road is one of the open bridge\'s',
     /this road is feature/i.test(src2),true);

  console.log('\npage errors: '+JSON.stringify(errs.concat(e2)));
  await b.close();
})();
