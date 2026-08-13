// FHWA's published HPMS submittal for NC -> hpms_routes. This is what makes
// BH06-3 a real test rather than an untested rule.
//
// Sliced by county_id, which is FIPS here — HPMS keys on FIPS while NCDOT keys
// on SAP, and conflating the two silently fails a whole county.
//
// The service reports no vintage of its own: no serviceDescription, no
// editingInfo, nothing. The year in the layer name is the only statement it
// makes about itself, so that is what gets recorded.
import { runIngest, getJSON, q, rpc, begin } from "../_shared/ingest.ts";

const YEAR = Number(Deno.env.get("HPMS_YEAR") ?? 2024);
const BASE = `https://geo.dot.gov/server/rest/services/Hosted/HPMS_FULL_NC_${YEAR}/FeatureServer/0`;
const LAYER = `${BASE}/query`;
const PAGE = 2000;
const STATS = JSON.stringify([
  { statisticType: "min", onStatisticField: "begin_point", outStatisticFieldName: "mn" },
  { statisticType: "max", onStatisticField: "end_point",   outStatisticFieldName: "mx" },
]);

Deno.serve((req) =>
  runIngest(req, "ingest-hpms",
    async (body, deadline, run) => {
      let counties: number[] = body.counties ?? [];
      if (!counties.length) {
        const c = await getJSON(q(LAYER, {
          where: "1=1", groupByFieldsForStatistics: "county_id",
          outStatistics: JSON.stringify([
            { statisticType: "count", onStatisticField: "objectid", outStatisticFieldName: "n" }]),
          returnGeometry: "false", resultRecordCount: 300, f: "json",
        }));
        counties = [...new Set((c.features ?? [])
          .map((f: any) => f.attributes.county_id).filter((x: any) => x != null))].sort((a, b) => a - b);
      }
      let rows = Number(body.rows ?? 0);

      while (counties.length) {
        if (Date.now() >= deadline) return { done: false, rows, next: { counties, rows } };
        const cid = counties[0];
        let offset = 0;
        for (;;) {
          const j = await getJSON(q(LAYER, {
            where: `county_id=${cid}`, groupByFieldsForStatistics: "route_id",
            outStatistics: STATS, returnGeometry: "false", orderByFields: "route_id",
            resultOffset: offset, resultRecordCount: PAGE, f: "json",
          }));
          const feats = j.features ?? [];
          if (feats.length) {
            await rpc("ingest_hpms", {
              p: feats.map((f: any) => ({
                route_id: f.attributes.route_id, county_id: cid,
                mn: f.attributes.mn, mx: f.attributes.mx,
              })),
              p_year: YEAR, p_run: run,
            });
            rows += feats.length;
          }
          if (feats.length < PAGE && !j.exceededTransferLimit) break;
          offset += feats.length;
        }
        counties = counties.slice(1);
      }
      return { done: true, rows, notes: `HPMS ${YEAR}` };
    },
    async () => begin("FHWA_HPMS", BASE,
      `HPMS ${YEAR} submittal. The service reports no publication date of its own; ` +
      `the year is from the layer name.`),
  )
);
