// NCDOT_CountyBdy_Poly -> county_codes (names, SAP/FIPS crosswalk, boundaries).
//
// 100 counties. Fits in one invocation, so no cursor. The boundaries are
// simplified on the way in: the map draws them at statewide zoom and full
// resolution is several megabytes for no visible gain.
import { runIngest, getJSON, q, rpc, begin, serviceDescription } from "../_shared/ingest.ts";

const MAP = "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_CountyBdy_Poly/MapServer";
const LAYER = `${MAP}/0/query`;

Deno.serve((req) =>
  runIngest(req, "ingest-counties",
    async (_body, _deadline, run) => {
      const j = await getJSON(q(LAYER, {
        where: "1=1",
        outFields: "CountyName,SapCountyId,FIPS,DOTDivisionID",
        returnGeometry: "true", outSR: 4326,
        maxAllowableOffset: 0.002,          // ~200 m; a county outline, not a survey
        f: "geojson",
      }));
      const rows = (j.features ?? []).map((f: any) => ({
        name: f.properties.CountyName,
        sap: f.properties.SapCountyId,
        fips: f.properties.FIPS,
        division: f.properties.DOTDivisionID,
        geom: f.geometry ? JSON.stringify(f.geometry) : null,
      })).filter((r: any) => r.sap && r.name);

      await rpc("ingest_counties", { p: rows, p_run: run });
      return { done: true, rows: rows.length };
    },
    async () => begin("NCDOT_CountyBdy_Poly", MAP, await serviceDescription(MAP)),
  )
);
