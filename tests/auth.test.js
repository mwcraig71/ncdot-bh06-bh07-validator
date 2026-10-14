/* The gate is gone, identity comes from the account, and the client-side
   signed-in flag decides nothing. */
const {chromium}=require('playwright');const fs=require('fs');
const sbmock=require('./fx/sbmock.js');
const bridges=JSON.parse(fs.readFileSync('tests/fx/bridges.json','utf8'));
const FILE=require('path').resolve(process.argv[2]||'dist/NCDOT_BH06_BH07_Validator.html');

const SB='https://drstmntdbmacdplhjvmx.supabase.co';
const mk=async(b,opts={})=>{
  const ctx=await b.newContext({acceptDownloads:true,viewport:{width:1500,height:1000}});
  const p=await ctx.newPage();
  const authCalls=[];
  const tile=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8//9/PQAJewN9nQAyAQAAAABJRU5ErkJggg==','base64');
  await p.route('**/cdnjs.cloudflare.com/**',r=>{const u=r.request().url();
    if(/\.css/.test(u)) return r.fulfill({contentType:'text/css',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.css','utf8')});
    if(/leaflet\.js/.test(u)) return r.fulfill({contentType:'application/javascript',body:fs.readFileSync('node_modules/leaflet/dist/leaflet.js','utf8')});
    return r.fulfill({body:''});});
  await p.route('**/cdn.jsdelivr.net/**',r=>r.fulfill({contentType:'application/javascript',
    body:fs.readFileSync('node_modules/@supabase/supabase-js/dist/umd/supabase.js','utf8')}));
  await p.route('**/server.arcgisonline.com/**',r=>r.fulfill({contentType:'image/png',body:tile}));
  await p.route('**/geo.dot.gov/**',r=>r.fulfill({contentType:'application/json',body:'{"features":[]}'}));
  await p.route('**/gis11.services.ncdot.gov/**',r=>{const u=r.request().url();
    const off=+((u.match(/resultOffset=(\d+)/)||[])[1]||0);
    if(u.includes('Bridges/MapServer/0/query'))
      return r.fulfill({contentType:'application/json',body:JSON.stringify(off>0?{features:[]}:bridges)});
    return r.fulfill({contentType:'application/json',body:'{"features":[]}'});});
  await sbmock(p,{bridges});
  // Supabase auth, mocked so the suite needs no network and no real account
  await p.route(SB+'/auth/v1/**',async r=>{
    const u=r.request().url();
    authCalls.push({url:u.replace(SB,''),body:r.request().postData()});
    if(/\/otp/.test(u)) return r.fulfill({status:200,contentType:'application/json',body:'{}'});
    return r.fulfill({status:200,contentType:'application/json',body:'{}'});
  });
  return {ctx,p,authCalls};
};
const {tally,CHROMIUM}=require('./_check');
const ok=(l,g,w)=>console.log((tally(String(g)===String(w))?'  PASS  ':'  FAIL  ')+l+'  got '+JSON.stringify(g)+', expected '+JSON.stringify(w));

(async()=>{
  const b=await chromium.launch({executablePath:CHROMIUM});
  const {p,authCalls}=await mk(b);
  const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  p.on('dialog',d=>d.accept(''));
  await p.goto('file://'+FILE); await p.waitForTimeout(2200);

  console.log('\nFILE: '+FILE.split('/').pop());

  console.log('\n1. The gate machinery is gone from the shipped file');
  const src=fs.readFileSync(FILE,'utf8');
  for(const [name,re] of [['isAdmin(',/\bisAdmin\s*\(/],['needAdmin(',/\bneedAdmin\s*\(/],
      ['sha( password hasher',/async function sha\s*\(/],['const AUTH=',/const AUTH\s*=/],
      ['let ROLE=',/let ROLE\s*=/],['PRISTINE',/PRISTINE/],['strip_gate markers',/GATEJS-(START|END)/],
      ['#gate overlay',/id="gate"/],['#admin dialog',/id="admin"/],['Passwords button',/id="pwbtn"/],
      ['password input',/type="password"/]])
    ok('no '+name+' in the build',re.test(src),false);

  console.log('\n2. Nothing blocks reading, signed out');
  ok('no gate overlay showing',await p.evaluate(()=>!document.getElementById('gate')),true);
  ok('signed out at load',await p.evaluate(()=>signedIn()),false);
  ok('identity label says so',await p.evaluate(()=>document.getElementById('whoami').textContent),'Not signed in');
  await p.evaluate(()=>{const a=document.getElementById('autoheavy'),h=document.getElementById('autohpms');
    if(a)a.checked=false; if(h)h.checked=false;});
  await p.selectOption('#mode','county'); await p.waitForTimeout(300);
  await p.selectOption('#arg','MECKLENBURG'); await p.click('#run');
  await p.waitForFunction(()=>ALL.length>0,null,{timeout:60000}); await p.waitForTimeout(2000);
  ok('a signed-out visitor still gets every row',await p.evaluate(()=>ALL.length),1282);
  ok('and can still export',await p.evaluate(()=>!document.getElementById('csv').disabled),true);

  console.log('\n3. Reviewer name comes from the account, not a text box');
  ok('the free-text Reviewer input is gone',await p.evaluate(()=>!document.getElementById('reviewer')),true);
  ok('REVIEWER variable is gone',await p.evaluate(()=>typeof REVIEWER==='undefined'),true);
  ok('reviewerName() is empty when signed out',await p.evaluate(()=>reviewerName()),'');

  console.log('\n4. Sign-in is a link, never a password');
  await p.click('#setbtn'); await p.waitForTimeout(400);
  ok('sign-in panel visible when signed out',
     await p.evaluate(()=>getComputedStyle(document.getElementById('signinbox')).display!=='none'),true);
  ok('sign-out panel hidden',
     await p.evaluate(()=>getComputedStyle(document.getElementById('signoutbox')).display),'none');
  ok('the email field is type=email, not password',
     await p.evaluate(()=>document.getElementById('signinemail').type),'email');
  await p.fill('#signinemail','not-an-email');
  await p.click('#signinbtn'); await p.waitForTimeout(400);
  ok('a bad address is refused locally',
     /work email/.test(await p.evaluate(()=>document.getElementById('signinmsg').textContent)),true);
  await p.fill('#signinemail','jsmith@ncdot.gov');
  await p.click('#signinbtn'); await p.waitForTimeout(900);
  const otp=authCalls.filter(c=>/otp/.test(c.url));
  ok('a magic-link request went out',otp.length,1);
  ok('...carrying the address and no password',
     !!otp[0] && /jsmith@ncdot\.gov/.test(otp[0].body||'') && !/password/i.test(otp[0].body||''),true);
  console.log('   request body: '+(otp[0]?otp[0].body:'(none)'));

  console.log('\n5. A session shows the identity and reveals the controls');
  await p.evaluate(()=>setSession({access_token:'fake-token',
    user:{id:'11111111-2222-3333-4444-555555555555',email:'jsmith@ncdot.gov',
          user_metadata:{full_name:'J. Smith'}}}));
  await p.waitForTimeout(500);
  ok('signedIn()',await p.evaluate(()=>signedIn()),true);
  ok('name from the account',await p.evaluate(()=>reviewerName()),'J. Smith');
  ok('header shows it',await p.evaluate(()=>document.getElementById('whoami').textContent),'J. Smith');
  ok('sign-out panel now visible',
     await p.evaluate(()=>getComputedStyle(document.getElementById('signoutbox')).display!=='none'),true);

  console.log('\n6. No display name set falls back to the local part, never the address');
  await p.evaluate(()=>setSession({access_token:'t',
    user:{id:'22222222-3333-4444-5555-666666666666',email:'mwcraig@strinteg.com',user_metadata:{}}}));
  await p.waitForTimeout(300);
  const nm=await p.evaluate(()=>reviewerName());
  ok('label is the local part',nm,'mwcraig');
  ok('and carries no @',/@/.test(nm),false);

  console.log('\n7. The exported record carries the account name, not a typed one');
  await p.click('#set-x'); await p.waitForTimeout(300);
  await p.evaluate(()=>{const bn=ALL[0].BRDG_NBR; const r=rec(bn,true);
    r.status='progress'; r.note='checked with Div 10'; touch(bn); revalidate(); applyFilters();});
  await p.waitForTimeout(400);
  const by=await p.evaluate(()=>REVIEW.get(ALL[0].BRDG_NBR).by);
  ok('the review record is stamped with the account name',by,'mwcraig');
  const dl=p.waitForEvent('download',{timeout:20000});
  await p.click('#setbtn'); await p.waitForTimeout(300); await p.click('#revsave');
  const d=await dl; await d.saveAs('/tmp/auth_rev.json');
  const j=JSON.parse(fs.readFileSync('/tmp/auth_rev.json','utf8'));
  ok('the review file says who saved it',j.savedBy,'mwcraig');
  ok('the filename carries the account name',/mwcraig/.test(d.suggestedFilename()),true);

  console.log('\n8. The client-side flag decides nothing');
  console.log('   Signing out, then forging the flag from the console as anyone could:');
  await p.evaluate(()=>setSession(null));
  await p.waitForTimeout(300);
  ok('signed out clears the token',await p.evaluate(()=>SESSION.token),null);
  await p.evaluate(()=>{SESSION.user='forged'; SESSION.name='Someone Else'; applySession();});
  await p.waitForTimeout(300);
  ok('the interface believes it — controls come back',await p.evaluate(()=>signedIn()),true);
  console.log('   ...and that is fine, because it buys nothing: every write goes to Postgres,');
  console.log('   where anon has SELECT and no INSERT, UPDATE or DELETE on any table.');
  console.log('   Proven separately against the live project by anon_api_test.sh (32/32),');
  console.log('   which gets 401 "permission denied for table" on all 16 write attempts.');
  const hasToken=await p.evaluate(()=>!!SESSION.token);
  ok('a forged flag does not conjure a token to send',hasToken,false);

  console.log('\npage errors: '+JSON.stringify(errs));
  await b.close();
})();
