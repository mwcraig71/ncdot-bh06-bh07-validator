/* A stand-in for the Supabase REST API, backed by the same fixtures the ArcGIS
   mocks used to serve.

   Since Prompt 0c the browser reads its reference data from PostgREST rather
   than from NCDOT and FHWA, so the suites have to mock PostgREST or they test
   nothing. This is deliberately a real little query engine — it honours
   `limit`, `offset`, `in.()` and `eq.` — because the things worth asserting are
   exactly whether the client scopes its reads and whether it pages past the
   1,000-row ceiling. A mock that ignored those would pass either way.

   Every request is recorded in `.log`, which is what the assertions read. */
const fs = require('fs');
const path = require('path');
const HERE = __dirname;

const SB = 'https://drstmntdbmacdplhjvmx.supabase.co';

/* ---------- fixtures, shaped as the views hand them back ---------- */
const countiesGeo = JSON.parse(fs.readFileSync(path.join(HERE, 'counties.json'), 'utf8'));

const FIPS = {};                       /* SAP -> FIPS; NCDOT publishes only SAP */
countiesGeo.features.forEach((f, i) => { FIPS[f.properties.SapCountyId] = (i * 2) + 1; });

const county_geojson = countiesGeo.features.map(f => ({
  county_name: String(f.properties.CountyName).toUpperCase(),
  sap_code: f.properties.SapCountyId,
  fips_code: FIPS[f.properties.SapCountyId],
  dot_division: f.properties.DOTDivisionID,
  geom: f.geometry,
}));

const SNBI_MAP = {
  structure_number: 'StructureNumber', division: 'Division',
  structure_type: 'LayerName', service_on: 'ServiceOn', service_under: 'ServiceUnder',
  structure_length: 'StructureLength', bridge_deck_width: 'BridgeDeckWidth',
  bridge_road_width: 'BridgeRoadWidth', approach_road_width: 'ApproachRoadWidth',
  fed_skew: 'FedSkew', through_lanes_on: 'ThroughLanesOn', year_built: 'YearBuilt',
  deck_condition: 'DeckCondition', superstructure_condition: 'SuperStructureCondition',
  substructure_condition: 'SubStructureCondition', culvert_condition: 'CulvertCondition',
  last_inspect_date: 'LastInspectDate', scour_critical: 'ScourCritical',
  fracture_critical: 'FractureCritical', posted_open_closed: 'PostedOpenClosed',
  nhs: 'NHS', owner_code: 'Owner', maint_responsible: 'MaintResponsible',
  legacy_inventory_route: 'InventoryRoute', adt: 'ADT',
};

function loadSnbi() {
  const raw = JSON.parse(fs.readFileSync(path.join(HERE, 'struct_meck.json'), 'utf8'));
  const out = [];
  for (const layer of Object.keys(raw)) for (const f of raw[layer]) {
    const a = f.attributes, row = { county_name: String(a.County || '').toUpperCase() };
    for (const [col, src] of Object.entries(SNBI_MAP)) row[col] = a[src] === undefined ? null : a[src];
    row.structure_number = String(a.StructureNumber).trim();
    out.push(row);
  }
  return out;
}

/* A county the fixtures do not contain, with more rows than one PostgREST page
   can return. The client has to page or it silently loses 60% of them — which
   is precisely what the old ArcGIS pager did. */
function bigCounty(n = 2500) {
  return Array.from({ length: n }, (_, i) => ({
    county_name: 'BIGSHIRE', structure_number: 'B' + String(i).padStart(5, '0'),
    structure_type: 'Bridge Structures', service_on: 'Highway', division: 99,
  }));
}

const hpmsIds = fs.readFileSync(path.join(HERE, 'hpms_routes.csv'), 'utf8')
  .trim().split('\n').slice(1).map(l => l.split(',')[0]).filter(Boolean);

/* ---------- the PostgREST bits the client actually uses ---------- */
function parseIn(v) {                       /* in.("A","B")  |  in.(1,2) */
  const m = /^in\.\((.*)\)$/s.exec(v || '');
  if (!m) return null;
  return m[1].length ? m[1].split(',').map(s => s.trim().replace(/^"|"$/g, '')) : [];
}
function parseEq(v) { const m = /^eq\.(.*)$/s.exec(v || ''); return m ? m[1] : null; }

module.exports = function sbmock(page, opts = {}) {
  const log = [];
  const snbi = (opts.snbi || loadSnbi()).concat(opts.bigCounty ? bigCounty(opts.bigCounty) : []);

  /* Route extents for every route the bridge fixture mentions, so deepCheck has
     something to join to. One route is deliberately absent: a route the extents
     do not cover has to report as not found rather than as valid. */
  const extents = opts.extents || [];
  if (opts.bridges && !opts.extents) {
    const seen = new Set();
    opts.bridges.features.forEach(f => {
      const r = f.attributes.RTE_ID;
      if (!r || !/^\d{11}$/.test(r) || seen.has(r)) return;
      seen.add(r);
      extents.push({ route_id: r, min_mp: 0, max_mp: 4.5 });
    });
    if (extents.length) extents.pop();     /* the one that is not in the extents */
  }

  /* county_id is filled from the same SAP->FIPS crosswalk the client will read
     out of county_geojson, so a suite supplying its own routes does not have to
     know it. Conflating SAP with FIPS is the failure this guards against. */
  const hpms = (opts.hpms || hpmsIds.map(id => ({ route_id: id, begin_point: 0, end_point: 40 })))
    .map(r => Object.assign({ hpms_year: 2024, county_id: FIPS[String(r.route_id).slice(8)] ?? 1 }, r));

  const vintage = opts.vintage || [
    { source_service: 'NCDOT_CountyBdy_Poly', publication_label: 'Friday, Feb 10, 2023',
      published_at: '2023-02-10T00:00:00Z', completed_at: '2026-08-13T18:03:31Z', row_count: 100 },
    { source_service: 'NCDOT_Bridges', publication_label: 'Latest Publication Date: 03/15/2026 : 14:05',
      published_at: '2026-03-15T14:05:00Z', completed_at: '2026-08-13T18:05:50Z', row_count: 23022 },
    { source_service: 'NCDOT_DynamicStructures', publication_label: 'Geoservice Date: 7/27/2020',
      published_at: '2020-07-27T00:00:00Z', completed_at: '2026-08-13T18:07:25Z', row_count: 22899 },
    { source_service: 'FHWA_HPMS', publication_label: 'HPMS 2024 submittal. The service reports no publication date of its own; the year is from the layer name.',
      published_at: null, completed_at: '2026-08-13T18:11:02Z', row_count: 222402 },
    { source_service: 'NCDOT_RoadCharacteristicsQtr', publication_label: 'Latest Publication Date: 06/28/2026 : 15:11',
      published_at: '2026-06-28T15:11:00Z', completed_at: '2026-08-13T18:40:00Z', row_count: 315494 },
  ];

  /* The approvals queue and the approver directory. Both are ordinary reads —
     the queue is public because the provenance of a public submittal is public
     — so they are ordinary fixtures. A suite that wants the decisions to have
     an effect passes `rpc`, below, and mutates these arrays itself. */
  const proposal_queue = opts.queue || [];
  const approver_directory = opts.directory || [];

  /* Traffic. traffic_client is one row per stretch of road carrying its
     station's current count beside the segmentation's older value; traffic_probe
     is the modelled fallback. Both are read by route, so the fixtures are just
     rows and the milepoint containment happens in the browser, which is where it
     happens for real. */
  const traffic_client = opts.traffic || [];
  const traffic_probe  = opts.probe   || [];

  /* Detour length as measured (migration 0042): one row per structure per
     mode, keyed by brdg_nbr, read for the structures on screen. */
  const detour_measured = opts.detour || [];

  const TABLES = { county_geojson, structure_snbi: snbi, route_extents: extents,
                   hpms_routes: hpms, data_vintage: vintage,
                   proposal_queue, approver_directory,
                   traffic_client, traffic_probe, detour_measured };

  return page.route(SB + '/rest/v1/**', async route => {
    const req = route.request();
    const u = new URL(req.url());
    const table = u.pathname.replace('/rest/v1/', '');
    const J = (o, status = 200) => route.fulfill({ status, contentType: 'application/json',
                                                   body: JSON.stringify(o) });

    if (table.startsWith('rpc/')) {
      const name = table.slice(4);
      log.push({ table, rpc: name, body: req.postData(), method: req.method() });
      if (opts.rpcFails) return J({ message: opts.rpcFails }, 400);
      /* A suite can hand a real implementation per function. Returning
         {status, body} lets it assert the refusal paths, which is where the
         interesting behaviour is: the database is the thing saying no. */
      if (opts.rpc && opts.rpc[name]) {
        let arg = {}; try { arg = JSON.parse(req.postData() || '{}'); } catch (e) {}
        const out = opts.rpc[name](arg);
        if (out && typeof out === 'object' && 'status' in out) return J(out.body, out.status);
        return J(out === undefined ? null : out);
      }
      return J(null);
    }

    let rows = TABLES[table];
    if (!rows) { log.push({ table, unknown: true }); return J({ message: 'no such table' }, 404); }

    const p = u.searchParams;
    const limit = Number(p.get('limit') || 1000);
    const offset = Number(p.get('offset') || 0);
    const filters = {};

    for (const [k, v] of p.entries()) {
      if (['select', 'limit', 'offset', 'order'].includes(k)) continue;
      filters[k] = v;
      const list = parseIn(v);
      if (list) { rows = rows.filter(r => list.includes(String(r[k]))); continue; }
      const eq = parseEq(v);
      if (eq !== null) rows = rows.filter(r => String(r[k]) === eq);
    }

    log.push({ table, filters, limit, offset, matched: rows.length,
               select: p.get('select') || '', url: req.url().replace(SB, '') });

    if (opts.fail && opts.fail === table) return J({ message: 'boom' }, 500);
    return J(rows.slice(offset, offset + limit));
  }).then(() => ({ log, SB, county_geojson, snbi, extents, hpms, vintage,
                   proposal_queue, approver_directory, traffic_client, traffic_probe, detour_measured,
                   /* helpers the suites read */
                   reads: t => log.filter(x => x.table === t),
                   rpcs: () => log.filter(x => x.rpc),
                   clear: () => { log.length = 0; } }));
};

module.exports.SB = SB;
