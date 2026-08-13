/* Reference data comes from the ingest, not from the browser.

   This suite replaces the cache suite. That one asked "does the tool stop
   re-pulling reference data on every run?" and counted ArcGIS requests; the
   question is now moot, because the browser does not pull reference data at
   all. What is worth asserting instead is that the reads it does make are
   scoped, that they page past PostgREST's 1,000-row ceiling, and that the four
   services the ingest owns are never contacted from a reviewer's machine. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const bridges=JSON.parse(fs.readFileSync('tests/fx/bridges.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');

const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

/* Requests that should no longer leave the browser at all. */
const RETIRED=[];
const mk=async(b,opts={})=>{
  const ctx=await b.newContext({viewport:{width:1500,height:950}});
  const p=await ctx.newPage();
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  const esri=[];
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',
      body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',
      body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/cdn.jsdelivr.net/**',r=>r.fulfill({contentType:'application/javascript',
    body:fs.readFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js','utf8')}));
  await p.route('**/*.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/basemap.nationalmap.gov/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/geo.dot.gov/**',r=>{RETIRED.push('geo.dot.gov');
    r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await p.route('**/gis11.services.ncdot.gov/**',async route=>{
    const req=route.request(), u=req.url();
    const pp=new URLSearchParams(req.postData()||'');
    const par=new URLSearchParams(u.split('?')[1]||'');
    const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('CountyBdy'))          { RETIRED.push('CountyBdy'); return J({features:[]}); }
    if(u.includes('DynamicStructures'))  { RETIRED.push('DynamicStructures'); return J({features:[]}); }
    if(/RoadChar.*outStatistics/.test(u)||/outStatistics/.test(req.postData()||'')){
      RETIRED.push('RoadChar statistics'); return J({features:[]}); }
    if(u.includes('Bridges/MapServer/0/query')){
      if(/returnCountOnly/.test(u)) return J({count:bridges.features.length});
      return J(off>0?{features:[]}:bridges); }
    if(u.includes('RoadCharacteristics')){ esri.push(u); return J({type:'FeatureCollection',features:[]}); }
    if(u.includes('export')){ return route.fulfill({contentType:'image/png',body:tile}); }
    return J({features:[]});
  });
  const sb=await sbmock(p,Object.assign({bridges},opts));
  return {ctx,p,sb,esri};
};

const boot=async(p)=>{
  await p.waitForTimeout(2000);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
};

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p,sb,esri}=await mk(b,{bigCounty:2500});
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+FILE);
  await boot(p);

  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. Boot reads counties from the ingest, not from NCDOT');
  const cr=sb.reads('county_geojson');
  ok('one county_geojson read',cr.length,1);
  ok('...and no NCDOT county request',RETIRED.filter(x=>x==='CountyBdy').length,0);
  ok('100 counties in the dropdown',
     await p.evaluate(()=>document.getElementById('f-county').options.length),101);
  ok('the SAP/FIPS crosswalk came with them',
     await p.evaluate(()=>Object.keys(SAP2FIPS).length),100);
  console.log('  county names are stored upper case and read title case:',
     await p.evaluate(()=>CODE2CNTY['060']+' / '+Object.keys(COUNTIES).find(k=>COUNTIES[k]==='060')));

  console.log('\n2. A county run: the SNBI read is scoped to the county on screen');
  sb.clear();
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG');
  await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p.waitForTimeout(2500);           /* let the run's own load settle first */
  sb.clear();
  await p.evaluate(()=>loadSNBI());
  await p.waitForFunction(()=>ALL.some(b=>b._snbi),null,{timeout:30000});
  const sr=sb.reads('structure_snbi');
  ok('one scoped read',sr.filter(x=>x.offset===0).length,1);
  ok('...filtered by county',sr[0].filters.county_name,'in.("MECKLENBURG")');
  ok('...paged because 1,267 rows exceed the ceiling',sr.length,2);
  ok('no DynamicStructures request left the browser',
     RETIRED.filter(x=>x==='DynamicStructures').length,0);
  console.log('  SNBI joined:',await p.evaluate(()=>ALL.filter(b=>b._snbi).length+' / '+ALL.length));

  console.log('\n3. Asking again is one request, not a cache decision');
  sb.clear();
  await p.evaluate(()=>loadSNBI()); await p.waitForTimeout(1500);
  ok('a second call costs the same one scoped read',
     sb.reads('structure_snbi').filter(x=>x.offset===0).length,1);
  console.log('  which is the point: there is no cache to be stale, and no scope');
  console.log('  bookkeeping to get wrong.');

  console.log('\n4. Paging past the 1,000-row ceiling');
  sb.clear();
  const big=await p.evaluate(()=>sbAll('structure_snbi?select=*&county_name=in.("BIGSHIRE")').then(r=>r.length));
  ok('all 2,500 rows loaded',big,2500);
  const pg=sb.reads('structure_snbi');
  ok('three pages fetched',pg.length,3);
  ok('offsets walked',JSON.stringify(pg.map(x=>x.offset)),'[0,1000,2000]');
  console.log('  a client that stopped at page one would have reported 1,000 and looked fine.');

  console.log('\n5. Deep check is a join, not 434 measurements');
  sb.clear();
  await p.evaluate(()=>{ROUTELEN={};ROUTEASKED=new Set();DEEP=false;deepCheck();});
  await p.waitForFunction(()=>DEEP===true,null,{timeout:60000});
  await p.waitForTimeout(800);
  const de=sb.reads('route_extents');
  ok('434 routes cost 2 reads (chunked at 300 for URL length)',de.length,2);
  ok('no RoadCharacteristics statistics query',
     RETIRED.filter(x=>x==='RoadChar statistics').length,0);
  ok('extents landed',await p.evaluate(()=>Object.keys(ROUTELEN).length),433);
  console.log('  the one route missing from the extents is reported as not found,');
  console.log('  which is the honest answer for a route the ingest does not cover.');

  console.log('\n6. HPMS comes from the ingest, scoped by FIPS');
  sb.clear();
  await p.evaluate(()=>fetchHPMS(null));
  await p.waitForFunction(()=>HPMS.size>0,null,{timeout:30000});
  const hr=sb.reads('hpms_routes');
  ok('at least one read',hr.length>0,true);
  ok('filtered to the submittal year',hr[0].filters.hpms_year,'eq.2024');
  ok('and to the counties in scope',/^in\.\(/.test(hr[0].filters.county_id||''),true);
  ok('geo.dot.gov never contacted',RETIRED.filter(x=>x==='geo.dot.gov').length,0);
  console.log('  county_id filter: '+hr[0].filters.county_id);
  console.log('  HPMS routes loaded: '+await p.evaluate(()=>HPMS.size));

  console.log('\n7. Route geometry is still drawn live, and still cached');
  const before=esri.length;
  await p.check('#l-route');
  await p.evaluate(async()=>{ await drawRoute('40401138060'); await drawRoute('40401138060');
    await drawRoute('40401138060'); await drawRoute('40401138061'); });
  await p.waitForTimeout(600);
  ok('3 identical draws + 1 new route = 2 requests',esri.length-before,2);
  console.log('  geometry is a map overlay, not reference data — it stays live on purpose.');

  console.log('\n8. Settings reports vintage, not cache size');
  await p.click('#setbtn'); await p.waitForTimeout(900);
  const txt=await p.evaluate(()=>document.getElementById('cachestate').innerText);
  console.log('  '+txt.replace(/\n/g,'\n  '));
  ok('every ingested source is named',
     ['Bridge inventory','SNBI inventory','County boundaries','Route extents','FHWA HPMS']
       .every(s=>txt.includes(s)),true);
  ok('the 2020 vintage of the structures layer is visible',/2020-07-27/.test(txt),true);
  ok('and HPMS says it reports no date rather than inventing one',
     /no publication date reported/.test(txt),true);

  console.log('\n9. Reloading is a server job, and it needs an account');
  sb.clear();
  await p.click('#cacherefresh'); await p.waitForTimeout(800);
  ok('signed out: nothing asked of the server',sb.rpcs().length,0);
  console.log('  toast: '+await p.evaluate(()=>document.getElementById('toast').textContent));
  await p.evaluate(()=>setSession({access_token:'fake-token',
    user:{id:'11111111-2222-3333-4444-555555555555',email:'jsmith@ncdot.gov',
          user_metadata:{full_name:'J. Smith'}}}));
  await p.waitForTimeout(400);
  sb.clear();
  await p.click('#cacherefresh'); await p.waitForTimeout(1500);
  const r=sb.rpcs();
  ok('signed in: one trigger per source',r.length,4);
  ok('...all of them trigger_ingest',r.every(x=>x.rpc==='trigger_ingest'),true);
  ok('...POSTed, not read',r.every(x=>x.method==='POST'),true);
  console.log('  sources: '+r.map(x=>JSON.parse(x.body).p_source).join(', '));
  ok('the reviewer token is what goes on the wire, not the anon key',
     await p.evaluate(()=>SESSION.token),'fake-token');
  await p.click('#set-x');

  console.log('\n10. A refused reload says so instead of claiming success');
  const {p:p3,sb:sb3}=await mk(b,{rpcFails:'an ingest is already running'});
  p3.on('dialog',d=>d.accept(''));
  await p3.goto('file://'+FILE); await boot(p3);
  await p3.evaluate(()=>setSession({access_token:'t',user:{id:'x',email:'a@b.gov',user_metadata:{}}}));
  await p3.click('#setbtn'); await p3.waitForTimeout(400);
  await p3.click('#cacherefresh'); await p3.waitForTimeout(1200);
  const t3=await p3.evaluate(()=>document.getElementById('toast').textContent);
  ok('the failure reaches the reviewer',/already running/.test(t3),true);
  console.log('  toast: '+t3);

  console.log('\n11. A dead database is reported, not drawn as an empty state');
  const {p:p2}=await mk(b,{fail:'county_geojson'});
  const e2=[]; p2.on('pageerror',e=>e2.push(e.message));
  p2.on('dialog',d=>d.accept(''));
  await p2.goto('file://'+FILE); await p2.waitForTimeout(2500);
  const t2=await p2.evaluate(()=>document.getElementById('toast').textContent);
  ok('the reviewer is told the counties did not load',/county boundaries/i.test(t2),true);
  console.log('  toast: '+t2);

  console.log('\n12. Nothing in the shipped file still points at the retired paths');
  const src=fs.readFileSync(FILE,'utf8');
  for(const [name,re] of [
      ['SNBI scope cache',/SNBISCOPE/],['HPMSGOT set',/HPMSGOT/],
      ['snbiPull()',/function\s+snbiPull/],['COUNTYGOT guard',/COUNTYGOT/],
      ['live HPMS host',/geo\.dot\.gov\/server\/rest/],
      ['groupByFieldsForStatistics',/groupByFieldsForStatistics/]])
    ok('no '+name,re.test(src),false);

  console.log('\nretired endpoints touched: '+JSON.stringify([...new Set(RETIRED)]));
  console.log('page errors: '+JSON.stringify(errs.concat(e2)));
  await b.close();
})();
