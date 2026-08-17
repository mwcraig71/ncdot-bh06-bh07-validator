// NCDOT Traffic Survey -> traffic_station, traffic_station_year, traffic_segment.
//
// B.H.09, B.H.10 and B.H.11 come from here, and not from the bridge record,
// because the bridge record is a copy of these numbers with the year removed.
//
// Three loads in one function, in a fixed order, because the third depends on
// the first two:
//
//   1. STATIONS  - 48,687 points, keyed on the 11-digit LRS Route ID.
//   2. YEARS     - the same file's AADT_2002..AADT_2024 columns, unpivoted. A
//                  blank is not a zero: it means the station was not counted
//                  that year, which its collection cycle predicts, so blanks
//                  are dropped rather than stored.
//   3. SEGMENTS  - the linear-referenced AADT/AADTT segmentation, three layers
//                  (secondary, primary, interstate). This is what lets a
//                  bridge's own BH06/BH07 pair find its station without a
//                  spatial guess, via TMS_ID.
//
// Then traffic_date_segments() works out, per segment, WHICH YEAR of its
// station's series its AADT equals. That is how the truck share gets dated:
// there is no dated truck series anywhere, so the share is carried forward and
// the year it came from is recorded rather than assumed from a release note.
import { runIngest, getJSON, q, rpc, begin } from "./_shared/ingest.ts";

const ORG = "https://services.arcgis.com/NuWFvHYDMVmmxMeM/ArcGIS/rest/services";
const STATIONS = `${ORG}/NCDOT__2024_AADT_Stations_published_September_2025/FeatureServer/0`;
const SEGMENTS = `${ORG}/NCDOT_AADT_Traffic_Segmentation/FeatureServer`;
const SEG_LAYERS: Record<number, string> = { 1: "secondary", 2: "primary", 3: "interstate" };
const FIRST_YEAR = 2002, LAST_YEAR = 2024;
// The station layer allows 2,000 a page; the segmentation layers advertise
// maxRecordCount 1000 while their standardMaxRecordCount says 2000, and hand
// back 1,000 with exceededTransferLimit set. Ask each for what it allows, and
// never treat a short page as the end of the data - see `more` below.
const STATION_PAGE = 2000, SEG_PAGE = 1000;

const num = (v: unknown): number | null => {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  if (s === "" || s === "0") return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
};

Deno.serve((req) =>
  runIngest(req, "ingest-traffic",
    async (body, deadline, run) => {
      let phase: string = body.phase ?? "stations";
      let off = Number(body.off ?? 0);
      let layer = Number(body.layer ?? 1);
      let rows = Number(body.rows ?? 0);
      let years = Number(body.years ?? 0);

      const more = (next: Record<string, unknown>) =>
        ({ done: false, rows, next: { ...next, rows, years } });

      while (Date.now() < deadline) {
        if (phase === "stations") {
          const j = await getJSON(q(`${STATIONS}/query`, {
            where: "1=1", outFields: "*", returnGeometry: "false",
            orderByFields: "FID", resultOffset: off, resultRecordCount: STATION_PAGE, f: "json",
          }));
          const fs = j.features ?? [];
          const stationsRemain = fs.length > 0 && (j.exceededTransferLimit || fs.length >= STATION_PAGE);
          if (fs.length) {
            await rpc("ingest_traffic_stations", {
              p: fs.map((f: any) => {
                const a = f.attributes;
                return {
                  location_id: String(a.LocationID).trim(),
                  county_name: a.County, route_id: a.Route == null ? null : String(a.Route).trim(),
                  location: a.Location, rte_cls: num(a.RTE_CLS), func_cls: num(a.FUNC_CLS),
                  coll_cycle: a.Coll_Cycle, active: String(a.Active) === "1",
                  category: a.Category, lat: a.Latitude, lon: a.Longitude,
                };
              }),
              p_run: run,
            });
            // The same page, unpivoted. Sending years alongside the stations
            // means one pass over a 48,687-row file rather than two.
            const ys: unknown[] = [];
            for (const f of fs) {
              const a = f.attributes, id = String(a.LocationID).trim();
              for (let y = FIRST_YEAR; y <= LAST_YEAR; y++) {
                const v = num(a[`AADT_${y}`]);
                if (v !== null) ys.push({ location_id: id, year: y, aadt: v });
              }
            }
            for (let i = 0; i < ys.length; i += 4000) {
              await rpc("ingest_traffic_station_years",
                        { p: ys.slice(i, i + 4000), p_run: run });
            }
            years += ys.length;
            rows += fs.length;
          }
          if (!stationsRemain) { phase = "segments"; off = 0; layer = 1; continue; }
          off += fs.length;
          continue;
        }

        if (phase === "segments") {
          if (!SEG_LAYERS[layer]) { phase = "date"; continue; }
          // A reload replaces: a segment is a stretch of road, not a thing with
          // an id, so there is nothing to upsert on.
          if (layer === 1 && off === 0) await rpc("traffic_reset_segments", {});
          const j = await getJSON(q(`${SEGMENTS}/${layer}/query`, {
            where: "1=1", outFields: "*", returnGeometry: "false",
            orderByFields: "FID", resultOffset: off, resultRecordCount: SEG_PAGE, f: "json",
          }));
          const fs = j.features ?? [];
          // exceededTransferLimit is the service saying there is more. A page
          // shorter than the one requested says nothing at all.
          const segsRemain = fs.length > 0 && (j.exceededTransferLimit || fs.length >= SEG_PAGE);
          if (fs.length) {
            await rpc("ingest_traffic_segments", {
              p: fs.map((f: any) => {
                const a = f.attributes;
                return {
                  route_id: String(a.RouteID).trim(),
                  begin_mp: a.BeginMP, end_mp: a.EndMP,
                  aadt: num(a.AADT), aadtt: num(a.AADTT),
                  su_aadt: num(a.SU_AADT), mu_aadt: num(a.MU_AADT),
                  su_pct: a.SU_PCT, mu_pct: a.MU_PCT,
                  source: a.SOURCE, tms_id: a.TMS_ID == null ? null : String(a.TMS_ID).trim(),
                  road_class: SEG_LAYERS[layer],
                };
              }),
              p_run: run,
            });
            rows += fs.length;
          }
          if (!segsRemain) { layer += 1; off = 0; } else { off += fs.length; }
          continue;
        }

        // Date every segment against its own station's series.
        const dated = await rpc("traffic_date_segments", {});
        return { done: true, rows,
                 notes: `${years} station-years loaded; ${dated} segments dated against their station` };
      }

      return more({ phase, off, layer });
    },
    async () => {
      // The station file states its own vintage in its name, which is the only
      // place NCDOT puts it for this one.
      return await begin("NCDOT_TrafficSurvey_AADT", STATIONS,
        "2024 AADT stations, published September 2025. Two-way totals, all lanes both " +
        "directions. Segmentation layers carry AADTT and the truck share at their own " +
        "older vintage, which traffic_date_segments() establishes per segment.");
    },
  )
);
