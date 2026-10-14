/* B.H.09, B.H.10 and B.H.11 — traffic, per feature.

   The claim being tested is not "an AADT appears". It is that the number that
   appears is the CURRENT COUNTED one, that it says which year it was counted,
   that the truck figure is derived from a share rather than copied forward from
   an older count, and that where nothing was counted the estimate says so and
   carries its interval.

   That matters because the thing being replaced — the AADT on NCDOT's bridge
   record — looks identical on screen and is none of those things: in
   Mecklenburg 83% of them equal a station value exactly, with no year attached
   and no way to tell which year it was.

   Every endpoint is mocked. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FX=JSON.parse(fs.readFileSync('tests/fx/features.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');
const {tally,CHROMIUM}=require('./_check');
const ok=(l,g,w)=>console.log((tally(String(g)===String(w))?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

const I85='10000085060';      /* 590819 carries this at MP 2.672 */
const I485N='10800485060';    /* and this runs beneath it */
const I77='10000077060';      /* 590207, at MP 8.774 */
const NC51='30000051060';     /* 590668 */

/* su_pct and mu_pct are FRACTIONS. Checked against all 12,673 NCDOT segments
   that carry both a truck count and a share: 12,672 satisfy AADTT = AADT x
   share and only 398 would satisfy AADT x share / 100. A hundred-fold error
   here would be invisible on a single bridge and wrong statewide. */
const TRAFFIC=()=>[
  /* the carried roadway: counted in 2024, share measured in 2022 */
  {route_id:I85, begin_mp:0, end_mp:4.5, tms_id:'0600001312', segment_aadt:143000,
   segment_aadtt:15000, su_pct:0.027, mu_pct:0.078, value_year:2022,
   location_id:'0600001312', station_location:'I-85 between EXIT 28 AND EXIT 30',
   coll_cycle:'A', aadt_year:2024, aadt:158000},
  /* the roadway beneath has its own traffic, and it is not the same number */
  {route_id:I485N, begin_mp:40, end_mp:50, tms_id:'0600000260', segment_aadt:96000,
   segment_aadtt:5000, su_pct:0.021, mu_pct:0.031, value_year:2022,
   location_id:'0600000260', station_location:'I-485 between EXIT 10 AND EXIT 12',
   coll_cycle:'E', aadt_year:2024, aadt:104000},
  /* a station whose last count is old: B.H.11 says so rather than hiding it */
  {route_id:I77, begin_mp:0, end_mp:20, tms_id:'0600000853', segment_aadt:79500,
   segment_aadtt:4530, su_pct:0.030, mu_pct:0.027, value_year:2016,
   location_id:'0600000853', station_location:'I-77 between EXIT 1 AND EXIT 3',
   coll_cycle:'S', aadt_year:2016, aadt:79500},
];
/* No segment covers NC-51 at all, so the probe stands in. */
const PROBE=()=>[
  {route_id:NC51, begin_mp:0, end_mp:30, estimated:3380, lo95:2400, hi95:5200, data_year:2023},
];

/* what the mocked pin tool answers with; the suite moves it between cases */
let PINRID=I485N, PINMP=45;

const mk=async(b,opts={})=>{
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
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('Bridges/MapServer/0/query')){
      const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
      return J(off>0?{features:[]}:FX.bridges); }
    if(u.includes('RoadCharacteristics')) return J({features:[]});
    /* NCDOT's route/milepost tool: submit, poll, read. The pin is the only way
       into the tool that starts from a POINT rather than from a bridge record,
       so the traffic lookup has to work from what it returns. */
    if(u.includes('submitJob')) return J({jobId:'j1',jobStatus:'esriJobSubmitted'});
    if(/\/jobs\/j1\?/.test(u)) return J({jobId:'j1',jobStatus:'esriJobSucceeded'});
    if(u.includes('IdentifyRouteMPResults')) return J({value:{features:[{attributes:
      {RID:PINRID, MEAS:PINMP, RouteName:'I-485', StreetName:'W I-485 Inner Hy'}}]}});
    return J({features:[]});
  });
  const m=await sbmock(p,Object.assign({bridges:FX.bridges,snbi:FX.snbi.map(x=>Object.assign({},x)),
    traffic:TRAFFIC(), probe:PROBE()},opts));
  return {ctx,p,m};
};

const boot=async p=>{
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms'),
                        t=document.getElementById('autotraffic');
    if(a)a.checked=false; if(h)h.checked=false; if(t)t.checked=false;});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000});
  await p.evaluate(()=>loadSNBI()); await p.waitForTimeout(1500);
};

(async()=>{
  const b=await chromium.launch({executablePath:CHROMIUM});
  const {p,m}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message)); p.on('dialog',d=>d.accept(''));
  await boot(p);

  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. Nothing is claimed before the data is read');
  ok('with the switch off, Run asks the traffic tables for nothing',
     m.reads('traffic_client').length,0);
  ok('a feature with no lookup yet says so rather than showing a blank',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
       const f=featuresOf(x).find(z=>isRowFeature(z));
       return f.tr===undefined;}),true);
  ok('...and raises no traffic finding either',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
       const f=featuresOf(x).find(z=>isRowFeature(z));
       return (f.flags||[]).some(g=>g.indexOf('AADT')===0);}),false);

  console.log('\n2. The count station is the source, and it is dated');
  await p.evaluate(()=>trafficCheck());
  await p.waitForFunction(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
    const f=featuresOf(x).find(z=>isRowFeature(z)); return f&&f.tr;},null,{timeout:30000});
  await p.waitForTimeout(600);
  const t=await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
    return featuresOf(x).find(z=>isRowFeature(z)).tr;});
  console.log('   590819 carried: BH09 '+t.aadt+'  BH10 '+t.aadtt+'  BH11 '+t.year+
              '  ('+t.basis+', share '+t.share+' from '+t.shareYear+')');
  ok('BH09 is the station\'s current count, not the segmentation\'s older value',t.aadt,158000);
  ok('...and not the undated figure on the bridge record',
     await p.evaluate(()=>Number(ALL.find(y=>y.BRDG_NBR==='590819').AADT)),155000);
  ok('BH11 is the year that count was taken',t.year,2024);
  ok('the basis is recorded as a count',t.basis,'count');
  ok('...and so is the station it came from',t.station,'0600001312');

  console.log('\n3. Trucks are a share carried forward, not a count carried forward');
  ok('BH10 is the current total times the measured share',t.aadtt,Math.round(158000*(0.027+0.078)));
  ok('...which is NOT the segmentation\'s own truck count',t.aadtt===15000,false);
  ok('the share is treated as a fraction, not a percentage',
     Math.abs(t.share-0.105)<1e-9,true);
  /* If the share were divided by 100 the answer would be 163 rather than 16,275.
     On one bridge that reads as a small number; statewide it is every truck
     figure wrong by two orders of magnitude. */
  ok('...so BH10 is in the thousands, not the hundreds',t.aadtt>10000,true);
  ok('the year the share came from is kept',t.shareYear,2022);
  ok('...and the panel says the share was applied to the current count',
     await p.evaluate(()=>{select('590819',true);
       return /share measured in 2022 applied to the current count/.test(document.getElementById('dr-body').innerText);}),true);

  console.log('\n4. Every feature has its own traffic, because every feature has its own road');
  /* Opening a bridge measures its features, and that rebuilds the feature list.
     Let it finish before touching one, or the edit lands on an object that is
     about to be replaced. */
  await p.waitForFunction(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
    return x&&(x._featDone||x._featErr);},null,{timeout:30000});
  await p.waitForTimeout(400);
  const below=await p.evaluate(async()=>{
    const x=ALL.find(y=>y.BRDG_NBR==='590819');
    /* 590819's Feature Crossed already names I485 beneath it, so the feature is
       there — it just has no route yet, because this suite mocks the road
       network away. Resolving it by hand is what "Resolve named features" does,
       and what is under test is that the traffic then attaches to THAT feature
       rather than to the bridge. */
    const u=featuresOf(x).find(z=>z.loc==='B');
    if(!u) return {f:null, why:'no below feature to resolve', all:featuresOf(x).map(z=>z.des+':'+z.loc)};
    u.rid='10800485060'; u.mp=45; u.resolved=true;
    await loadTraffic(['10800485060']);
    featuresOf(x).forEach(f=>attachTraffic(x,f));
    rollUpFeatures(x); revalidate();
    const f=featuresOf(x).filter(z=>z.loc==='B'&&/^\d{11}$/.test(z.rid||''))[0];
    return {f:f?{des:f.des,rid:f.rid,tr:f.tr}:null,
            all:featuresOf(x).map(z=>({des:z.des,loc:z.loc,rid:z.rid,tr:z.tr?z.tr.aadt:z.tr}))};});
  console.log('   '+below.all.map(a=>a.des+' '+a.loc+' '+(a.rid||'-')+' AADT '+(a.tr||'-')).join('  |  '));

  ok('the roadway beneath reports its own AADT',
     !!(below.f&&below.f.tr&&below.f.tr.aadt===104000),true);
  ok('...which is not the carried roadway\'s',
     !!(below.f&&below.f.tr&&below.f.tr.aadt!==t.aadt),true);
  ok('...and its own station',
     below.f&&below.f.tr?below.f.tr.station:'',"0600000260");

  console.log('\n5. Where nothing was counted, the estimate says so');
  const pr=await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590668');
    const f=featuresOf(x).find(z=>isRowFeature(z)); return f?f.tr:null;});
  console.log('   590668: '+(pr?pr.aadt+' '+pr.basis+' ['+pr.lo+'–'+pr.hi+']':'none'));
  ok('the probe estimate stands in',pr&&pr.basis,'probe');
  ok('...with its 95% interval attached',!!(pr&&pr.lo===2400&&pr.hi===5200),true);
  ok('...and it is flagged as an estimate rather than a count',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590668');
       return (featuresOf(x).find(z=>isRowFeature(z)).flags||[]).includes('AADT_PROBE');}),true);
  ok('the panel prints the interval, not just the number',
     await p.evaluate(()=>{select('590668',true);
       return /95% confidence 2,400 to 5,200/.test(document.getElementById('dr-body').innerText);}),true);
  ok('...and the table marks it too',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590668'); return /est/.test(cell(x,'_aadt'));}),true);

  console.log('\n6. An old count is reported as old, not hidden');
  const st=await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590207');
    const f=featuresOf(x).find(z=>isRowFeature(z));
    return f?{tr:f.tr,flags:f.flags}:null;});
  ok('the year is the year it was actually counted',st&&st.tr?st.tr.year:0,2016);
  ok('...and that raises a finding rather than passing quietly',
     !!(st&&st.flags.includes('AADT_STALE')),true);
  ok('the table shades the old year',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590207'); return /C9A227/.test(cell(x,'_aadty'));}),true);

  console.log('\n6b. The published copy that matches nothing');
  ok('590819\u2019s record AADT matches neither the count nor the older segment value',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
       return (featuresOf(x).find(z=>isRowFeature(z)).flags||[]).includes('AADT_PUBLISHED_ODD');}),true);
  ok('...and a record that DOES match the count raises nothing',
     await p.evaluate(()=>{const x=ALL.find(y=>y.BRDG_NBR==='590819');
       const keep=x.AADT; x.AADT=158000; revalidate();
       const has=(featuresOf(x).find(z=>isRowFeature(z)).flags||[]).includes('AADT_PUBLISHED_ODD');
       x.AADT=keep; revalidate(); return has;}),false);

  console.log('\n7. The arithmetic checks');
  const arith=await p.evaluate(()=>{
    const seg={route_id:'99999999999',begin_mp:0,end_mp:10,tms_id:'X',segment_aadt:1000,
               segment_aadtt:9000,su_pct:0.6,mu_pct:0.3,value_year:2022,location_id:'X',
               aadt_year:2024,aadt:1000};
    TRAFFIC.set('99999999999',[seg]); TRAFFICASKED.add('99999999999');
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const f={des:'ZZ',loc:'C',primary:false,rid:'99999999999',mp:5,routes:[],_ord:990};
    const flags=trafficFlags(b,f);
    return {flags, tr:f.tr};});
  ok('a truck share above anything measured statewide is flagged',
     arith.flags.includes('AADTT_SHARE'),true);
  const over=await p.evaluate(()=>{
    TRAFFIC.set('88888888888',[{route_id:'88888888888',begin_mp:0,end_mp:10,tms_id:'Y',
      segment_aadt:1000,segment_aadtt:5000,su_pct:null,mu_pct:null,value_year:2022,
      location_id:'Y',aadt_year:2024,aadt:1000}]);
    TRAFFICASKED.add('88888888888');
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const f={des:'ZZ',loc:'C',primary:false,rid:'88888888888',mp:5,routes:[],_ord:991};
    return trafficFlags(b,f);});
  ok('trucks exceeding the total is an error, not a warning',over.includes('AADTT_OVER'),true);
  ok('...and it is graded as one',
     await p.evaluate(()=>RULEMAP.AADTT_OVER.sev),'e');

  console.log('\n8. A road with no traffic data at all');
  const none=await p.evaluate(()=>{
    TRAFFICASKED.add('77777777777');
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const c={des:'ZC',loc:'C',primary:false,rid:'77777777777',mp:5,routes:[],_ord:992};
    const u={des:'ZB',loc:'B',primary:false,rid:'77777777777',mp:5,routes:[],_ord:993};
    return {carried:trafficFlags(b,c), below:trafficFlags(b,u)};});
  ok('a carried roadway with nothing is flagged',none.carried.includes('AADT_NONE'),true);
  ok('...and a roadway beneath gets its own wording, because the fix differs',
     none.below.includes('AADT_NONE_BELOW'),true);
  ok('the below rule talks about the traffic underneath the bridge',
     await p.evaluate(()=>/traffic BELOW/.test(RULEMAP.AADT_NONE_BELOW.d)),true);

  console.log('\n9. Correcting BH07 moves the traffic with it');
  const moved=await p.evaluate(()=>{
    TRAFFIC.set('66666666666',[
      {route_id:'66666666666',begin_mp:0,end_mp:5,tms_id:'A',segment_aadt:1000,segment_aadtt:100,
       su_pct:0.05,mu_pct:0.05,value_year:2022,location_id:'A',aadt_year:2024,aadt:1000},
      {route_id:'66666666666',begin_mp:5,end_mp:10,tms_id:'B',segment_aadt:9000,segment_aadtt:900,
       su_pct:0.05,mu_pct:0.05,value_year:2022,location_id:'B',aadt_year:2024,aadt:9000}]);
    TRAFFICASKED.add('66666666666');
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const f={des:'ZM',loc:'C',primary:false,rid:'66666666666',mp:2,routes:[],_ord:994};
    trafficFlags(b,f); const first=f.tr.aadt;
    f.mp=7; trafficFlags(b,f);
    return {first, then:f.tr.aadt};});
  ok('a milepoint in the first stretch reads that stretch',moved.first,1000);
  ok('...and moving it reads the other one, rather than the value it cached',moved.then,9000);

  console.log('\n10. It reaches the table and the export');
  ok('BH09, BH10 and BH11 are columns',
     await p.evaluate(()=>['_aadt','_aadtt','_aadty'].every(k=>COLS.some(c=>c.k===k))),true);
  ok('...and they sort and filter as numbers',
     await p.evaluate(()=>['_aadt','_aadtt','_aadty'].every(k=>NUMCOL[k])),true);
  ok('a comparison filter works on them',
     await p.evaluate(()=>{COLF._aadt='>100000';
       const n=VIEW.filter(passesColumns).length; COLF._aadt=''; return n>0;}),true);
  const csv=await p.evaluate(()=>{
    let cap=null; const old=URL.createObjectURL;
    URL.createObjectURL=b=>{cap=b; return 'blob:x';};
    exportCSV(); URL.createObjectURL=old;
    return cap? cap.text() : '';});
  const head=csv.split('\n')[0];
  ok('the CSV carries the three items',
     ['BH09_AADT','BH10_AADTT','BH11_AADT_YEAR'].every(c=>head.includes(c)),true);
  ok('...and enough beside them to say what each one is',
     ['AADT_BASIS','AADT_STATION','AADT_TRUCK_SHARE','AADT_SHARE_YEAR','AADT_PROBE_LO95'].every(c=>head.includes(c)),true);
  ok('...including what NCDOT\'s own record says, for comparison',
     head.includes('NCDOT_RECORD_AADT'),true);
  /* Split on commas OUTSIDE quotes — Feature Carried is full of commas, and a
     naive split makes an aligned file look ragged and a ragged one look fine. */
  const fields=l=>{const out=[];let cur='',q=false;
    for(let i=0;i<l.length;i++){const c=l[i];
      if(c==='"'){ if(q&&l[i+1]==='"'){cur+='"';i++;} else q=!q; }
      else if(c===','&&!q){ out.push(cur); cur=''; }
      else cur+=c; }
    out.push(cur); return out;};
  const cols=fields(head);
  const rows=csv.split('\n').slice(1).filter(Boolean).map(fields);
  ok('the header and the rows still line up',
     rows.every(r=>r.length===cols.length)&&rows.length>0,true);
  const r819=rows.find(r=>r[0]==='590819')||[];
  ok('...and BH09 for 590819 is the value the panel showed',
     r819[cols.indexOf('BH09_AADT')],String(t.aadt));
  ok('...beside what NCDOT publishes, undated',
     r819[cols.indexOf('NCDOT_RECORD_AADT')],'155000');
  ok('...and the basis is spelled out rather than coded',
     r819[cols.indexOf('AADT_BASIS')],'COUNTED');
  const r668=rows.find(r=>r[0]==='590668')||[];
  ok('a probe row says so, and carries its interval',
     r668[cols.indexOf('AADT_BASIS')]+' '+r668[cols.indexOf('AADT_PROBE_LO95')]+
     '-'+r668[cols.indexOf('AADT_PROBE_HI95')],'PROBE ESTIMATE 2400-5200');

  console.log('\n11. The pin drop reports the three items for the point clicked');
  PINRID=I485N; PINMP=45;
  await p.evaluate(()=>{PINTARGET=null; SEL=null;});
  await p.evaluate(()=>pinAt(35.24,-80.96));
  await p.waitForFunction(()=>!!document.querySelector('.leaflet-popup-content'),null,{timeout:30000});
  const pop=await p.evaluate(()=>document.querySelector('.leaflet-popup-content').innerText);
  console.log('   '+pop.replace(/\n+/g,' | ').slice(0,190));
  ok('the popup carries BH09',/104,000 AADT \(BH09\)/.test(pop),true);
  ok('...BH10',/5,408 trucks \(BH10\)/.test(pop),true);
  ok('...and BH11, as the year it was counted',/counted in 2024 \(BH11\)/.test(pop),true);
  ok('...and says which station it came from',/station 0600000260/.test(pop),true);
  ok('the road and the milepoint are still the headline',
     /10800485060/.test(pop)&&/45\.000/.test(pop),true);

  /* A point on a road no station governs: the estimate, with its interval. */
  PINRID=NC51; PINMP=5;
  await p.evaluate(()=>{map.closePopup();});
  await p.evaluate(()=>pinAt(35.12,-80.70));
  await p.waitForFunction(()=>{const n=document.querySelector('.leaflet-popup-content');
    return n&&/3,380/.test(n.innerText);},null,{timeout:30000});
  const pop2=await p.evaluate(()=>document.querySelector('.leaflet-popup-content').innerText);
  ok('a probe-covered point says the figure is estimated',/estimated/i.test(pop2),true);
  ok('...and prints the interval rather than the bare number',
     /95% confidence 2,400 to 5,200/.test(pop2),true);

  /* And a road with nothing at all says so, rather than showing an empty slot. */
  PINRID='55555555555'; PINMP=1;
  await p.evaluate(()=>{map.closePopup();});
  await p.evaluate(()=>pinAt(35.13,-80.71));
  await p.waitForFunction(()=>{const n=document.querySelector('.leaflet-popup-content');
    return n&&/No AADT covers this point/.test(n.innerText);},null,{timeout:30000});
  ok('a point with no traffic data says so',true,true);

  console.log('\n11b. Confirming a pin shows the traffic it would bring with it');
  PINRID=I485N; PINMP=45;
  await p.evaluate(()=>{map.closePopup();});
  const conf=await p.evaluate(async()=>{
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const f=featuresOf(b).find(z=>z.loc==='B');
    SEL='590819'; PINTARGET={bn:'590819',des:f.des};
    await pinAt(35.24,-80.96);
    return {tr:PENDPIN&&PENDPIN.tr?PENDPIN.tr.aadt:null,
            txt:document.getElementById('dr-body').innerText};});
  ok('the confirmation card carries the AADT the road would bring',conf.tr,104000);
  ok('...printed before the yes, not after it',
     /104,000 AADT/.test(conf.txt)&&/is this the road you meant/i.test(conf.txt),true);
  ok('...with the trucks and the year beside it',
     /5,408 trucks/.test(conf.txt)&&/counted 2024/.test(conf.txt),true);
  const took=await p.evaluate(()=>{
    document.querySelector('a.pinyes').click();
    const b=ALL.find(x=>x.BRDG_NBR==='590819');
    const f=featuresOf(b).find(z=>z.rid==='10800485060');
    return f&&f.tr?{aadt:f.tr.aadt,year:f.tr.year}:null;});
  ok('and accepting it carries the traffic onto the feature',
     took?took.aadt+'@'+took.year:'',"104000@2024");

  console.log('\n12. The reads are scoped, and asked for once');
  const reads=m.reads('traffic_client');
  ok('traffic is read by route, not wholesale',
     reads.length>0&&reads.every(r=>/route_id=in\./.test(r.url)),true);
  const before=m.reads('traffic_client').length;
  await p.evaluate(()=>trafficCheck());
  await p.waitForTimeout(1200);
  ok('...and a second pass asks for nothing it already holds',
     m.reads('traffic_client').length,before);

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
