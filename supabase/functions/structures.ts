// NCDOT_DynamicStructures -> the SNBI columns on structures.
//
// Eight layers, and this service caps a page at 1,000 rather than the 2,000
// everything else allows — asking for more and stopping when fewer come back
// truncated every layer at its first page in the browser tool, which is how a
// statewide pull there returned 4,367 of 22,899 structures.
//
// Worth knowing while reading the ingest_runs row this writes: the service
// reports a Geoservice Date of 2020 while the bridge layer reports 2026. The
// condition and geometry columns are that old, and the export should say so.
import { runIngest, getJSON, q, rpc, begin, serviceDescription } from "../_shared/ingest.ts";

const MAP = "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Structures/NCDOT_DynamicStructures/MapServer";
const PAGE = 1000;
const LAYERS: [number, string][] = [
  [0, "Bridge"], [1, "Pipe"], [2, "Culvert"], [3, "Railroad bridge"],
  [4, "Tunnel"], [5, "Pedestrian"], [6, "Sign"], [7, "Other"],
];
const FIELDS = "StructureNumber,ServiceOn,ServiceUnder,StructureLength,BridgeDeckWidth," +
  "BridgeRoadWidth,ApproachRoadWidth,FedSkew,ThroughLanesOn,YearBuilt,DeckCondition," +
  "SuperStructureCondition,SubStructureCondition,CulvertCondition,LastInspectDate," +
  "ScourCritical,FractureCritical,PostedOpenClosed,NHS,Owner,InventoryRoute";

Deno.serve((req) =>
  runIngest(req, "ingest-structures",
    async (body, deadline, run) => {
      let li = Number(body.layer ?? 0);
      let offset = Number(body.offset ?? 0);
      let rows = Number(body.rows ?? 0);

      while (li < LAYERS.length) {
        if (Date.now() >= deadline) return { done: false, rows, next: { layer: li, offset, rows } };
        const [id, label] = LAYERS[li];
        const j = await getJSON(q(`${MAP}/${id}/query`, {
          where: "1=1", outFields: FIELDS, returnGeometry: "false",
          orderByFields: "ObjectID", resultOffset: offset, resultRecordCount: PAGE, f: "json",
        }));
        const feats = j.features ?? [];
        if (feats.length) {
          await rpc("ingest_structures", {
            p: feats.map((f: any) => f.attributes), p_run: run, p_type: label,
          });
          rows += feats.length;
        }
        // page size OR the transfer-limit flag; never "fewer than I asked for"
        if (feats.length < PAGE && !j.exceededTransferLimit) { li += 1; offset = 0; }
        else offset += feats.length;
      }
      return { done: true, rows };
    },
    async () => begin("NCDOT_DynamicStructures", MAP, await serviceDescription(MAP)),
  )
);
