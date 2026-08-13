// NCDOT_RoadCharacteristicsQtr -> route_extents.
//
// This is deepCheck(), moved off the request path. The browser used to compute
// it live, once per run, for every route in scope; it becomes a join.
//
// No offset paging, deliberately. This MapServer silently IGNORES resultOffset
// on a groupByFieldsForStatistics query: offset 0 and offset 2000 return byte
// for byte the same first 2,000 rows, and exceededTransferLimit stays true. A
// pager written the obvious way therefore never terminates — it re-reads page
// one until the platform kills the invocation, which is exactly what the first
// version of this function did.
//
// So instead the work is cut into slices small enough to arrive whole:
// route class digit x county, which is 900 slices of a few hundred to ~1,000
// routes each. A slice that still comes back truncated is split again by
// prefixing another digit, and again, rather than being quietly accepted short.
// The first version subdivided only once and reported 51 slices still truncated
// after subdividing - which is the right thing to report, and the wrong thing
// to stop at.
import { runIngest, getJSON, q, rpc, sql, begin, serviceDescription } from "./_shared/ingest.ts";

const MAP = "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_RoadCharacteristicsQtr/MapServer";
const LAYER = `${MAP}/0/query`;
const PAGE = 2000;
const STATS = JSON.stringify([
  { statisticType: "min", onStatisticField: "BeginMp1", outStatisticFieldName: "mn" },
  { statisticType: "max", onStatisticField: "EndMp1",   outStatisticFieldName: "mx" },
]);

Deno.serve((req) =>
  runIngest(req, "ingest-route-extents",
    async (body, deadline, run) => {
      // A slice is a LIKE pattern over the 11-digit route id: class, then
      // wildcards, then the three-digit SAP county it ends with.
      let todo: string[] = body.todo ?? [];
      if (!todo.length && !body.started) {
        const cc = await sql("county_codes?select=sap_code&order=sap_code");
        if (!cc.length) throw new Error("No counties loaded - run ingest-counties first.");
        for (const c of cc) for (let cls = 1; cls <= 9; cls++) todo.push(`${cls}%${c.sap_code}`);
      }
      let rows = Number(body.rows ?? 0);
      let split = Number(body.split ?? 0);

      while (todo.length) {
        if (Date.now() >= deadline) {
          return { done: false, rows, next: { todo, rows, split, started: 1 } };
        }
        const pat = todo.shift()!;
        const j = await getJSON(q(LAYER, {
          where: `RouteID LIKE '${pat}'`,
          groupByFieldsForStatistics: "RouteID", outStatistics: STATS,
          returnGeometry: "false", orderByFields: "RouteID",
          resultRecordCount: PAGE, f: "json",
        }));
        const feats = j.features ?? [];

        // Truncated: subdivide rather than accept a short answer. The digit
        // after the class is the qualifier, so this cuts the slice ten ways.
        if (feats.length >= PAGE || j.exceededTransferLimit) {
          const cls = pat[0], tail = pat.slice(1);
          if (cls.length === 1 && !/^\d\d/.test(pat)) {
            for (let qd = 0; qd <= 9; qd++) todo.push(`${cls}${qd}${tail}`);
            split++;
            continue;
          }
          // already subdivided once and still truncated: take what came back and
          // say so, rather than pretending the slice was complete
          split += 1000;
        }

        if (feats.length) {
          await rpc("ingest_route_extents", {
            p: feats.map((f: any) => ({
              route_id: f.attributes.RouteID, mn: f.attributes.mn, mx: f.attributes.mx,
            })),
            p_run: run,
          });
          rows += feats.length;
        }
      }
      return {
        done: true, rows,
        notes: split ? `${split % 1000} slices subdivided` +
                       (split >= 1000 ? `; ${Math.floor(split / 1000)} still truncated after subdividing` : "")
                     : null,
      };
    },
    async () => begin("NCDOT_RoadCharacteristicsQtr", MAP, await serviceDescription(MAP)),
  )
);
