/* Corrections are validated: does a reviewer's fix06/fix07 actually get tested? */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const bridges=JSON.parse(fs.readFileSync('tests/fx/bridges.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');

const mk=async(b)=>{
  const ctx=await b.newContext({acceptDownloads:true,viewport:{width:1600,height:1000}});
  const p=await ctx.newPage();
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/server.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/geo.dot.gov/**',r=>r.fulfill({contentType:'application/json',body:'{"features":[]}'}));
  await p.route('**/gis11.services.ncdot.gov/**',r=>{const u=r.request().url();
    const off=+((u.match(/resultOffset=(\d+)/)||[])[1]||0);
    if(u.includes('Bridges/MapServer/0/query'))
      return r.fulfill({contentType:'application/json',body:JSON.stringify(off>0?{features:[]}:bridges)});
    return r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await sbmock(p,{bridges});
  return {ctx,p};
};
const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+'  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

const st=(p,bn)=>p.evaluate(n=>{const b=ALL.find(x=>x.BRDG_NBR===n);
  return {rid:b._rid,mp:b._mp3,src:b._src,src6:b._src06,src7:b._src07,
          sev:b._sev,flags:b._flags.slice().sort(),off:b._off,stale:!!b._offStale};},bn);

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const {p}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+FILE); await p.waitForTimeout(2000);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p.waitForTimeout(2500);

  console.log('\nFILE: '+FILE.split('/').pop());

  /* A bridge whose published BH06 is in the wrong county — CNTY_MISMATCH.
     Mecklenburg is SAP 060; give one a route ending 999 and it should fail. */
  const target=await p.evaluate(()=>{
    const b=ALL.find(x=>/^\d{11}$/.test((x.RTE_ID||'').trim())&&x._mp3!==null);
    return {bn:b.BRDG_NBR,rid:b.RTE_ID,mp:b._mp3};});
  console.log('\ntarget bridge '+target.bn+'  published '+target.rid+' @ '+target.mp);

  console.log('\n1. Baseline — validated on the published value');
  let s=await st(p,target.bn);
  ok('source',s.src,'PUBLISHED'); ok('rid under test',s.rid,target.rid);
  console.log('   flags: '+JSON.stringify(s.flags));
  const baseFlags=s.flags;

  console.log('\n2. A correction is validated, not just stored');
  console.log('   (BH06 -> a route ID whose county digits say ANSON, not Mecklenburg)');
  const badRid=target.rid.slice(0,8)+'004';
  await p.evaluate(([bn,rid])=>{rec(bn,true).fix06=rid; touch(bn); revalidate(); applyFilters();},[target.bn,badRid]);
  await p.waitForTimeout(400);
  s=await st(p,target.bn);
  ok('rid under test is now the correction',s.rid,badRid);
  ok('source',s.src,'REVIEWED');
  ok('BH06 field marked reviewed',s.src6,'REVIEWED');
  ok('BH07 field still published',s.src7,'PUBLISHED');
  ok('the wrong correction FAILS county check',s.flags.includes('CNTY_MISMATCH'),true);
  ok('and is marked as validated-on-a-correction',s.flags.includes('REVIEWED_VALUE'),true);
  console.log('   flags: '+JSON.stringify(s.flags));

  console.log('\n3. REVIEWED is not the same as cleared — the two stay separate');
  ok('a corrected row is NOT automatically clean',s.sev!=='ok',true);
  ok('CNTY_MISMATCH severity carries through',s.sev,'w');
  await p.evaluate(bn=>{const r=rec(bn,true); r.cleared['CNTY_MISMATCH']={reason:'t',by:'t',ts:1};
    touch(bn); revalidate(); applyFilters();},target.bn);
  await p.waitForTimeout(300);
  const eff=await p.evaluate(bn=>{const b=ALL.find(x=>x.BRDG_NBR===bn);
    return {raw:b._flags.includes('CNTY_MISMATCH'),effSev:effSev(b),effHas:effFlags(b).includes('CNTY_MISMATCH')};},target.bn);
  ok('clearing does not delete the finding',eff.raw,true);
  ok('clearing does remove it from the effective set',eff.effHas,false);
  await p.evaluate(bn=>{delete REVIEW.get(bn).cleared['CNTY_MISMATCH']; revalidate(); applyFilters();},target.bn);

  console.log('\n4. A GOOD correction clears the finding it was meant to fix');
  await p.evaluate(([bn,rid])=>{rec(bn,true).fix06=rid; touch(bn); revalidate(); applyFilters();},[target.bn,target.rid]);
  await p.waitForTimeout(300);
  s=await st(p,target.bn);
  ok('county finding gone',s.flags.includes('CNTY_MISMATCH'),false);
  ok('still flagged as a reviewed value',s.flags.includes('REVIEWED_VALUE'),true);

  console.log('\n5. Withdrawing a correction returns the row to the published value');
  await p.evaluate(bn=>{rec(bn,true).fix06=''; rec(bn,true).fix07=''; touch(bn); revalidate(); applyFilters();},target.bn);
  await p.waitForTimeout(300);
  s=await st(p,target.bn);
  ok('source',s.src,'PUBLISHED');
  ok('flags back to baseline',JSON.stringify(s.flags),JSON.stringify(baseFlags));

  console.log('\n6. A corrected BH07 invalidates the cached Locate offset');
  await p.evaluate(bn=>{const b=ALL.find(x=>x.BRDG_NBR===bn);
    b._off=12.5; b._offFor=offKey(b._rid,b._mp3); b._offStale=false; revalidate();},target.bn);
  s=await st(p,target.bn);
  ok('offset held before the change',s.off,12.5);
  await p.evaluate(bn=>{rec(bn,true).fix07='9.999'; touch(bn); revalidate(); applyFilters();},target.bn);
  await p.waitForTimeout(300);
  s=await st(p,target.bn);
  ok('stale offset dropped',s.off,null);
  ok('row marked as needing re-locate',s.stale,true);
  const offCell=await p.evaluate(bn=>{const b=ALL.find(x=>x.BRDG_NBR===bn); return cell(b,'_off');},target.bn);
  ok('table shows re-locate, not a stale number',/re-locate/.test(offCell),true);

  console.log('\n7. The UI never leaves it ambiguous which number is being tested');
  const cells=await p.evaluate(bn=>{const b=ALL.find(x=>x.BRDG_NBR===bn);
    return {b06:cell(b,'_bh06'),mp:cell(b,'MP')};},target.bn);
  ok('BH07 cell carries the reviewed tag',/srctag/.test(cells.mp),true);
  ok('BH07 cell shows the corrected number',/9\.999/.test(cells.mp),true);
  await p.evaluate(bn=>select(bn,false),target.bn); await p.waitForTimeout(900);
  const drawer=await p.evaluate(()=>document.getElementById('dr-body').innerText);
  ok('drawer shows the corrected value',/9\.999/.test(drawer),true);
  ok('drawer also shows the published one',drawer.includes(String(target.mp.toFixed(3))),true);
  ok('drawer explains which is under test',/because that is the value you would submit/.test(drawer),true);
  const struck=await p.evaluate(()=>!!document.querySelector('#dr-body .wasval'));
  ok('published value is struck through',struck,true);

  console.log('\n8. Editing the field in the panel re-tests immediately');
  await p.fill('#rv-f06','not-a-route');
  await p.evaluate(()=>document.getElementById('rv-f06').dispatchEvent(new Event('change')));
  await p.waitForTimeout(700);
  s=await st(p,target.bn);
  ok('bad format caught from a panel edit',s.flags.includes('BAD_FORMAT'),true);
  ok('and the row is not clean',s.sev!=='ok',true);

  console.log('\n9. Duplicate detection sees corrections');
  const two=await p.evaluate(()=>{const c=ALL.filter(x=>/^\d{11}$/.test(x._rid)&&x._mp3!==null).slice(0,2);
    return c.map(x=>x.BRDG_NBR);});
  await p.evaluate(([a,c])=>{
    const A=ALL.find(x=>x.BRDG_NBR===a), C=ALL.find(x=>x.BRDG_NBR===c);
    rec(a,true).fix06=''; rec(a,true).fix07='';
    rec(c,true).fix06=A.RTE_ID; rec(c,true).fix07=mp3(A.MP).toFixed(3);
    touch(c); revalidate(); applyFilters();},two);
  await p.waitForTimeout(400);
  const dup=await p.evaluate(([a,c])=>({a:ALL.find(x=>x.BRDG_NBR===a)._flags.includes('DUPLICATE_PAIR'),
    c:ALL.find(x=>x.BRDG_NBR===c)._flags.includes('DUPLICATE_PAIR')}),two);
  ok('correction collides with a published pair — both flagged',dup.a&&dup.c,true);

  console.log('\n10. CSV: header and every row line up, and the tested value is in it');
  await p.click('#dr-x'); await p.waitForTimeout(400);   /* drawer covers the toolbar */
  const dl=p.waitForEvent('download',{timeout:25000});
  await p.click('#csv'); const d=await dl; await d.saveAs('/tmp/fix.csv');
  const txt=fs.readFileSync('/tmp/fix.csv','utf8').replace(/^﻿/,'');
  const split=l=>{const o=[];let cur='',q=false;
    for(let i=0;i<l.length;i++){const ch=l[i];
      if(q){ if(ch==='"'){ if(l[i+1]==='"'){cur+='"';i++;} else q=false; } else cur+=ch; }
      else if(ch==='"') q=true; else if(ch===','){o.push(cur);cur='';} else cur+=ch;}
    o.push(cur); return o;};
  const lines=txt.split('\r\n').filter(x=>x.length);
  const hdr=split(lines[0]);
  const widths=[...new Set(lines.map(l=>split(l).length))];
  ok('every row has exactly as many fields as the header',JSON.stringify(widths),JSON.stringify([hdr.length]));
  const iOff=hdr.indexOf('OFFSET_FT'), iCar=hdr.indexOf('F_CARRIED'), iSrc=hdr.indexOf('VALUE_SOURCE');
  console.log('   OFFSET_FT at '+iOff+', F_CARRIED at '+iCar+', VALUE_SOURCE at '+iSrc);
  const rowFor=bn=>split(lines.find(l=>l.startsWith(bn+',')));
  const r=rowFor(two[1]);
  ok('F_CARRIED column holds carried text, not a shifted value',
     /[A-Z]/.test(r[iCar])&&r[iCar]===String(await p.evaluate(n=>ALL.find(x=>x.BRDG_NBR===n).F_CARRIED,two[1])),true);
  ok('VALUE_SOURCE marks the corrected row',r[iSrc],'REVIEWED');
  ok('VALIDATED_BH06 is the corrected route',r[hdr.indexOf('VALIDATED_BH06')],
     await p.evaluate(n=>ALL.find(x=>x.BRDG_NBR===n)._rid,two[1]));

  console.log('\n11. Review file round-trip, v1 and v2');
  const v2=await p.evaluate(()=>{const out={tool:'x',kind:'review-file',version:2,entries:{}};
    REVIEW.forEach((v,k)=>{out.entries[k]=v;}); return JSON.stringify(out);});
  fs.writeFileSync('/tmp/rev_v2.json',v2);
  fs.writeFileSync('/tmp/rev_v1.json',JSON.stringify(Object.assign(JSON.parse(v2),{version:1})));
  for(const [tag,f] of [['v2','/tmp/rev_v2.json'],['v1','/tmp/rev_v1.json']]){
    await p.evaluate(()=>{REVIEW=new Map(); revalidate(); applyFilters();});
    await p.evaluate(()=>document.getElementById('settings').classList.add('on'));
    await p.evaluate(()=>document.getElementById('revfile').dataset.merge='0');
    await p.setInputFiles('#revfile',f); await p.waitForTimeout(1400);
    const back=await st(p,two[1]);
    ok(tag+' file: correction re-applied and re-validated',back.src,'REVIEWED');
    ok(tag+' file: duplicate finding recomputed on open',back.flags.includes('DUPLICATE_PAIR'),true);
    const toast=await p.evaluate(()=>document.getElementById('toast').textContent);
    console.log('   toast: '+toast.slice(-150));
  }

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
