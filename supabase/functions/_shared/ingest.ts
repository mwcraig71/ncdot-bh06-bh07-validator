// Shared plumbing for the reference-data ingests.
//
// Every one of these pulls more than fits in a single function invocation, so
// the shape is always the same: work through slices until the wall-clock budget
// is nearly spent, then hand the remaining cursor to a fresh invocation of
// ourselves and return. The ingest_runs row is what makes that legible from
// outside — one row per logical load, updated as it goes.

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
export const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Leaves headroom under the platform limit so the hand-off itself can run. */
export const BUDGET_MS = Number(Deno.env.get("INGEST_BUDGET_MS") ?? 55_000);

export async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

export async function sql(path: string, init?: RequestInit) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  if (!r.ok) throw new Error(`${path}: ${r.status} ${await r.text()}`);
  return r.json();
}

/** Retries, because a quarterly job that dies on one flaky response is a job
 *  someone has to babysit. */
export async function getJSON(url: string, tries = 4): Promise<any> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, { headers: { "User-Agent": "strinteg-bh0607-ingest" } });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const j = await r.json();
      if (j?.error) throw new Error(j.error.message ?? "service error");
      return j;
    } catch (e) {
      last = e;
      await new Promise((s) => setTimeout(s, 400 * Math.pow(2, i)));
    }
  }
  throw new Error(`${url.split("?")[0]}: ${last}`);
}

export function q(base: string, params: Record<string, string | number>) {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) u.set(k, String(v));
  return `${base}?${u.toString()}`;
}

/** The vintage the service reports about itself, kept verbatim; the database
 *  parses it. Three different formats across the four NCDOT services. */
export async function serviceDescription(mapServer: string): Promise<string> {
  try {
    const j = await getJSON(`${mapServer}?f=json`);
    return [j.serviceDescription, j.description, j.documentInfo?.Comments]
      .filter(Boolean).join("\n");
  } catch { return ""; }
}

export async function begin(service: string, url: string, desc: string): Promise<number> {
  return await rpc("ingest_begin", { p_service: service, p_url: url, p_desc: desc });
}

export async function finish(run: number, status: string, rows: number,
                             ins = 0, upd = 0, error: string | null = null,
                             notes: string | null = null) {
  await rpc("ingest_finish", {
    p_run: run, p_status: status, p_rows: rows, p_ins: ins, p_upd: upd,
    p_error: error, p_notes: notes,
  });
}

/** Hand the rest of the work to a fresh invocation. Fire and forget: the reply
 *  is another whole run and we must not wait for it. */
export function handOff(fnName: string, body: Record<string, unknown>, token: string) {
  fetch(`${SUPABASE_URL}/functions/v1/${fnName}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      "x-ingest-token": token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  }).catch(() => {});
}

/** The functions sit behind verify_jwt, but the anon key is printed in the
 *  published page — so JWT verification alone would let any visitor start a
 *  statewide pull. The second factor is a token the database owns and no client
 *  role can read. */
export async function authorised(req: Request): Promise<boolean> {
  const sent = req.headers.get("x-ingest-token") ?? "";
  if (!sent) return false;
  try {
    const rows = await sql("ingest_secret?select=token&id=eq.1");
    const want = rows?.[0]?.token ?? "";
    if (!want || sent.length !== want.length) return false;
    // constant time-ish: compare every byte regardless of where it diverges
    let diff = 0;
    for (let i = 0; i < want.length; i++) diff |= sent.charCodeAt(i) ^ want.charCodeAt(i);
    return diff === 0;
  } catch { return false; }
}

export function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 1), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/** Every function has the same outer shape, so it lives here once. */
export async function runIngest(
  req: Request,
  name: string,
  work: (body: any, deadline: number, run: number) => Promise<
    { done: boolean; next?: Record<string, unknown>; rows: number; notes?: string }
  >,
  openRun: (body: any) => Promise<number>,
) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!await authorised(req)) {
    return jsonResponse({ ok: false, error: "x-ingest-token missing or wrong" }, 403);
  }
  const started = Date.now();
  const deadline = started + BUDGET_MS;
  let body: any = {};
  try { body = await req.json(); } catch { /* manual trigger with no body */ }

  let run: number = body.run ?? 0;
  try {
    if (!run) run = await openRun(body);
    const out = await work(body, deadline, run);

    if (!out.done) {
      handOff(name, { ...(out.next ?? {}), run },
              req.headers.get("x-ingest-token") ?? "");
      return jsonResponse({ ok: true, run, done: false, rows: out.rows,
                            continued: out.next, ms: Date.now() - started });
    }
    await finish(run, "ok", out.rows, 0, 0, null, out.notes ?? null);
    return jsonResponse({ ok: true, run, done: true, rows: out.rows, ms: Date.now() - started });
  } catch (e) {
    const msg = String(e?.message ?? e);
    if (run) await finish(run, "failed", 0, 0, 0, msg).catch(() => {});
    return jsonResponse({ ok: false, run, error: msg }, 500);
  }
}
