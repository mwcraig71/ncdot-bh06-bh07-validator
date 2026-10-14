import base64,re,os
h=open('tool_template.html').read()

# ---------------- Supabase project this build talks to -------------------------
# The publishable (anon) key is meant to be in the page. It identifies the
# project and nothing else: what it can actually do is decided by row level
# security, where anon has SELECT and no more. Treating it as a secret would be
# a misunderstanding of what it is.
SB_URL = os.environ.get('SB_URL','https://drstmntdbmacdplhjvmx.supabase.co')
SB_KEY = os.environ.get('SB_KEY','eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRyc3RtbnRkYm1hY2RwbGhqdm14Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2MzMwMDEsImV4cCI6MjEwMjIwOTAwMX0.319PV9Prn8q6qurIMG_SHk63EoRQCv6tkGn_0fiwo7A')
h = h.replace('__SB_URL__',SB_URL).replace('__SB_KEY__',SB_KEY)
def b64(p): return base64.b64encode(open(p,'rb').read()).decode()
import glob
# The skills folder is re-synced under a generated id, so find the logo rather than hard-code it.
LOGO_PATH=os.environ.get('LOGO_PATH') or next(iter(sorted(glob.glob(
    '/root/.claude/skills/synced/**/strinteg-design/assets/logo.png', recursive=True))), None)
if not LOGO_PATH: raise SystemExit('logo.png not found - set LOGO_PATH')
LOGO=b64(LOGO_PATH)

# ---------------- variant A: fully self-contained (NCDOT / offline) -------------
FONTS=[('Oswald',400,'node_modules/@fontsource/oswald/files/oswald-latin-400-normal.woff2'),
       ('Oswald',500,'node_modules/@fontsource/oswald/files/oswald-latin-500-normal.woff2'),
       ('Oswald',700,'node_modules/@fontsource/oswald/files/oswald-latin-700-normal.woff2'),
       ('Open Sans',300,'node_modules/@fontsource/open-sans/files/open-sans-latin-300-normal.woff2'),
       ('Open Sans',600,'node_modules/@fontsource/open-sans/files/open-sans-latin-600-normal.woff2'),
       ('Open Sans',700,'node_modules/@fontsource/open-sans/files/open-sans-latin-700-normal.woff2')]
ff="\n".join("@font-face{font-family:'%s';font-style:normal;font-weight:%d;font-display:swap;"
             "src:url(data:font/woff2;base64,%s) format('woff2')}"%(n,w,b64(p)) for n,w,p in FONTS)
lcss=re.sub(r'url\([^)]*\)','none',open('node_modules/leaflet/dist/leaflet.css').read())
ljs=open('node_modules/leaflet/dist/leaflet.js').read()
# break the 144KB single line so a recursive parser has somewhere to breathe
# (do not reformat minified source — it corrupts string/regex literals)

a=h.replace('<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">',
            '<style>/* Leaflet 1.9.4 */\n'+lcss+'\n</style>')
a=a.replace('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Oswald:wght@300;400;500;700&family=Open+Sans:wght@300;400;600;700&family=Lato:wght@100;300;400;700&display=swap">',
            '<style>/* Embedded webfonts */\n'+ff+'\n</style>')
a=a.replace('<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js"></script>',
            '<script>/* Leaflet 1.9.4 — leafletjs.com (c) Vladimir Agafonkin, BSD-2 */\n'+ljs+'\n</script>')
a=a.replace("--font-d:'Lato',Arial,sans-serif;","--font-d:'Open Sans',Arial,sans-serif;")
# supabase-js inlined too, so the offline copy can still sign a reviewer in on a
# network that allows the project but not a CDN
sbjs=open('node_modules/@supabase/supabase-js/dist/umd/supabase.js').read()
a=re.sub(r'<!--SBJS-->.*?<!--/SBJS-->',
         lambda m: '<script>/* @supabase/supabase-js v2 - MIT */\n'+sbjs+'\n</script>',
         a, flags=re.S)
a=a.replace('__LOGO_B64__',LOGO)
open('NCDOT_BH06_BH07_Validator.html','w').write(a)

# ---------------- variant B: slim, for the Cowork artifact renderer ------------
b=h.replace('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Oswald:wght@300;400;500;700&family=Open+Sans:wght@300;400;600;700&family=Lato:wght@100;300;400;700&display=swap">',
            '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Oswald:wght@300;400;500;700&family=Open+Sans:wght@300;400;600;700&display=swap">')
b=b.replace("--font-d:'Lato',Arial,sans-serif;","--font-d:'Open Sans',Arial,sans-serif;")
b=b.replace('src="data:image/png;base64,__LOGO_B64__"','src="data:image/png;base64,'+LOGO+'"')
open('NCDOT_BH06_BH07_Validator_artifact.html','w').write(b)

# ---------------- variant C: public web build ---------------------------------
# There is nothing left to strip. The gate is gone from the source itself: what
# a person may do is decided by row level security on the Supabase project, and
# all three builds now carry exactly the same code. The only difference here is
# public-page metadata.
def public_meta(src):
    src=src.replace('<title>NCDOT SNBI BH Validator</title>',
      '<title>NCDOT SNBI BH Validator \u2014 Strinteg</title>\n'
      '<meta name="description" content="Free browser tool that validates SNBI items BH06 (LRS Route ID) and '
      'BH07 (LRS Milepoint) for every North Carolina bridge against FHWA\'s published rules and NCDOT\'s live GIS. '
      'By Strinteg Corporation.">\n'
      '<meta name="robots" content="index,follow">\n'
      '<meta property="og:type" content="website">\n'
      '<meta property="og:title" content="NCDOT SNBI BH Validator">\n'
      '<meta property="og:description" content="Validate BH06 and BH07 for any NC bridge, route, county or the whole '
      'state against FHWA rules, NCDOT\'s LRS and the FHWA HPMS submittal. Runs entirely in your browser.">\n'
      '<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 32 32\'%3E'
      '%3Crect width=\'32\' height=\'32\' fill=\'%23CF3910\'/%3E%3Cpath d=\'M5 20h22M8 20V13M16 20V10M24 20V15\' '
      'stroke=\'white\' stroke-width=\'2.4\' fill=\'none\'/%3E%3C/svg%3E">')
    return src

web=public_meta(b)                     # start from the CDN-light variant
os.makedirs('web',exist_ok=True)
open('web/index.html','w').write(web)
open('web/robots.txt','w').write("User-agent: *\nAllow: /\n")

for f in ('NCDOT_BH06_BH07_Validator.html','NCDOT_BH06_BH07_Validator_artifact.html','web/index.html'):
    t=open(f).read()
    print(f"{f:<46}{round(len(t)/1024):>5} KB   longest line {round(max(len(l) for l in t.split(chr(10)))/1024):>4} KB")
