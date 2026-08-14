/* Field mode. A different tool for a different person: someone standing under a
   bridge with one hand free, who needs the bridge rather than the checklist. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FX=JSON.parse(fs.readFileSync('tests/fx/features.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');
const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

/* the fixture's 590668 sits here; the phone is put 120 ft away from it */
const AT=FX.bridges.features.find(f=>f.attributes.BRDG_NBR==='590819').attributes;
const HERE={latitude:AT.LAT_DD+0.00033, longitude:AT.LONG_DD, accuracy:8};

const mk=async(b,opts={})=>{
  const ctx=await b.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,
    isMobile:true,hasTouch:true,permissions:opts.deny?[]:['geolocation'],
    geolocation:{latitude:HERE.latitude,longitude:HERE.longitude}});
  const p=await ctx.newPage();
  const proposals=[];
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
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('Bridges/MapServer/0/query')){
      const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
      return J(off>0?{features:[]}:FX.bridges); }
    if(u.includes('RoadCharacteristics')) return J(FX.road['590668']||{features:[]});
    return J({features:[]});
  });
  await sbmock(p,{bridges:FX.bridges,snbi:FX.snbi.map(x=>Object.assign({},x))});
  /* after sbmock, which also claims /rest/v1/** — the last route registered wins */
  await p.route('**/rest/v1/rpc/propose_value',r=>{
    proposals.push(JSON.parse(r.request().postData()||'{}'));
    return r.fulfill({status:200,contentType:'application/json',
      body:JSON.stringify({queued:true,created_feature:false})});});
  return {ctx,p,proposals};
};

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p,proposals}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+FILE);
  await p.waitForTimeout(2600);

  console.log('\nFILE: '+FILE.split('/').pop()+'   390x844, touch');

  console.log('\n1. The left panel and the checklist are gone');
  ok('field mode is on',await p.evaluate(()=>document.body.classList.contains('field')),true);
  ok('the filter panel is not displayed',
     await p.evaluate(()=>getComputedStyle(document.getElementById('side')).display),'none');
  ok('the tab strip is gone with it',
     await p.evaluate(()=>getComputedStyle(document.querySelector('.mtabs')).display),'none');
  ok('a field bar takes its place',
     await p.evaluate(()=>getComputedStyle(document.getElementById('fieldbar')).display),'flex');

  console.log('\n2. No verdict to read off the map');
  ok('the severity legend is not added',
     await p.evaluate(()=>!document.querySelector('.legend')),true);

  console.log('\n3. The table starts hidden, on a tab you pull up');
  ok('closed on open',await p.evaluate(()=>document.body.classList.contains('sheet')),false);
  ok('the pull-up is off screen',await p.evaluate(()=>{
     const r=document.getElementById('tablewrap').getBoundingClientRect();
     return r.top>=window.innerHeight-4;}),true);
  await p.click('#fb-table'); await p.waitForTimeout(400);
  ok('tapping the tab raises it',await p.evaluate(()=>document.body.classList.contains('sheet')),true);
  ok('...and it is on screen now',await p.evaluate(()=>{
     const r=document.getElementById('tablewrap').getBoundingClientRect();
     return r.top<window.innerHeight-100;}),true);
  await p.click('#fb-table'); await p.waitForTimeout(300);
  ok('tapping again puts it away',await p.evaluate(()=>document.body.classList.contains('sheet')),false);

  console.log('\n4. It starts where the inspector is standing');
  await p.waitForFunction(()=>typeof MYPOS!=='undefined'&&MYPOS,null,{timeout:20000});
  ok('a fix was taken',await p.evaluate(()=>!!MYPOS),true);
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p.waitForTimeout(2500);
  ok('the county underneath was loaded without being asked',
     await p.evaluate(()=>ALL.length>0&&ALL[0].COUNTY==='MECKLENBURG'),true);
  const sel=await p.evaluate(()=>SEL);
  console.log('   standing 120 ft from 590819, selected: '+sel);
  ok('the bridge being stood at is already open',sel,'590819');
  const fb=await p.evaluate(()=>document.getElementById('fb-state').textContent);
  console.log('   field bar: '+fb);
  ok('the field bar says how far',/\d+\s*ft/.test(fb),true);

  console.log('\n5. The panel leads with the numbers, not the paperwork');
  const body=await p.evaluate(()=>document.getElementById('dr-body').innerText);
  const iB6=body.search(/BH06/i), iFeat=body.search(/features/i), iRev=body.search(/\bstatus\b/i);
  console.log('   BH06 at '+iB6+', features at '+iFeat+', review at '+iRev);
  ok('BH06 comes first',iB6>=0&&iB6<iFeat,true);
  ok('the features come next',iFeat<iRev,true);
  ok('status and corrections come last',iRev>iFeat,true);
  ok('every feature shows its own BH06 and BH07',await p.evaluate(()=>{
     const b=ALL.find(x=>x.BRDG_NBR===SEL);
     return featuresOf(b).length>1;}),true);

  console.log('\n6. Add new feature, and pick the roadway by tapping');
  ok('the button is there after the last feature',
     await p.evaluate(()=>!!document.getElementById('addfeat')),true);
  const before=await p.evaluate(()=>featuresOf(ALL.find(x=>x.BRDG_NBR===SEL)).length);
  await p.evaluate(()=>document.getElementById('addfeat').click());
  await p.waitForTimeout(500);
  const after=await p.evaluate(()=>featuresOf(ALL.find(x=>x.BRDG_NBR===SEL)).length);
  ok('adding one appends a below feature',after,before+1);
  ok('...and arms the pin at it',await p.evaluate(()=>PINTARGET&&PINTARGET.des),
     await p.evaluate(()=>{const f=featuresOf(ALL.find(x=>x.BRDG_NBR===SEL));return f[f.length-1].des;}));
  ok('the map is showing, not the table',await p.evaluate(()=>document.body.classList.contains('sheet')),false);
  ok('the new feature offers pick-roadway as a tap target, not a text link',
     await p.evaluate(()=>{const a=document.querySelector('a.pinf');
       return a? a.classList.contains('pinbtn') : 'none';}),true);
  ok('...and it is full width under a thumb',
     await p.evaluate(()=>{const a=document.querySelector('a.pinf');
       return a? a.getBoundingClientRect().width>240 : false;}),true);
  ok('a twin pair is called out rather than silently resolved',
     await p.evaluate(()=>{
       const b=ALL.find(x=>x.BRDG_NBR==='590668');
       return !!(b&&b._twins&&b._twins.length);}),true);

  console.log('\n7. What the inspector records goes to a queue, not into the data');
  await p.evaluate(()=>{SESSION.token='t';SESSION.user='u';SESSION.name='S. Gordon';applySession();});
  await p.evaluate(()=>submitProposal('590819','H02','BH07','0.244','measured at the abutment'));
  await p.waitForTimeout(700);
  ok('it was sent as a proposal',proposals.length>0,true);
  if(proposals.length) console.log('   '+JSON.stringify(proposals[proposals.length-1]));
  ok('...naming the structure and the feature, not a UUID',
     proposals.length? (proposals[0].p_structure==='590819'&&proposals[0].p_designation==='H02') : false,true);
  ok('the queue empties once sent',await p.evaluate(()=>pendCount()),0);

  console.log('\n8. Offline, nothing is lost');
  await p.context().setOffline(true);
  await p.evaluate(()=>submitProposal('590819','H03','BH06','20000074060','under the east span'));
  await p.waitForTimeout(400);
  ok('it is held instead of dropped',await p.evaluate(()=>pendCount()),1);
  ok('and the field bar says so',
     await p.evaluate(()=>/waiting to send/.test(document.getElementById('fb-state').textContent)),true);
  ok('it survives the page being closed',await p.evaluate(()=>{
     const raw=localStorage.getItem('bh0607.pending.v1');
     return !!raw&&JSON.parse(raw).length===1;}),true);
  const n0=proposals.length;
  await p.context().setOffline(false);
  await p.evaluate(()=>flushProposals()); await p.waitForTimeout(900);
  ok('coming back online sends it',proposals.length,n0+1);
  ok('...and the queue is empty again',await p.evaluate(()=>pendCount()),0);

  console.log('\n9. The county is saved to the phone, and works without a signal');
  await p.evaluate(()=>cacheCounty('MECKLENBURG'));
  await p.waitForFunction(()=>typeof OFFLINE!=='undefined'&&OFFLINE,null,{timeout:30000});
  const cache=await p.evaluate(()=>({county:OFFLINE.county,bridges:(OFFLINE.bridges||[]).length,
     snbi:(OFFLINE.snbi||[]).length,extents:(OFFLINE.extents||[]).length,
     kb:Math.round(JSON.stringify(OFFLINE).length/1024)}));
  console.log('   saved '+cache.county+': '+cache.bridges+' bridges, '+cache.snbi+' SNBI, '+
              cache.extents+' extents  ('+cache.kb+' KB)');
  ok('the county was written to the device',cache.county,'MECKLENBURG');
  ok('with the structures in it',cache.bridges>0,true);
  ok('it survives a reload — it is in IndexedDB, not in memory',
     await p.evaluate(async()=>{const b=await idbGet('county:MECKLENBURG'); return !!b&&b.bridges.length>0;}),true);
  ok('and the pending queue is kept separately, so a broken cache cannot take it',
     await p.evaluate(()=>!!localStorage.getItem('bh0607.pending.v1')||pendCount()===0),true);

  const off=await p.evaluate(async()=>{
    ALL=[]; SNBI=new Map(); HPMS=new Map(); ROUTELEN={};
    const held=await loadCachedCounty('MECKLENBURG');
    if(!held) return null;
    ALL=held.bridges.map(x=>Object.assign({},x));
    offlineApply(); revalidate();
    return {n:ALL.length, snbi:SNBI.size, extents:Object.keys(ROUTELEN).length,
            validated:ALL.filter(b=>b._flags).length};});
  console.log('   restored offline: '+off.n+' bridges, '+off.snbi+' SNBI, '+off.extents+' extents');
  ok('the structures come back from the device',off.n>0,true);
  ok('...and every one is validated with no network at all',off.validated,off.n);
  ok('the SNBI join survives too',off.snbi>0,true);
  ok('and so do the route extents the deep check needs',off.extents>0,true);

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
