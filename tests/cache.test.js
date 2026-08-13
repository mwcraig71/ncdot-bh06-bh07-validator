/* Cache behaviour: does the tool stop re-pulling reference data?
   Counts every outbound request per service across a sequence of scopes. */
const {chromium}=require('playwright');const fs=require('fs');
const counties=fs.readFileSync('tests/fx/counties.json','utf8');
const bridges=JSON.parse(fs.readFileSync('tests/fx/bridges.json','utf8'));
const struct=JSON.parse(fs.readFileSync('tests/fx/struct_meck.json','utf8'));
const FILE=process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html';

const LOG=[];                      /* every structures/roadchar/county request */
const bump=(k,d)=>LOG.push({k,d});
const count=k=>LOG.filter(x=>x.k===k).length;
let mark=0;
const since=k=>LOG.slice(mark).filter(x=>x.k===k).length;
const reset=()=>{mark=LOG.length;};

/* --- a where-clause evaluator good enough for the shapes the app emits --- */
function parseIn(where,field){
  const m=where.match(new RegExp(field+"\\s+IN\\s*\\(([^)]*)\\)",'i'));
  if(!m) return null;
  return m[1].split(',').map(s=>s.trim().replace(/^'|'$/g,''));
}
function eqOf(where,field){
  const m=where.match(new RegExp(field+"\\s*=\\s*'([^']*)'",'i'));
  return m?m[1]:null;
}
function filterBridges(where){
  let f=bridges.features;
  if(/^1=1$/.test(where.trim())) return f;
  const c=eqOf(where,'COUNTY'); if(c) return f.filter(x=>x.attributes.COUNTY===c);
  const like=where.match(/BRDG_NBR LIKE '%([^%]*)%'/);
  if(like) return f.filter(x=>String(x.attributes.BRDG_NBR).includes(like[1]));
  const r=eqOf(where,'RTE_ID'); if(r) return f.filter(x=>x.attributes.RTE_ID===r);
  const rl=where.match(/RTE_ID LIKE '([^']*)'/);
  if(rl){ const re=new RegExp('^'+rl[1].replace(/_/g,'.')+'$');
    return f.filter(x=>re.test(String(x.attributes.RTE_ID||''))); }
  return f;
}
/* a synthetic county with 2,500 structures in layer 0, to prove the pager
   walks past the service's 1,000-row cap instead of stopping at page one */
const BIG=Array.from({length:2500},(_,i)=>({attributes:{ObjectID:900000+i,
  County:'Bigshire',StructureNumber:'B'+String(i).padStart(5,'0'),ServiceOn:'Highway'}}));
function filterStruct(layer,where){
  if(/Bigshire/.test(where)) return layer===0?BIG:[];
  let rows=struct[String(layer)]||[];
  if(/^1=1$/.test(where.trim())) return rows;
  const cin=parseIn(where,'County'), ceq=eqOf(where,'County');
  if(cin) return rows.filter(x=>cin.includes(x.attributes.County));
  if(ceq) return rows.filter(x=>x.attributes.County===ceq);
  const sin=parseIn(where,'StructureNumber');
  if(sin) return rows.filter(x=>sin.includes(String(x.attributes.StructureNumber).trim()));
  return [];
}

const mk=async(b)=>{
  const ctx=await b.newContext({viewport:{width:1500,height:950}});
  const p=await ctx.newPage();
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  /* the CDN builds pull Leaflet from cdnjs; this sandbox has no network */
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',
      body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',
      body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/server.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/geo.dot.gov/**',r=>{bump('hpms',r.request().url());
    r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await p.route('**/gis11.services.ncdot.gov/**',async route=>{
    const req=route.request(), u=req.url();
    const body=req.postData()||'';
    const par=new URLSearchParams(u.split('?')[1]||'');
    const pp=new URLSearchParams(body);
    const where=(pp.get("where")||par.get("where")||"1=1");
    const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});

    if(u.includes('CountyBdy')){ bump('county',where); return route.fulfill({contentType:'application/json',body:counties}); }

    const sl=u.match(/DynamicStructures\/MapServer\/(\d)\/query/);
    if(sl){ bump('struct',{layer:+sl[1],where:where.slice(0,80),off});
      const rows=filterStruct(+sl[1],where);
      const pg=rows.slice(off,off+1000);        /* the real service caps at 1000 */
      return J({features:pg,exceededTransferLimit:off+pg.length<rows.length}); }

    if(u.includes('Bridges/MapServer/0/query')){ bump('bridges',where);
      return J({features:off>0?[]:filterBridges(where)}); }

    if(u.includes('RoadCharacteristics')){ bump('roadchar',where.slice(0,60));
      if((par.get('f')||pp.get('f'))==='geojson') return J({type:'FeatureCollection',features:[]});
      return J({features:[]}); }

    return J({features:[]});
  });
  return {ctx,p};
};

const ok=(label,got,want)=>console.log((got===want?'  PASS  ':'  FAIL  ')+label+
  '  got '+got+', expected '+want);

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+require('path').resolve(FILE));
  await p.waitForTimeout(1800);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});

  console.log('\nFILE: '+FILE.split('/').pop());
  console.log('\n1. Boot');
  ok('county boundary pulls at load',count('county'),1);

  console.log('\n2. County scope (Mecklenburg) — the first real pull');
  reset();
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG');
  await p.click('#run');
  await p.waitForFunction(()=>document.getElementById('t-tot').textContent!=='–',null,{timeout:60000});
  await p.waitForTimeout(2500);
  const s1=since('struct');
  console.log('  structure-layer requests: '+s1+'  (8 layers, county-scoped)');
  console.log('  layers hit:',JSON.stringify(LOG.slice(mark).filter(x=>x.k==='struct').map(x=>x.d.layer)));
  console.log('  where clause:',JSON.stringify(LOG.slice(mark).filter(x=>x.k==='struct')[0].d.where));
  const matched=await p.evaluate(()=>ALL.filter(b=>b._snbi).length+' / '+ALL.length);
  console.log('  SNBI joined:',matched);

  console.log('\n3. Single bridge inside that county — should cost nothing');
  reset();
  await p.selectOption('#mode','bridge'); await p.waitForTimeout(250);
  await p.fill('#arg','590001');
  await p.click('#run'); await p.waitForTimeout(2500);
  ok('new structure requests',since('struct'),0);
  ok('new county requests',since('county'),0);
  console.log('  SNBI joined:',await p.evaluate(()=>ALL.filter(b=>b._snbi).length+' / '+ALL.length));

  console.log('\n4. Route scope inside that county — should also cost nothing');
  reset();
  await p.selectOption('#mode','route'); await p.waitForTimeout(250);
  await p.fill('#arg','40401138'); await p.click('#run'); await p.waitForTimeout(2500);
  ok('new structure requests',since('struct'),0);

  console.log('\n5. Route geometry cache — three bridges on one route');
  reset();
  await p.check('#l-route');
  await p.evaluate(async()=>{ await drawRoute('40401138060'); await drawRoute('40401138060');
    await drawRoute('40401138060'); await drawRoute('40401138061'); });
  await p.waitForTimeout(600);
  ok('geometry requests for 3 identical draws + 1 new route',
     LOG.slice(mark).filter(x=>x.k==='roadchar').length,2);

  console.log('\n6. Cache state readout');
  await p.click('#setbtn'); await p.waitForTimeout(400);
  console.log('  '+(await p.evaluate(()=>document.getElementById('cachestate').innerText)).replace(/\n/g,'\n  '));
  await p.click('#set-x'); await p.waitForTimeout(200);

  console.log('\n7. Manual refresh');
  reset();
  await p.click('#setbtn'); await p.waitForTimeout(300);
  await p.click('#cacherefresh'); await p.waitForTimeout(1800);
  ok('county boundaries re-read',since('county'),1);
  ok('SNBI dropped',await p.evaluate(()=>SNBI.size),0);
  ok('route geometry dropped',await p.evaluate(()=>ROUTEGEO.size),0);
  console.log('  county dropdown still has',await p.evaluate(()=>document.getElementById('f-county').options.length),'options (1 + counties)');
  await p.click('#set-x');

  console.log('\n8. Fresh page, single bridge FIRST — the case that used to pull the state');
  const {p:p2}=await mk(b);
  const e2=[]; p2.on('pageerror',e=>e2.push(e.message)); p2.on('dialog',d=>d.accept(''));
  await p2.goto('file://'+require('path').resolve(FILE)); await p2.waitForTimeout(1800);
  await p2.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  reset();
  await p2.selectOption('#mode','bridge'); await p2.waitForTimeout(250);
  await p2.fill('#arg','590001'); await p2.click('#run'); await p2.waitForTimeout(2500);
  const sl=LOG.slice(mark).filter(x=>x.k==='struct');
  console.log('  structure requests: '+sl.length+'  layers '+JSON.stringify(sl.map(x=>x.d.layer)));
  console.log('  where: '+JSON.stringify(sl.length?sl[0].d.where:''));
  ok('single bridge costs one layer request',sl.length,1);
  console.log('  SNBI joined:',await p2.evaluate(()=>ALL.filter(b=>b._snbi).length+' / '+ALL.length));

  console.log('\n9. Then widen to the whole county from that same page');
  reset();
  await p2.selectOption('#mode','county'); await p2.waitForTimeout(250);
  await p2.selectOption('#arg','MECKLENBURG'); await p2.click('#run');
  await p2.waitForTimeout(3000);
  console.log('  structure requests: '+since('struct')+' (a county pull, as it should be)');
  console.log('  SNBI joined:',await p2.evaluate(()=>ALL.filter(b=>b._snbi).length+' / '+ALL.length));

  console.log('\n10. Paging past the 1,000-row cap (a 2,500-structure layer)');
  reset();
  const grew=await p2.evaluate(async()=>{
    const before=SNBI.size;
    await snbiPull("County IN ('Bigshire')",[[0,'Bridge']],null,'Bigshire');
    return SNBI.size-before;
  });
  ok('structures loaded from a 2,500-row layer',grew,2500);
  ok('pages fetched',since('struct'),3);

  console.log('\npage errors:',JSON.stringify(errs.concat(e2)));
  await b.close();
})();
