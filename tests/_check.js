/* Shared by every suite.

   tally(): each suite's ok() passes its comparison through here, so the process
   knows how many assertions failed. A FAIL used to print and the suite still
   exited 0, so a broken build passed any script that checked the exit code.
   Now a suite exits 1 if any assertion failed, or if it made none at all (it
   stopped before reaching them).

   CHROMIUM: the suites were written on a machine with Chromium at
   /opt/pw-browsers/chromium. That path is still used when it exists. Elsewhere
   PW_CHROMIUM names a browser, and with neither, Playwright uses its own
   (`npx playwright install chromium`). */
const fs = require('fs');

let pass = 0, fail = 0;
function tally(passed) { if (passed) pass++; else fail++; return passed; }

const CHROMIUM = process.env.PW_CHROMIUM ||
  (fs.existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined);

process.on('exit', code => {
  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  if (code === 0 && (fail > 0 || pass === 0)) process.exitCode = 1;
});

module.exports = { tally, CHROMIUM };
