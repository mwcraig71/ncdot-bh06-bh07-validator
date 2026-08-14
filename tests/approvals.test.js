/* Approvals — the other half of field capture.

   An inspector submits and nothing moves. This suite is about what happens
   next, and the question it keeps asking is not "does the button work" but
   "does the screen tell an approver enough to be right". So most of it is
   about the verdict: a milepoint outside its route's extent, a BH06 proposed
   on a roadway that runs BENEATH the bridge, a route in the wrong county — all
   of them things that pass every FHWA submittal check and are still wrong, put
   in front of the person about to accept them.

   The rest is refusals. Anonymous cannot decide, a signed-in non-approver
   cannot decide, a rejection without a reason is refused before it is sent,
   and the database's own refusals — the last approver, an account that has
   never signed in — arrive as sentences rather than as HTTP codes.

   Every endpoint is mocked, including the route geometry the offset is
   measured against, so nothing here can pass because a service answered. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const FX=JSON.parse(fs.readFileSync('tests/fx/features.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');

const ok=(l,g,w)=>console.log((String(g)===String(w)?'  PASS  ':'  FAIL  ')+l+
  '  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

const F1='11111111-1111-1111-1111-111111111111';   /* 590819 H01, carried, I-85 NBL */
const F2='22222222-2222-2222-2222-222222222222';   /* 590819 H02, below, I-485 inner */
const F3='33333333-3333-3333-3333-333333333333';   /* 590819 H03, below, removal asked */
const F4='44444444-4444-4444-4444-444444444444';   /* 590207, a clean one */
const A1='aaaaaaaa-0000-0000-0000-000000000001';
const A2='aaaaaaaa-0000-0000-0000-000000000002';

/* The queue as the view hands it back. Three of these are wrong in ways FHWA's
   own checks cannot see, which is the whole reason the screen validates. */
const QUEUE=()=>[
  {feature_id:F1, field:'BH07', kind:'value', proposed_value:'30.100',
   proposed_by:'j.hall', proposed_at:'2026-08-10T14:02:00Z', note:'read off the mile marker',
   structure_number:'590819', designation:'H01', location_type:'C', feature_name:'I85NBL',
   county_name:'MECKLENBURG', division:10, published_value:'2.672',
   current_bh06:'10000085060', current_bh07:2.672},
  {feature_id:F2, field:'BH06', kind:'value', proposed_value:'10800485060',
   proposed_by:'j.hall', proposed_at:'2026-08-10T14:05:00Z', note:null,
   structure_number:'590819', designation:'H02', location_type:'B', feature_name:'I485N',
   county_name:'MECKLENBURG', division:10, published_value:null,
   current_bh06:null, current_bh07:null},
  {feature_id:F3, field:null, kind:'removal', proposed_value:'remove H03',
   proposed_by:'j.hall', proposed_at:'2026-08-10T14:09:00Z', note:'ramp was rebuilt in 2019, it is gone',
   structure_number:'590819', designation:'H03', location_type:'B', feature_name:'I485S RAMP',
   county_name:'MECKLENBURG', division:10, published_value:null},
  {feature_id:F4, field:'BH07', kind:'value', proposed_value:'8.774',
   proposed_by:'r.diaz', proposed_at:'2026-08-11T09:30:00Z', note:'picked on the map',
   structure_number:'590207', designation:'H01', location_type:'C', feature_name:'I77',
   county_name:'MECKLENBURG', division:10, published_value:null,
   current_bh06:'10000077060', current_bh07:null},
];
/* Nothing is added here any more. It survives as a marker of the thing the
   queue used to be missing: F4 proposes only a milepoint, and until migration
   0032 the route it is measured on was nowhere in the queue, so the screen
   could not judge the commonest submission there is. */
QUEUE.withRoute=q=>q;

const DIR=()=>[
  {actor:A1, display_name:'m.craig', granted_at:'2026-08-01T00:00:00Z', revoked_at:null,
   revoke_reason:null, granted_by_name:null, revoked_by_name:null, decisions:14},
  {actor:A2, display_name:'t.nguyen', granted_at:'2026-07-02T00:00:00Z', revoked_at:'2026-08-05T00:00:00Z',
   revoke_reason:'moved to Division 7', granted_by_name:'m.craig', revoked_by_name:'m.craig', decisions:3},
];

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

  /* NCDOT: bridges by number, and route geometry by RouteID — the second is
     what the offset is actually measured on, so it is real geometry off the
     live service rather than a straight line. */
  await p.route('**/gis11.services.ncdot.gov/**',async route=>{
    const req=route.request(), u=req.url();
    const pp=new URLSearchParams(req.postData()||''), par=new URLSearchParams(u.split('?')[1]||'');
    const where=pp.get('where')||par.get('where')||'';
    const J=o=>route.fulfill({contentType:'application/json',body:JSON.stringify(o)});
    if(u.includes('Bridges/MapServer/0/query')){
      const off=Number(pp.get('resultOffset')||par.get('resultOffset')||0);
      if(off>0) return J({features:[]});
      const m=/BRDG_NBR IN \(([^)]*)\)/.exec(where);
      if(m){ const want=m[1].split(',').map(s=>s.replace(/'/g,'').trim());
             return J({features:FX.bridges.features.filter(f=>want.includes(String(f.attributes.BRDG_NBR).trim()))}); }
      return J(FX.bridges);
    }
    if(u.includes('RoadCharacteristics')){
      const m=/RouteID='([^']+)'/.exec(where);
      if(m){
        const rid=m[1], out=[];
        Object.values(FX.road).forEach(r=>(r.features||[]).forEach(f=>{
          if(f.attributes&&f.attributes.RouteID===rid&&f.geometry) out.push(f); }));
        return J({features:out});
      }
      return J({features:[]});
    }
    return J({features:[]});
  });

  const snbiRows=FX.snbi.map(r=>Object.assign({},r));
  const m=await sbmock(p,Object.assign({bridges:FX.bridges, snbi:snbiRows},opts));
  return {ctx,p,m};
};

/* A stand-in for the database's own answers. It mutates the queue the way the
   real functions do, so "accept it and the row is gone" is asserted against
   state rather than against a spy. */
function handlers(queue,dir,state){
  const drop=(fid,field)=>{ for(let i=queue.length-1;i>=0;i--)
    if(queue[i].feature_id===fid&&(field===undefined||queue[i].field===field)) queue.splice(i,1); };
  return {
    is_approver:()=>state.approver,
    approve_proposal:a=>{ if(!state.approver) return {status:400,body:{message:'Only a designated approver can accept a proposal.'}};
                          state.calls.push(['approve',a.p_feature,a.p_field,a.p_reason]);
                          drop(a.p_feature,a.p_field); return {approved:true}; },
    reject_proposal:a=>{ if(!a.p_reason) return {status:400,body:{message:'A rejection needs a reason.'}};
                         state.calls.push(['reject',a.p_feature,a.p_field,a.p_reason]);
                         drop(a.p_feature,a.p_field); return {rejected:true}; },
    decide_feature_removal:a=>{ state.calls.push(['removal',a.p_feature,a.p_accept,a.p_reason]);
                                drop(a.p_feature); return {removed:!!a.p_accept}; },
    grant_approver:a=>{ state.calls.push(['grant',a.p_email]);
      if(!/@/.test(a.p_email||'')) return {status:400,body:{message:'Give the work email address of the account to appoint.'}};
      if(/nobody/.test(a.p_email)) return {status:400,body:{message:'No account for '+a.p_email+
        '. They have to sign in once before they can be appointed - the sign-in is what creates the account, and appointing cannot create a person.'}};
      dir.push({actor:'bbbb0000-0000-0000-0000-000000000001', display_name:a.p_email.split('@')[0],
                granted_at:'2026-08-14T00:00:00Z', revoked_at:null, revoke_reason:null,
                granted_by_name:'m.craig', revoked_by_name:null, decisions:0});
      return {granted:true, display_name:a.p_email.split('@')[0]}; },
    revoke_approver:a=>{ state.calls.push(['revoke',a.p_actor]);
      if(dir.filter(d=>!d.revoked_at).length<=1)
        return {status:400,body:{message:'That is the last approver. Appoint somebody else first - with nobody able to decide, every submission from the field stops at the queue.'}};
      const d=dir.find(x=>x.actor===a.p_actor); if(d){ d.revoked_at='2026-08-14T00:00:00Z'; d.revoked_by_name='m.craig'; }
      return {revoked:true}; },
  };
}

const openQueue=async(p,click)=>{
  if(click) await p.click('#apprbtn');
  else await p.evaluate(()=>{ APPR.loaded=false; showApprovals(true); loadQueue(); });
  await p.waitForFunction(()=>APPR.loaded,null,{timeout:20000});
  await p.waitForTimeout(1600); };            /* let the verdicts finish */

(async()=>{
  const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
  const errs=[];

  /* ---------------------------------------------------------------- signed out */
  const queue=QUEUE.withRoute(QUEUE()), dir=DIR();
  const state={approver:false, calls:[]};
  const {p}=await mk(b,{queue, directory:dir, rpc:handlers(queue,dir,state),
    extents:[{route_id:'10000085060',min_mp:0,max_mp:21.155},
             {route_id:'10800485060',min_mp:0,max_mp:65.7},
             {route_id:'10000077060',min_mp:0,max_mp:23.884}]});
  p.on('pageerror',e=>errs.push(e.message));
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);

  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. The queue is public. Deciding is not.');
  ok('the button is in the toolbar before anything is loaded',
     await p.evaluate(()=>!!document.getElementById('apprbtn')),true);
  await openQueue(p,true);
  ok('a signed-out visitor can read the queue',
     await p.evaluate(()=>APPR.items.length),4);
  ok('...and is told plainly that deciding needs an account',
     await p.evaluate(()=>/deciding needs an approver account/i.test(document.getElementById('ascroll').innerText)),true);
  ok('no accept button is drawn for them',
     await p.evaluate(()=>document.querySelectorAll('#ascroll .ayes').length),0);
  ok('the queue replaces the table rather than covering the map',
     await p.evaluate(()=>document.getElementById('tscroll').style.display==='none'
       &&document.getElementById('map').offsetHeight>100),true);
  ok('the count is on the button',
     await p.evaluate(()=>document.getElementById('apprdot').textContent),'4');
  ok('two structures, grouped',
     await p.evaluate(()=>document.querySelectorAll('#ascroll .apprg').length),3);  /* + the approvers card */

  console.log('\n2. The verdict is what the screen is for');
  const v1=await p.evaluate(f=>{const v=APPR.verdicts.get(f);
    return v?{worst:v.worst, txt:v.rows.map(r=>r.s+':'+r.t).join(' || ')}:null;},F1);
  console.log('   H01 BH07 30.100 -> '+(v1&&v1.worst));
  (v1?v1.txt.split(' || '):[]).forEach(t=>console.log('     '+t.slice(0,110)));
  ok('a milepoint past the end of its route is called wrong',v1&&v1.worst,'no');
  ok('...and the message says what the route actually runs',
     /runs 0\.000 to 21\.155/.test(v1?v1.txt:''),true);
  ok('...and names the check FHWA does not run',
     /off the end of it|FHWA does not run/.test(v1?v1.txt:''),true);

  const v2=await p.evaluate(f=>{const v=APPR.verdicts.get(f);
    return v?{worst:v.worst, txt:v.rows.map(r=>r.s+':'+r.t).join(' || ')}:null;},F2);
  console.log('   H02 BH06 on a below feature -> '+(v2&&v2.worst));
  ok('a BH06 proposed on a roadway BENEATH the bridge is refused on B.F.02',
     /BH06-4/.test(v2?v2.txt:'')&&v2.worst==='no',true);
  ok('...and explains where the route ID actually belongs',
     /belongs to whichever structure carries it/.test(v2?v2.txt:''),true);

  const v4=await p.evaluate(f=>{const v=APPR.verdicts.get(f);
    return v?{worst:v.worst, txt:v.rows.map(r=>r.s+':'+r.t).join(' || ')}:null;},F4);
  console.log('   590207 H01 8.774, route from the feature\'s standing pair -> '+(v4&&v4.worst));
  (v4?v4.txt.split(' || '):[]).forEach(t=>console.log('     '+t.slice(0,110)));
  ok('a milepoint submitted on its own is still tested, on the feature\'s own route',
     /Route 10000077060/.test(v4?v4.txt:''),true);
  ok('...and measured against the structure',
     /Lands \d+ ft from the structure/.test(v4?v4.txt:''),true);
  ok('...inside the extent',/Inside the route’s extent/.test(v4?v4.txt:''),true);
  ok('...and the county code is checked against the structure',
     /County code agrees/.test(v4?v4.txt:''),true);
  ok('a removal says why it cannot be checked against the LRS',
     await p.evaluate(f=>{const v=APPR.verdicts.get(f);
       return !!v&&/nothing measures the absence of a road/.test(v.rows.map(r=>r.t).join(' '));},F3),true);
  ok('the structure card carries the worst verdict on it',
     await p.evaluate(()=>!!document.querySelector('#ascroll .apprf.v-no')),true);

  console.log('\n3. Signed in is not the same as approver');
  await p.evaluate(()=>{SESSION.user='u1';SESSION.token='t';SESSION.name='j.hall';applySession();});
  await openQueue(p);
  ok('a signed-in non-approver still gets no buttons',
     await p.evaluate(()=>document.querySelectorAll('#ascroll .ayes').length),0);
  ok('...and is told why, without being told to go away',
     await p.evaluate(()=>/read-only/i.test(document.getElementById('ascroll').innerText)),true);

  console.log('\n4. An approver decides, one at a time');
  state.approver=true;
  await openQueue(p);
  ok('now the buttons are there',
     await p.evaluate(()=>document.querySelectorAll('#ascroll .ayes').length>0),true);
  const before=await p.evaluate(()=>APPR.items.length);
  await p.evaluate(f=>document.querySelector('#ascroll .ayes[data-fid="'+f+'"]').click(),F4);
  await p.waitForTimeout(1200);
  ok('accepting calls approve_proposal for that feature and field',
     JSON.stringify(state.calls[0]),JSON.stringify(['approve',F4,'BH07',null]));
  ok('...and the row leaves the queue',await p.evaluate(()=>APPR.items.length),before-1);

  let dialog='';
  p.on('dialog',d=>d.accept(dialog));
  dialog='';                                   /* an empty reason is not a reason */
  await p.evaluate(f=>document.querySelector('#ascroll .ano[data-fid="'+f+'"]').click(),F1);
  await p.waitForTimeout(900);
  ok('a rejection with no reason never reaches the database',
     state.calls.filter(c=>c[0]==='reject').length,0);
  ok('...and says so',
     await p.evaluate(()=>/rejection needs a reason/i.test(document.getElementById('toast').textContent)),true);

  dialog='30.1 is the mile marker, not the LRS measure';
  await p.evaluate(f=>document.querySelector('#ascroll .ano[data-fid="'+f+'"]').click(),F1);
  await p.waitForTimeout(1200);
  const rej=state.calls.find(c=>c[0]==='reject');
  ok('a rejection with a reason is sent with the reason',rej&&rej[3],'30.1 is the mile marker, not the LRS measure');
  ok('...and that row is gone too',
     await p.evaluate(f=>APPR.items.some(i=>i.feature_id===f),F1),false);

  console.log('\n5. A removal is decided on its own');
  dialog='the ramp is still there, it was realigned not removed';
  await p.evaluate(f=>document.querySelector('#ascroll .ano[data-fid="'+f+'"]').click(),F3);
  await p.waitForTimeout(1200);
  const rm=state.calls.find(c=>c[0]==='removal');
  ok('keeping a feature goes through decide_feature_removal, not reject_proposal',!!rm,true);
  ok('...with accept false',rm&&rm[2],false);
  ok('...and the reason the inspector will read',rm&&/realigned not removed/.test(rm[3]),true);

  console.log('\n6. Accept all on one structure — values only');
  const q2=QUEUE.withRoute(QUEUE()), d2=DIR(), s2={approver:true, calls:[]};
  const {p:p2}=await mk(b,{queue:q2, directory:d2, rpc:handlers(q2,d2,s2),
    extents:[{route_id:'10000085060',min_mp:0,max_mp:21.155},
             {route_id:'10000077060',min_mp:0,max_mp:23.884}]});
  p2.on('pageerror',e=>errs.push(e.message));
  p2.on('dialog',d=>d.accept(''));
  await p2.goto('file://'+FILE); await p2.waitForTimeout(2200);
  await p2.evaluate(()=>{SESSION.user='u1';SESSION.token='t';SESSION.name='m.craig';applySession();});
  await openQueue(p2);
  ok('the offer is on the structure, not on the page',
     await p2.evaluate(()=>document.querySelectorAll('#ascroll .aall').length>0),true);
  await p2.evaluate(()=>acceptStructure('590819'));
  await p2.waitForTimeout(1500);
  ok('every value proposal on that structure was accepted',
     s2.calls.filter(c=>c[0]==='approve').length,2);
  ok('...and the removal was left alone',
     s2.calls.filter(c=>c[0]==='removal').length,0);
  ok('...so the removal is still waiting on somebody',
     await p2.evaluate(f=>APPR.items.some(i=>i.feature_id===f&&i.kind==='removal'),F3),true);
  ok('the other structure was not touched',
     s2.calls.some(c=>c[1]===F4),false);

  console.log('\n7. Who may decide');
  ok('the directory is drawn',
     await p2.evaluate(()=>/m\.craig/.test(document.getElementById('ascroll').innerText)),true);
  ok('a revoked approver is still shown, with who revoked them and why',
     await p2.evaluate(()=>/moved to Division 7/.test(document.getElementById('ascroll').innerText)),true);
  ok('their decision count is on the record',
     await p2.evaluate(()=>/14 decisions/.test(document.getElementById('ascroll').innerText)),true);
  ok('no email address appears anywhere on the page',
     await p2.evaluate(()=>/@/.test(document.getElementById('ascroll').innerText.replace(/placeholder[^\n]*/g,''))),false);

  await p2.evaluate(()=>{document.getElementById('a-email').value='nobody@ncdot.gov';
                         document.getElementById('a-grant').click();});
  await p2.waitForTimeout(1200);
  ok('appointing an account that has never signed in is refused',
     await p2.evaluate(()=>/have to sign in once/.test(document.getElementById('toast').textContent)),true);
  ok('...by the database, not by the page guessing',
     s2.calls.some(c=>c[0]==='grant'),true);

  await p2.evaluate(()=>{document.getElementById('a-email').value='r.diaz@ncdot.gov';
                         document.getElementById('a-grant').click();});
  await p2.waitForTimeout(1500);
  ok('appointing an existing account works',
     await p2.evaluate(()=>APPR.dir.some(d=>d.display_name==='r.diaz'&&!d.revoked_at)),true);
  ok('...and the new approver is drawn without a page reload',
     await p2.evaluate(()=>/r\.diaz/.test(document.getElementById('ascroll').innerText)),true);

  await p2.evaluate(()=>{const n=document.querySelector('#ascroll .arev'); if(n) n.click();});
  await p2.waitForTimeout(1200);
  ok('revoking is sent with the actor, not the name',
     await p2.evaluate(()=>APPR.dir.filter(d=>!d.revoked_at).length),1);

  /* down to one live approver: the database refuses the next one */
  await p2.evaluate(()=>{const n=document.querySelector('#ascroll .arev'); if(n) n.click();});
  await p2.waitForTimeout(1200);
  ok('the last approver cannot be revoked',
     await p2.evaluate(()=>APPR.dir.filter(d=>!d.revoked_at).length),1);
  ok('...and the refusal explains what would happen',
     await p2.evaluate(()=>/stops at the queue/.test(document.getElementById('toast').textContent)),true);

  console.log('\n8. Getting to the bridge');
  ok('every structure card offers to open it',
     await p2.evaluate(()=>document.querySelectorAll('#ascroll .aopen').length>=2),true);
  await p2.evaluate(()=>{ document.getElementById('mode').value='bridge'; buildArg();
                          document.getElementById('arg').value='590207'; });
  await p2.click('#run');
  await p2.waitForFunction(()=>ALL.length>0,null,{timeout:30000});
  await p2.waitForTimeout(800);
  ok('running a scope leaves the approvals view rather than filling a hidden table',
     await p2.evaluate(()=>APPR.open===false&&document.getElementById('tscroll').style.display!=='none'),true);
  ok('...and the queue is still one click away, with its count',
     await p2.evaluate(()=>document.getElementById('apprdot').textContent),'2');

  console.log('\npage errors: '+JSON.stringify(errs.filter(e=>!/ResizeObserver/.test(e))));
  await b.close();
})();
