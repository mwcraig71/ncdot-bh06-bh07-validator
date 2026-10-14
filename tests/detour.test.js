/* Detour length — B.H.17 as NCDOT publishes it, beside the detour as measured.

   The claim being tested is not "a detour appears". It is that the coded value
   and the measured one are shown as two different things and allowed to
   disagree in plain view; that a structure the statewide run did not reach,
   or could not measure, says so and is never shown as a zero-mile detour; and
   that the findings fire exactly where the road network's answer contradicts
   the code — a dead end coded with a detour, a "no detour" with a way around,
   a "bypass at the site" with miles to go — and nowhere else.

   B.H.17 is read in MILES. Measured against 15,385 bridges, culverts and
   pipes, the miles reading is the closer one on 89% of them, and from code 10
   upward the median measured/coded ratio is 1.03.

   Every endpoint is mocked. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FX=JSON.parse(fs.readFileSync('tests/fx/features.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');
const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

const I85='10000085060';      /* 590819 carries this */
const V='OSM north-carolina-261012';

/* What NCDOT codes for each fixture structure. */
const CODED={'590819':'2', '590207':'99', '590213':'1', '590668':'0', '590669':'12'};

/* What the road network says. 590669 is deliberately absent: it was not in
   the run, and must not read as a measurement of anything. */
const DETOUR=()=>[
  /* agrees with its code: no finding */
  {brdg_nbr:'590819',mode:'bypass',seq:0,road:'I 85 North',heading:56,verdict:'ok',
   around_mi:2.0,direct_mi:0.14,additional_mi:1.86,probe_mi:0.05,reason:null,
   width_assumed:false,deck_inferred:false,graph_vintage:V},
  {brdg_nbr:'590819',mode:'collapse',seq:0,road:'I 485 Inner',heading:150,verdict:'ok',
   around_mi:3.1,direct_mi:1.8,additional_mi:1.3,probe_mi:1,reason:null,
   width_assumed:false,deck_inferred:false,graph_vintage:V},
  {brdg_nbr:'590819',mode:'collapse',seq:1,road:'I 485 Outer',heading:330,verdict:'no_detour',
   around_mi:null,direct_mi:null,additional_mi:null,probe_mi:null,
   reason:'no way around within 8 mi',width_assumed:false,deck_inferred:false,graph_vintage:V},
  /* coded 99, "no detour" — but there is a way around */
  {brdg_nbr:'590207',mode:'bypass',seq:0,road:'I 77',heading:10,verdict:'ok',
   around_mi:4.4,direct_mi:0.2,additional_mi:4.2,probe_mi:0.05,reason:null,
   width_assumed:false,deck_inferred:false,graph_vintage:V},
  {brdg_nbr:'590207',mode:'collapse',seq:0,road:null,heading:null,verdict:'none_beneath',
   around_mi:null,direct_mi:null,additional_mi:null,probe_mi:null,
   reason:'NCDOT records no highway beneath (service under: Waterway)',
   width_assumed:false,deck_inferred:false,graph_vintage:V},
  /* coded 1 mile — but the far side is reachable only over this bridge */
  {brdg_nbr:'590213',mode:'bypass',seq:0,road:'Old Road',heading:90,verdict:'no_detour',
   around_mi:null,direct_mi:null,additional_mi:null,probe_mi:null,
   reason:'the far side is reachable only over this bridge (dead end)',
   width_assumed:false,deck_inferred:true,graph_vintage:V},
  /* coded 0, "bypass at the site" — but closing it costs 3 miles; and the road
     beneath could not be measured, which must say why rather than show a number */
  {brdg_nbr:'590668',mode:'bypass',seq:0,road:'NC 51',heading:170,verdict:'ok',
   around_mi:3.3,direct_mi:0.2,additional_mi:3.1,probe_mi:0.1,reason:null,
   width_assumed:true,deck_inferred:false,graph_vintage:V},
  {brdg_nbr:'590668',mode:'collapse',seq:0,road:'US 74',heading:80,verdict:'unmeasured',
   around_mi:null,direct_mi:null,additional_mi:null,probe_mi:null,
   reason:'the open path does not use the blocked span',
   width_assumed:true,deck_inferred:false,graph_vintage:V},
];

let PINRID=I85, PINMP=2.672;

const mk=async(b,opts={})=>{
  const ctx=await b.newContext({viewport:{width:1600,height:1000}});
  const p=await ctx.newPage();
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  const bridges=JSON.parse(JSON.stringify(FX.bridges));
  bridges.features.forEach(f=>{ const n=String(f.attributes.BRDG_NBR).trim();
    if(n in CODED) f.attributes.DETOUR_LEN=CODED[n]; });
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
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('Bridges/MapServer/0/query')){
      const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
      return J(off>0?{features:[]}:bridges); }
    if(u.includes('RoadCharacteristics')) return J({features:[]});
    if(u.includes('submitJob')) return J({jobId:'j1',jobStatus:'esriJobSubmitted'});
    if(/\/jobs\/j1\?/.test(u)) return J({jobId:'j1',jobStatus:'esriJobSucceeded'});
    if(u.includes('IdentifyRouteMPResults')) return J({value:{features:[{attributes:
      {RID:PINRID, MEAS:PINMP, RouteName:'I-85', StreetName:'I-85 N'}}]}});
    return J({features:[]});
  });
  const m=await sbmock(p,Object.assign({bridges, snbi:FX.snbi.map(x=>Object.assign({},x)),
    detour:DETOUR()},opts));
  return {ctx,p,m};
};

const boot=async p=>{
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);
  await p.evaluate(()=>{['autoheavy','autohpms','autotraffic'].forEach(id=>{
    const e=document.getElementById(id); if(e) e.checked=false;});});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  /* Run all reads the detour lengths for the scope on its own */
  await p.waitForFunction(()=>ALL.every(b=>DETOURASKED.has(bnKey(b))),null,{timeout:60000});
  await p.waitForTimeout(800);
};

const fields=l=>{const out=[];let cur='',q=false;
  for(let i=0;i<l.length;i++){const c=l[i];
    if(c==='"'){ if(q&&l[i+1]==='"'){cur+='"';i++;} else q=!q; }
    else if(c===','&&!q){ out.push(cur); cur=''; }
    else cur+=c; }
  out.push(cur); return out;};

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p,m}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('dialog',d=>d.accept(''));
  await boot(p);
  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. The measurements are read for the structures on screen, once');
  const reads=m.reads('detour_measured');
  ok('Run all reads the detour table without being asked',reads.length>0,true);
  ok('...by structure number, never wholesale',
     reads.every(r=>/brdg_nbr=in\./.test(r.url)),true);
  ok('...asking about exactly the structures in scope',
     await p.evaluate(()=>ALL.length),reads.reduce((n,r)=>n+(decodeURIComponent(r.url).match(/"\d{6}"/g)||[]).length,0));
  const before=m.reads('detour_measured').length;
  await p.evaluate(()=>detourCheck(null,true)); await p.waitForTimeout(500);
  ok('...and a second pass asks for nothing it already holds',m.reads('detour_measured').length,before);

  console.log('\n2. B.H.17 is decoded, and its special codes say what they mean');
  const dec=await p.evaluate(()=>[0,'2','99','199','',null,'x'].map(v=>bh17({DETOUR_LEN:v})));
  ok('0 is a bypass at the site',dec[0].kind+' / '+dec[0].label,'site / 0 — a bypass at the site');
  ok('a number is miles',dec[1].kind+' / '+dec[1].label,'miles / 2 mi');
  ok('99 is NCDOT’s no-detour code',dec[2].kind,'none');
  ok('199 is reported as a code, not as 199 miles',dec[3].kind,'special');
  ok('blank is "not coded", never zero',dec[4].code===null&&dec[5].code===null&&dec[4].label==='not coded',true);
  ok('a non-number is not silently turned into one',dec[6].code===null,true);
  ok('DETOUR_LEN is requested from the bridge layer',
     await p.evaluate(()=>BFIELDS.split(',').includes('DETOUR_LEN')),true);

  console.log('\n3. The findings fire where the road network contradicts the code, and only there');
  const fl=await p.evaluate(()=>Object.fromEntries(ALL.map(b=>[b.BRDG_NBR,
    b._flags.filter(f=>f.indexOf('DETOUR_')===0)])));
  console.log('   '+JSON.stringify(fl));
  ok('590819: coded 2, measured 1.86 — agreement raises nothing',fl['590819'].length,0);
  ok('590207: coded 99, but a way around exists',fl['590207'].join(),'DETOUR_99_MEASURED');
  ok('590213: coded 1 mile, but the bridge is the only way across',fl['590213'].join(),'DETOUR_CODED_DEAD_END');
  ok('590668: coded "bypass at the site", but 3.1 miles to go',fl['590668'].join(),'DETOUR_0_LONG');
  ok('590669: not in the run — nothing to contradict, so nothing is claimed',fl['590669'].length,0);
  ok('the three contradictions are warnings',
     await p.evaluate(()=>['DETOUR_CODED_DEAD_END','DETOUR_99_MEASURED','DETOUR_0_LONG']
       .every(id=>RULEMAP[id].sev==='w'&&RULEMAP[id].grp==='qc')),true);
  ok('...and they reach the checklist counts',
     await p.evaluate(()=>{renderChecks();
       const c={}; ALL.forEach(b=>(b._eff||b._flags).forEach(f=>{c[f]=(c[f]||0)+1;}));
       return [c.DETOUR_99_MEASURED,c.DETOUR_CODED_DEAD_END,c.DETOUR_0_LONG].join();}),'1,1,1');
  /* A plain mismatch is a note, not a warning: from code 10 up the two agree to
     a median within 3%, so only a large gap is worth raising - and quietly. */
  await p.evaluate(()=>{ALL.find(x=>x.BRDG_NBR==='590819').DETOUR_LEN='8'; revalidate();});
  ok('coded 8, measured 1.86 — more than half and 5 miles off — is a note',
     await p.evaluate(()=>ALL.find(x=>x.BRDG_NBR==='590819')._flags.filter(f=>f.indexOf('DETOUR_')===0).join()),
     'DETOUR_FAR_OFF');
  ok('...whose severity is a note, so it colours nothing',
     await p.evaluate(()=>RULEMAP.DETOUR_FAR_OFF.sev),'i');
  await p.evaluate(()=>{ALL.find(x=>x.BRDG_NBR==='590819').DETOUR_LEN='5'; revalidate();});
  ok('coded 5, measured 1.86 — under 5 miles apart — raises nothing',
     await p.evaluate(()=>ALL.find(x=>x.BRDG_NBR==='590819')._flags.filter(f=>f.indexOf('DETOUR_')===0).length),0);
  await p.evaluate(()=>{ALL.find(x=>x.BRDG_NBR==='590819').DETOUR_LEN='2'; revalidate();});

  console.log('\n4. The panel shows the code and the measurement as two things');
  const t819=await p.evaluate(()=>{select('590819',true); return document.getElementById('dr-body').innerText;});
  ok('a Detour length section, named for B.H.17',/Detour length.{0,4}B\.H\.17/i.test(t819),true);
  ok('NCDOT’s coded value, in miles',/NCDOT coded\s*2 mi/i.test(t819),true);
  ok('headed "Calculated detour length": the extra miles with the deck closed',
     /Calculated detour length\s*1\.9 mi extra/i.test(t819),true);
  ok('...and the trip in plain words, measured from the ends of the bridge',
     /Normally 0\.1 mi from one end of the bridge to the other; 2\.0 mi with it closed\./.test(t819),true);
  ok('...never called "straight across": the measured trip is not the bridge',/straight across/i.test(t819),false);
  ok('the structure’s own length is not repeated here: it is not part of the measurement',
     /The structure itself is/.test(t819),false);
  const t819far=await p.evaluate(()=>{const d=DETOUR.get('590819'); const o=d.bypass;
    d.bypass=Object.assign({},o,{probe_mi:0.5,direct_mi:1.001,around_mi:5.537,additional_mi:4.535});
    select('590819',true); const t=document.getElementById('dr-body').innerText; d.bypass=o; return t;});
  ok('a divided road measured from half a mile out says why, and where the trip starts and ends (as 590141)',
     /4\.5 mi extra[\s\S]{0,40}No way off the road near the bridge, so the trip is measured from half a mile before it to half a mile past it: normally 1\.0 mi, 5\.5 mi with the bridge closed\./i.test(t819far),true);
  ok('each road beneath is headed "Calculated detour length, road beneath"',
     (t819.match(/Calculated detour length, road beneath/gi)||[]).length,2);
  ok('...and its trip is told for the road closed under the bridge',
     /from 1 mi before it to 1 mi past it: normally 1\.8 mi, 3\.1 mi with the road closed under the bridge\./.test(t819),true);
  ok('"Road on the bridge" is gone as a heading',/Road on the bridge/i.test(t819),false);
  ok('each road beneath has its own line, by name',/I 485 Inner/.test(t819)&&/I 485 Outer/.test(t819),true);
  ok('...and a dead end beneath says so, with its reason',/No detour[\s\S]{0,40}no way around within 8 mi/.test(t819),true);
  ok('the graph it was measured on is named',t819.includes(V),true);
  ok('...and what it does not check is said',/nothing on the way around is checked for clearance, posting or width/.test(t819),true);

  const t213=await p.evaluate(()=>{select('590213',true); return document.getElementById('dr-body').innerText;});
  ok('a dead end reads "No detour", not a number',/Calculated detour length\s*No detour/i.test(t213),true);
  ok('...the finding sits with the structure’s QC findings',/B\.H\.17 gives a detour, but there is no other way across/.test(t213),true);

  const t668=await p.evaluate(()=>{select('590668',true); return document.getElementById('dr-body').innerText;});
  ok('an unmeasured road beneath says "Not measured" and why',
     /Not measured[\s\S]{0,40}the open path does not use the blocked span/.test(t668),true);
  ok('an assumed deck width is disclosed',/deck width assumed \(30 ft\)/.test(t668),true);

  const t669=await p.evaluate(()=>{select('590669',true); return document.getElementById('dr-body').innerText;});
  ok('a structure outside the run says so',/not measured.{0,6}this structure was not in the statewide run/.test(t669),true);
  ok('...while its coded value still shows',/NCDOT coded\s*12 mi/i.test(t669),true);

  const t207=await p.evaluate(()=>{select('590207',true); return document.getElementById('dr-body').innerText;});
  ok('no highway beneath is NCDOT’s answer, and is attributed to NCDOT',
     /NCDOT records no highway beneath \(service under: Waterway\)/.test(t207),true);

  console.log('\n5. The table: two columns, numeric, filterable, sortable');
  const cells=await p.evaluate(()=>Object.fromEntries(ALL.map(b=>[b.BRDG_NBR,
    cellText(b,'_bh17')+' | '+cellText(b,'_detour')])));
  console.log('   '+JSON.stringify(cells));
  ok('coded and measured side by side',cells['590819'],'2 | 1.9');
  ok('a dead end reads "none", not 0',cells['590213'],'1 | none');
  ok('a structure outside the run leaves the measured cell blank',cells['590669'],'12 | ');
  ok('the special codes are labelled in the cell',cells['590207'].startsWith('99 none'),true);
  ok('the measured column is numeric for filtering',
     await p.evaluate(()=>{COLF._detour='>3'; const r=ALL.filter(passesColumns).map(b=>b.BRDG_NBR).sort();
       delete COLF._detour; return r.join();}),'590207,590668');
  ok('"-" finds the ones with nothing measured',
     await p.evaluate(()=>{COLF._detour='-'; const r=ALL.filter(passesColumns).map(b=>b.BRDG_NBR).sort();
       delete COLF._detour; return r.join();}),'590213,590669');
  ok('sorting on it is numeric, not alphabetical',
     await p.evaluate(()=>{const ks=['590819','590207','590668'];
       VIEW=ALL.filter(b=>ks.includes(b.BRDG_NBR)); sortKey='_detour'; sortDir=1; sortView();
       const r=VIEW.map(b=>b.BRDG_NBR).join(); applyFilters(); return r;}),'590819,590668,590207');
  await p.evaluate(()=>{sortKey='BRDG_NBR'; sortDir=1; applyFilters();});

  console.log('\n6. The CSV carries the code, the measurement, and what each one is');
  const csv=await p.evaluate(()=>{let cap=null; const old=URL.createObjectURL;
    URL.createObjectURL=b=>{cap=b; return 'blob:x';}; exportCSV(); URL.createObjectURL=old;
    return cap? cap.text() : '';});
  const cols=fields(csv.split('\n')[0]);
  const rows=csv.split('\n').slice(1).filter(Boolean).map(fields);
  ok('the header and the rows still line up',rows.every(r=>r.length===cols.length),true);
  const row=bn=>rows.find(r=>r[0]===bn), at=(bn,c)=>row(bn)[cols.indexOf(c)];
  ok('B.H.17 as coded, with its meaning',at('590668','BH17_NCDOT_CODE')+' / '+at('590668','BH17_MEANING'),
     '0 / 0 — a bypass at the site');
  ok('the measured verdict travels with the number, and the route lengths with where they were measured',
     ['DETOUR_MEASURED','DETOUR_EXTRA_MI','DETOUR_MEASURED_EACH_SIDE_MI','DETOUR_ROUTE_OPEN_MI','DETOUR_ROUTE_CLOSED_MI']
       .map(c=>at('590819',c)).join(' '),'MEASURED 1.860 0.05 0.140 2.000');
  ok('no column is named "around" or "across" any longer',
     cols.some(c=>/AROUND|ACROSS|ADDITIONAL/.test(c)),false);
  ok('a dead end is NO DETOUR with blank distances, never 0',
     ['DETOUR_MEASURED','DETOUR_EXTRA_MI','DETOUR_MEASURED_EACH_SIDE_MI','DETOUR_ROUTE_OPEN_MI','DETOUR_ROUTE_CLOSED_MI']
       .map(c=>at('590213',c)).join('|'),'NO DETOUR||||');
  ok('...and its note says why, and that the deck was inferred',
     at('590213','DETOUR_NOTE'),'the far side is reachable only over this bridge (dead end); deck inferred');
  ok('a structure outside the run is NOT MEASURED',at('590669','DETOUR_MEASURED'),'NOT MEASURED');
  ok('every road beneath is summarised',at('590819','DETOUR_BENEATH'),'I 485 Inner: +1.30 mi; I 485 Outer: no detour');
  ok('the graph vintage is recorded on every measured row',at('590819','DETOUR_GRAPH'),V);
  ok('the findings are in the QC column',/no other way across/.test(at('590213','QC_FINDINGS')||row('590213').join('|')),true);

  console.log('\n7. The pin reads the detour for the road it lands on');
  PINRID=I85; PINMP=2.672;
  await p.evaluate(()=>{PINTARGET=null; select('590819',true);});
  await p.evaluate(()=>pinAt(35.24,-80.96));
  await p.waitForFunction(()=>!!document.querySelector('.leaflet-popup-content'),null,{timeout:30000});
  const pop=await p.evaluate(()=>document.querySelector('.leaflet-popup-content').innerText);
  console.log('   '+pop.replace(/\n+/g,' | ').slice(0,260));
  ok('BH06, BH07 and the AADT for the road here are the first three lines',
     /^THE ROAD AT THIS POINT\s*BH06 here\s*10000085060\s*BH07 here\s*2\.672\s*Traffic\s*/i.test(pop),true);
  ok('then the calculated detour for the bridge, named',/Calculated detour length · bridge 590819/.test(pop),true);
  ok('...the bridge closed, with NCDOT’s code beside it',
     /On the bridge\s*1\.9 mi extra · NCDOT codes 2 mi \(B\.H\.17\)/.test(pop),true);
  ok('...and every road beneath closed, both shown whichever road the pin landed on',
     /Road beneath\s*I 485 Inner: 1\.3 mi extra/.test(pop)&&/Road beneath\s*I 485 Outer: no detour/.test(pop),true);
  ok('the detour comes before the reading of the route',pop.indexOf('Calculated detour')<pop.indexOf('Route here'),true);
  const popB=await p.evaluate(()=>{const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const d=document.createElement('div'); d.innerHTML=detourPop(b,{loc:'B'}); return d.innerText;});
  ok('a pin on a road beneath shows the same two together',
     /On the bridge\s*1\.9 mi extra/.test(popB)&&/I 485 Inner: 1\.3 mi extra/.test(popB),true);
  ok('the popup is capped to the map’s height so it scrolls on a phone',
     await p.evaluate(()=>{const o=map._popup&&map._popup.options; return !!o&&o.maxHeight>=170&&o.maxHeight<=map.getSize().y;}),true);
  const near=await p.evaluate(async()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590819'); map.closePopup(); SEL=null; PINTARGET=null;
    await pinAt(Number(b.LAT_DD)+0.0003,Number(b.LONG_DD));
    const ps=[...document.querySelectorAll('.leaflet-popup-content')]; const t=ps[ps.length-1].innerText;
    const far=pinNearestStructure(Number(b.LAT_DD)+0.05,Number(b.LONG_DD),120);
    return {t,far:far&&far.BRDG_NBR};});
  ok('with no bridge open, the pin uses the nearest structure within 120 m, and says so',
     /bridge 590819 \(nearest to the pin\)/.test(near.t),true);
  ok('...and claims none when nothing is that close',near.far,null);
  ok('with no bridge open, the pin claims no detour at all',
     await p.evaluate(()=>detourPop(null,null)),'');
  ok('a structure outside the run adds nothing to the popup',
     await p.evaluate(()=>detourPop(ALL.find(x=>x.BRDG_NBR==='590669'),{loc:'C'})),'');

  console.log('\n7b. The pin finds NCDOT’s route/milepost tool after a rename');
  const gp=await p.evaluate(async()=>{
    const saveT=GPTOOL, saveOK=GPTOOL_OK, of=window.fetch, asked=[];
    GPTOOL=SVC+'/NCDOT_Tools/OldName/GPServer/Old%20Task'; GPTOOL_OK=false;
    window.fetch=async u=>{ asked.push(String(u)); const J=o=>new Response(JSON.stringify(o),{headers:{'content-type':'application/json'}});
      if(/OldName/.test(u)) return J({error:{code:400,message:'Service not found'}});
      if(/\/NCDOT_Tools\?f=json/.test(u)) return J({services:[{name:'NCDOT_Tools/Something',type:'MapServer'},
        {name:'NCDOT_Tools/IdentifyRouteMilepostUsingPointTool_v2',type:'GPServer'}]});
      if(/IdentifyRouteMilepostUsingPointTool_v2\/GPServer\?f=json/.test(u)) return J({tasks:['Identify Route Milepost Using Point Tool']});
      return J({}); };
    let url, url2, err=null;
    try{ url=await gpTool(); url2=await gpTool(); }catch(e){ err=e.message; }
    window.fetch=of; const n=asked.length; GPTOOL=saveT; GPTOOL_OK=saveOK;
    return {url, url2, err, n};});
  console.log('   '+JSON.stringify(gp));
  ok('a renamed service is found in the NCDOT_Tools folder, not reported as a pin failure',
     gp.url,'https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Tools/IdentifyRouteMilepostUsingPointTool_v2/GPServer/Identify%20Route%20Milepost%20Using%20Point%20Tool');
  ok('...and remembered, so the next pin does not look again',gp.n===3&&gp.url2===gp.url,true);
  const gpGone=await p.evaluate(async()=>{
    const saveT=GPTOOL, saveOK=GPTOOL_OK, of=window.fetch;
    GPTOOL=SVC+'/NCDOT_Tools/OldName/GPServer/Old%20Task'; GPTOOL_OK=false;
    window.fetch=async u=>new Response(JSON.stringify(/OldName/.test(u)?{error:{code:400}}:{services:[]}));
    let err=null; try{ await gpTool(); }catch(e){ err=e.message; }
    window.fetch=of; GPTOOL=saveT; GPTOOL_OK=saveOK; return err;});
  ok('if it has gone altogether, the message says so plainly',/not in its usual folder/.test(gpGone||''),true);

  console.log('\n7b2. When NCDOT’s tool fails, the pin reads its road layer instead');
  const fb=await p.evaluate(async()=>{
    const of=window.fetch, asked=[]; GP_DOWN=false;
    const lat=35.24, lon=-80.96, q=toStatePlane(lat,lon);
    window.fetch=async(u,o)=>{ u=String(u); asked.push(u.replace(/\?.*/,''));
      const J=x=>new Response(JSON.stringify(x),{headers:{'content-type':'application/json'}});
      if(/submitJob/.test(u)) return J({jobId:'jx',jobStatus:'esriJobSubmitted'});
      if(/\/jobs\/jx\?/.test(u)) return J({jobId:'jx',jobStatus:'esriJobFailed',
        messages:[{type:'esriJobMessageTypeError',description:'SDE Connection file not found'}]});
      if(/RoadCharacteristicsQtr\/MapServer\/0\/query/.test(u)) return J({features:[
        {attributes:{RouteID:'10000085060',RouteName:'I-85',StreetName:'I-85 N'},
         geometry:{paths:[[[q.x-1000,q.y+20,2.0],[q.x+1000,q.y+20,2.4]]]}},
        {attributes:{RouteID:'40003135060',RouteName:'SR-3135',StreetName:'Elsewhere Rd'},
         geometry:{paths:[[[q.x-1000,q.y+400,0.1],[q.x+1000,q.y+400,0.5]]]}}]});
      return of(u,o); };
    const ts=[]; const ot=window.toast; window.toast=(m,ms)=>{ts.push(m); return ot(m,ms);};
    PINTARGET=null; await pinAt(lat,lon);
    const pops=[...document.querySelectorAll('.leaflet-popup-content')], pop=pops.length?pops[pops.length-1].innerText:'';
    const n1=asked.filter(x=>/submitJob/.test(x)).length;
    await pinAt(lat,lon);
    const n2=asked.filter(x=>/submitJob/.test(x)).length;
    window.fetch=of; window.toast=ot; GP_DOWN=false;
    return {pop:pop.replace(/\n+/g,' | '), toasts:ts, n1, n2};});
  console.log('   '+fb.pop.slice(0,240));
  ok('no "pin drop failed" when NCDOT’s tool fails',fb.toasts.some(t=>/failed/i.test(t)),false);
  ok('the nearest route on the road layer, and the milepoint read off its geometry',
     /BH06 here \| 10000085060/.test(fb.pop)&&/BH07 here \| 2\.200/.test(fb.pop),true);
  ok('...and the popup says where the answer came from',/Read from NCDOT’s road layer/.test(fb.pop),true);
  ok('a second pin does not wait on the broken tool again',fb.n1===1&&fb.n2===1,true);

  console.log('\n7d. The tool is named for the BH items, not just BH06 and BH07');
  ok('the page title and the heading read "NCDOT SNBI BH Validator"',
     await p.evaluate(()=>/^NCDOT SNBI BH Validator/.test(document.title)&&document.querySelector('header h1').textContent.trim()==='NCDOT SNBI BH Validator'),true);

  console.log('\n7c. The table can show bridges only');
  const grp=await p.evaluate(()=>{
    const cnt=g=>ALL.filter(b=>!g||stypeGroup(b)===g).length;
    const btns=[...document.querySelectorAll('#tgrp button')].map(x=>x.innerText.replace(/\s+/g,' ').trim());
    const all=VIEW.length;
    document.querySelector('#tgrp button[data-g="bridge"]').click();
    const onlyB=VIEW.every(b=>stypeGroup(b)==='bridge'), nB=VIEW.length,
          on=document.querySelector('#tgrp button.on').dataset.g;
    document.querySelector('#tgrp button[data-g="culvert"]').click();
    const onlyC=VIEW.every(b=>stypeGroup(b)==='culvert'), nC=VIEW.length;
    document.querySelector('#tgrp button[data-g=""]').click();
    return {btns, all, nB, nC, onlyB, onlyC, on, back:VIEW.length, want:{b:cnt('bridge'),c:cnt('culvert')}};});
  console.log('   '+JSON.stringify(grp));
  ok('a switch above the table: All, Bridges, Culverts & pipes, Signs & other, each with its count',
     grp.btns.length===4&&/^All/.test(grp.btns[0])&&/^Bridges/.test(grp.btns[1])&&/^Culverts & pipes/.test(grp.btns[2]),true);
  ok('Bridges shows bridges and nothing else',grp.onlyB&&grp.nB===grp.want.b&&grp.on==='bridge',true);
  ok('Culverts & pipes shows those and nothing else',grp.onlyC&&grp.nC===grp.want.c,true);
  ok('All brings every structure back',grp.back,grp.all);
  ok('the type is read from NCDOT’s structure type',
     await p.evaluate(()=>[stypeGroup({BRDG_TYP_NM:'Bridge'}),stypeGroup({BRDG_TYP_NM:'FEDERAL BRIDGE'}),
       stypeGroup({BRDG_TYP_NM:'Pipe'}),stypeGroup({BRDG_TYP_NM:'CULVERT'}),stypeGroup({BRDG_TYP_NM:'SIGN'})].join()),
     'bridge,bridge,culvert,culvert,other');

  console.log('\n8. A failed read is reported, not drawn as "no detour anywhere"');
  const {p:p2,m:m2}=await mk(b,{fail:'detour_measured'});
  const errs2=[]; p2.on('pageerror',e=>errs2.push(e.message)); p2.on('dialog',d=>d.accept(''));
  await p2.goto('file://'+FILE); await p2.waitForTimeout(2200);
  await p2.evaluate(()=>{['autoheavy','autohpms','autotraffic'].forEach(id=>{
    const e=document.getElementById(id); if(e) e.checked=false;});});
  await p2.selectOption('#mode','county'); await p2.waitForTimeout(300);
  await p2.selectOption('#arg','MECKLENBURG'); await p2.click('#run');
  await p2.waitForFunction(()=>ALL.length>0,null,{timeout:60000}); await p2.waitForTimeout(2500);
  ok('nothing is marked as looked up when the read failed',
     await p2.evaluate(()=>ALL.every(b=>detourOf(b)===undefined)),true);
  ok('...so the panel says "not looked up", not "not measured"',
     await p2.evaluate(()=>{select('590819',true); return /Measured\s*not looked up yet/i.test(document.getElementById('dr-body').innerText);}),true);
  ok('...and no detour finding is raised on missing data',
     await p2.evaluate(()=>ALL.some(b=>b._flags.some(f=>f.indexOf('DETOUR_')===0))),false);
  ok('the rest of the review is unaffected',await p2.evaluate(()=>ALL.length>0&&ALL.every(b=>b._sev)),true);
  ok('asked by hand, the failure is said out loud',
     await p2.evaluate(async()=>{await detourCheck(); return /could not be read/.test(document.getElementById('toast').textContent);}),true);
  console.log('   page errors (failed read): '+JSON.stringify(errs2));

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
