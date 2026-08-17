// NCDOT probe-estimated AADT -> traffic_probe.
//
// Its own function, and its own schedule, because it is a different KIND of
// number and much the largest table here: 1,210,860 segments against the
// segmentation's 47,071.
//
// It exists for the two thirds of the inventory no count station governs. In
// Mecklenburg, 826 of 1,282 structures carry no AADT at all, and a blank is not
// a better answer than a modelled one - provided the model's uncertainty comes
// with it. Every row keeps Lower_95_P and Upper_95_P, and nothing downstream is
// allowed to report the estimate without them.
import { runIngest, getJSON, q, rpc, begin } from "./_shared/ingest.ts";

const ORG = "https://services.arcgis.com/NuWFvHYDMVmmxMeM/ArcGIS/rest/services";
const LAYER = `${ORG}/NCDOT_AADT_ProbeEstimated_2023/FeatureServer/0`;
const DATA_YEAR = 2023;
const PAGE = 2000;

Deno.serve((req) =>
  runIngest(req, "ingest-traffic-probe",
    async (body, deadline, run) => {
      let off = Number(body.off ?? 0);
      let rows = Number(body.rows ?? 0);

      // A reload replaces: a probe segment has no natural key to upsert on.
      if (off === 0) await rpc("traffic_reset_probe", {});

      while (Date.now() < deadline) {
        const j = await getJSON(q(`${LAYER}/query`, {
          where: "1=1", outFields: "RouteID,BegMP,EndMP,Estimated,Lower_95_P,Upper_95_P",
          returnGeometry: "false", orderByFields: "FID",
          resultOffset: off, resultRecordCount: PAGE, f: "json",
        }));
        const fs = j.features ?? [];
        // Never infer completion from the size of a page - the segmentation
        // layers taught this the expensive way. exceededTransferLimit is the
        // only thing that means "there is more".
        const remain = fs.length > 0 && (j.exceededTransferLimit || fs.length >= PAGE);
        if (fs.length) {
          await rpc("ingest_traffic_probe", {
            p: fs.map((f: any) => {
              const a = f.attributes;
              return {
                route_id: String(a.RouteID).trim(),
                begin_mp: a.BegMP, end_mp: a.EndMP,
                estimated: a.Estimated, lo95: a.Lower_95_P, hi95: a.Upper_95_P,
                data_year: DATA_YEAR,
              };
            }),
            p_run: run,
          });
          rows += fs.length;
        }
        if (!remain) return { done: true, rows };
        off += fs.length;
      }
      return { done: false, rows, next: { off, rows } };
    },
    async () => await begin("NCDOT_AADT_ProbeEstimated", LAYER,
      "Probe-derived AADT, 2023, with a 95% confidence interval on every segment. " +
      "Linear-referenced on the same RouteID and milepoint system as the count-based data, " +
      "so it substitutes for a station on roads that have none."),
  )
);
