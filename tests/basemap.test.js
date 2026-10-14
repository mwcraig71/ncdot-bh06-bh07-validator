/* Basemap fallback: when a tile host is blocked, does the map find another one? */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');
const PNG=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');

const HOSTS=['server.arcgisonline.com','services.arcgisonline.com','basemap.nationalmap.gov',
             'services.nconemap.gov','basemaps.cartocdn.com'];

const mk=async(b,blocked)=>{
  const ctx=await b.newContext({viewport:{width:1200,height:800}});
  const p=await ctx.newPage();
  const seen=[];
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  for(const h of HOSTS){
    await p.route('**://'+h+'/**',r=>{ seen.push(h);
      return blocked.includes(h)? r.abort('blockedbyclient')
        : r.fulfill({contentType:'image/png',body:PNG}); });
  }
  await p.route('**/geo.dot.gov/**',r=>r.fulfill({contentType:'application/json',body:'{"count":12345}'}));
  await p.route('**/gis11.services.ncdot.gov/**',r=>{
    const u=r.request().url();
    if(u.includes('/export?')){ seen.push('gis11-export:'+u.split('bbox=')[1].split('&')[0]);
      return blocked.includes('gis11')? r.abort('blockedbyclient')
        : r.fulfill({contentType:'image/png',body:PNG}); }
    if(u.includes('GPServer')) return r.fulfill({contentType:'application/json',body:'{"name":"IdentifyRouteMilepostUsingPointTool"}'});
    return r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await sbmock(p);
  return {p,seen};
};

const {tally,CHROMIUM}=require('./_check');
const ok=(l,g,w)=>console.log((tally(String(g)===String(w))?'  PASS  ':'  FAIL  ')+l+'  got '+g+', expected '+w);

(async()=>{
  const b=await chromium.launch({executablePath:CHROMIUM});

  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. Picker is built from the provider table');
  {
    const {p}=await mk(b,[]);
    await p.goto('file://'+FILE); await p.waitForTimeout(2200);
    const g=await p.evaluate(()=>[...document.querySelectorAll('#f-base optgroup')].map(o=>o.label));
    console.log('  groups:'); g.forEach(x=>console.log('    '+x));
    ok('option count',await p.evaluate(()=>document.querySelectorAll('#f-base option').length),14);
    ok('default selection',await p.evaluate(()=>document.getElementById('f-base').value),'esri_imagery');
    console.log('  host line: '+await p.evaluate(()=>document.getElementById('basehost').textContent));
    await p.close();
  }

  const scenario=async(label,blocked,wantKey)=>{
    const {p,seen}=await mk(b,blocked);
    const errs=[]; p.on('pageerror',e=>errs.push(e.message));
    await p.goto('file://'+FILE); await p.waitForTimeout(5000);
    const key=await p.evaluate(()=>baseKey);
    const dead=await p.evaluate(()=>[...DEADHOST]);
    const tl=await p.evaluate(()=>tilesDead);
    console.log('\n'+label);
    console.log('  blocked: '+(blocked.join(', ')||'nothing'));
    console.log('  hosts detected blocked: '+JSON.stringify(dead));
    ok('active basemap',tl?'__none':key,wantKey);
    if(errs.length) console.log('  PAGE ERRORS: '+JSON.stringify(errs.slice(0,3)));
    return {p,seen};
  };


  let r;
  r=await scenario('2. Esri blocked  ->  Esri mirror (still imagery)',['server.arcgisonline.com'],'esri2_imagery'); await r.p.close();
  r=await scenario('3. Both Esri hosts blocked  ->  USGS imagery',
      ['server.arcgisonline.com','services.arcgisonline.com'],'usgs_imagery'); await r.p.close();
  r=await scenario('4. Esri + USGS blocked  ->  CARTO (no aerial left)',
      ['server.arcgisonline.com','services.arcgisonline.com','basemap.nationalmap.gov'],'carto_light'); await r.p.close();

  r=await scenario('5. Everything external blocked  ->  NCDOT, off the data server itself',
      ['server.arcgisonline.com','services.arcgisonline.com','basemap.nationalmap.gov',
       'basemaps.cartocdn.com','services.nconemap.gov'],'ncdot_roads');
  const ex=r.seen.filter(x=>x.startsWith('gis11-export:'));
  console.log('  export tiles requested: '+ex.length);
  if(ex.length){
    const bb=ex[0].split(':')[1].split('%2C').join(',').split(',').map(Number);
    const w=bb[2]-bb[0], h=bb[3]-bb[1];
    console.log('  first tile bbox: '+bb.map(n=>n.toFixed(0)).join(', '));
    ok('tile is square in Web Mercator',Math.abs(w-h)<1,true);
    ok('bbox is a power-of-two slice of the world',
       Math.abs(Math.log2(40075016.6855784/w)-Math.round(Math.log2(40075016.6855784/w)))<0.001,true);
    ok('tile lies over North Carolina',
       (bb[0]>-9400000&&bb[2]<-8300000&&bb[1]>3900000&&bb[3]<4500000),true);
  }
  await r.p.close();

  r=await scenario('6. Every host blocked  ->  county outlines only',
      ['server.arcgisonline.com','services.arcgisonline.com','basemap.nationalmap.gov',
       'basemaps.cartocdn.com','services.nconemap.gov','gis11'],'__none');
  ok('blocked note is visible',
     await r.p.evaluate(()=>getComputedStyle(document.getElementById('tilenote')).display),'block');
  ok('picker still usable',await r.p.evaluate(()=>document.getElementById('f-base').disabled),false);
  await r.p.close();

  console.log('\n7. Every host in the automatic chain is blocked, but NC OneMap is not.');
  console.log('   The picker stays enabled precisely so this is recoverable by hand.');
  {
    const {p}=await mk(b,['server.arcgisonline.com','services.arcgisonline.com',
      'basemap.nationalmap.gov','basemaps.cartocdn.com','gis11']);
    await p.goto('file://'+FILE); await p.waitForTimeout(5000);
    ok('starts tileless',await p.evaluate(()=>tilesDead),true);
    await p.selectOption('#f-base','nc1_ortho'); await p.waitForTimeout(1200);
    ok('picked NC OneMap',await p.evaluate(()=>baseKey),'nc1_ortho');
    await p.waitForTimeout(2500);        /* long enough for it to bail again if it were going to */
    ok('background restored and it stuck',await p.evaluate(()=>tilesDead),false);
    await p.selectOption('#f-base','__none'); await p.waitForTimeout(600);
    ok('"no background" honoured',await p.evaluate(()=>tilesDead),true);
    await p.close();
  }

  console.log('\n8. Diagnostics probes every host');
  {
    const {p}=await mk(b,['server.arcgisonline.com','services.arcgisonline.com']);
    await p.goto('file://'+FILE); await p.waitForTimeout(2500);
    await p.click('#setbtn'); await p.waitForTimeout(300);
    await p.click('#diag'); await p.waitForTimeout(22000);
    const t=await p.evaluate(()=>document.getElementById('dr-body').innerText);
    console.log('  '+t.split('\n').filter(x=>x.trim()).slice(0,40).join('\n  '));
    await p.close();
  }

  await b.close();
})();
