/* Filtering on the table itself.
   The left panel filters what the data is; this filters what the table shows,
   column by column, against the text in the cell — which is the only way to
   reach the decoded label, the findings and the suggested correction, none of
   which exist as a field anywhere. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const bridges=JSON.parse(fs.readFileSync('tests/fx/bridges.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');
const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const ctx=await b.newContext({acceptDownloads:true,viewport:{width:1700,height:1000}});
  const p=await ctx.newPage();
  const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('dialog',d=>d.accept(''));
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/cdn.jsdelivr.net/**',r=>r.fulfill({contentType:'application/javascript',
    body:fs.readFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js','utf8')}));
  await p.route('**/*.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/gis11.services.ncdot.gov/**',r=>{const u=r.request().url();
    const off=+((u.match(/resultOffset=(\d+)/)||[])[1]||0);
    if(u.includes('Bridges/MapServer/0/query'))
      return r.fulfill({contentType:'application/json',body:JSON.stringify(off>0?{features:[]}:bridges)});
    return r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await sbmock(p,{bridges});
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000}); await p.waitForTimeout(2500);

  const shown=()=>p.evaluate(()=>document.querySelectorAll('#tscroll tbody tr').length);
  const setf=async(k,v)=>{ await p.evaluate(([k,v])=>{COLF[k]=v;renderTable();},[k,v]); await p.waitForTimeout(150); };
  const clearf=()=>p.evaluate(()=>{Object.keys(COLF).forEach(k=>delete COLF[k]);applyFilters();});

  console.log('\nFILE: '+FILE.split('/').pop());
  const total=await p.evaluate(()=>VIEW.length);
  console.log('rows in view: '+total);

  console.log('\n1. Every column carries a filter box');
  const boxes=await p.evaluate(()=>[...document.querySelectorAll('#tscroll input.cf')].map(x=>x.dataset.k));
  const cols=await p.evaluate(()=>COLS.map(c=>c.k));
  ok('one per column',boxes.length,cols.length);
  ok('...and they line up with the columns',boxes.join()===cols.join(),true);
  ok('the header still sorts',await p.evaluate(async()=>{
    document.querySelector('#tscroll thead tr:first-child th[data-k="COUNTY"]').click();
    return sortKey;}),'COUNTY');

  console.log('\n2. Text columns match what the cell shows');
  await clearf(); await setf('F_CARRIED','SR1138');
  const nc=await shown();
  ok('Carried filtered to SR1138',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>(b.F_CARRIED||'').toUpperCase().includes('SR1138'))),true);
  console.log('   '+nc+' of '+total+' rows carry SR1138');
  await setf('F_CARRIED','!SR1138');
  ok('a leading ! excludes instead',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>!(b.F_CARRIED||'').toUpperCase().includes('SR1138'))),true);
  await clearf(); await setf('FTR_INTRSC','-');
  ok('a lone dash finds the empty cells',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>!String(b.FTR_INTRSC||'').trim())),true);

  console.log('\n3. Columns that are not fields at all');
  await clearf(); await setf('_declab','I85');
  ok('the decoded label filters, though no such field exists',
     await p.evaluate(()=>VIEW.filter(passesColumns).every(b=>b._dec&&b._dec.label==='I85')),true);
  await clearf(); await setf('_flaglab','county');
  const fl=await p.evaluate(()=>VIEW.filter(passesColumns).length);
  ok('findings filter as text',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>b._flags.some(f=>/county/i.test(RULEMAP[f].t)))),true);
  console.log('   '+fl+' rows have a finding whose name contains "county"');

  console.log('\n4. Numeric columns take comparisons, not just equality');
  await clearf(); await setf('MP','>5');
  ok('>5 keeps only milepoints over 5',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>b._mp3!==null&&b._mp3>5)),true);
  await setf('MP','1-2');
  ok('a range keeps only what is inside it',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>b._mp3>=1&&b._mp3<=2)),true);
  await setf('MP','<=0.5');
  ok('<= is inclusive',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>b._mp3<=0.5)),true);
  await setf('MP','0.227');
  ok('a bare number matches at three decimals',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>Math.abs(b._mp3-0.227)<0.0005)),true);
  await setf('MP','>');
  ok('a half-typed comparison hides nothing',await p.evaluate(()=>
     VIEW.filter(passesColumns).length===VIEW.length),true);
  await clearf(); await setf('_off','-');
  ok('- on a numeric column finds what was never measured',await p.evaluate(()=>
     VIEW.filter(passesColumns).every(b=>b._off==null)),true);

  console.log('\n5. Filters combine, and the count says so');
  await clearf();
  await setf('COUNTY','MECK'); await setf('F_CARRIED','SR');
  const both=await p.evaluate(()=>VIEW.filter(passesColumns).length);
  ok('two columns narrow further than one',both<total&&both>0,true);
  const cnt=await p.evaluate(()=>document.getElementById('tcount').textContent);
  console.log('   count reads: '+cnt);
  ok('the count names how many filters are on',/2 column filters/.test(cnt),true);

  console.log('\n6. The export is what you are looking at');
  const dl=p.waitForEvent('download',{timeout:20000});
  await p.click('#csv');
  const d=await dl; await d.saveAs('/tmp/colfilter.csv');
  const lines=fs.readFileSync('/tmp/colfilter.csv','utf8').trim().split(/\r?\n/);
  const data=lines.filter(l=>/^\uFEFF?\d{6},/.test(l));   /* a note can carry a newline */
  ok('the CSV holds the filtered rows, not the whole view',data.length,both);
  console.log('   exported '+data.length+' rows against '+total+' in view');

  console.log('\n7. Nothing matching says so, and offers a way back');
  await clearf(); await setf('BRDG_NBR','ZZZZZZ');
  const empty=await p.evaluate(()=>document.getElementById('tscroll').innerText);
  ok('it explains the column filters are the cause',/column filter/.test(empty),true);
  ok('...and offers to clear them',await p.evaluate(()=>!!document.getElementById('cf-clear')),true);
  await p.evaluate(()=>document.getElementById('cf-clear').click());
  await p.waitForTimeout(300);
  ok('clearing them brings the rows back',await shown()>0,true);

  console.log('\n8. Clear filters clears these too');
  await setf('F_CARRIED','SR1138');
  await p.click('#clearf'); await p.waitForTimeout(300);
  ok('the column boxes are empty again',await p.evaluate(()=>colFilterCount()),0);

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
