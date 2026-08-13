// NCDOT_Bridges -> structures, highway features, PUBLISHED BH06/BH07.
//
// 23,022 rows at 2,000 a page. Pages until the budget runs low, then hands the
// offset to a fresh invocation.
import { runIngest, getJSON, q, rpc, begin, serviceDescription } from "../_shared/ingest.ts";

const MAP = "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Bridges/MapServer";
const LAYER = `${MAP}/0/query`;
const PAGE = 2000;                                   // the layer's own maxRecordCount
const FIELDS = "BRDG_NBR,COUNTY,DIVISION,ROUTE,RTE_ID,MP,F_CARRIED,FTR_INTRSC," +
               "SERVICEON,SERVICEUNDER,MAINT_RESP,FUNC_CLASS,LAT_DD,LONG_DD,BRDG_TYP_NM,AADT";

Deno.serve((req) =>
  runIngest(req, "ingest-bridges",
    async (body, deadline, run) => {
      let offset = Number(body.offset ?? 0);
      let rows = Number(body.rows ?? 0);

      while (Date.now() < deadline) {
        const j = await getJSON(q(LAYER, {
          where: "1=1", outFields: FIELDS, returnGeometry: "false",
          orderByFields: "OBJECTID", resultOffset: offset, resultRecordCount: PAGE, f: "json",
        }));
        const feats = j.features ?? [];
        if (feats.length) {
          await rpc("ingest_bridges", { p: feats.map((f: any) => f.attributes), p_run: run });
          rows += feats.length;
        }
        if (feats.length < PAGE) return { done: true, rows };
        offset += feats.length;
      }
      return { done: false, rows, next: { offset, rows } };
    },
    async () => begin("NCDOT_Bridges", MAP, await serviceDescription(MAP)),
  )
);
