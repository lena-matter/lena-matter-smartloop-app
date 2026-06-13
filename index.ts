// ============================================================================
// SmartLoop · ThinkLid sensor ingestion  (Supabase Edge Function, Deno)
// ----------------------------------------------------------------------------
// A bin lid / site gateway POSTs a fill reading here. The function:
//   1. authenticates the device by a per-device API key (Bearer header),
//      comparing its SHA-256 hash against public.devices.api_key_hash;
//   2. resolves the device -> bin_id;
//   3. inserts into public.bin_readings using the SERVICE_ROLE key
//      (bypassing RLS — sensors are not logged-in users);
//   4. stamps devices.last_seen_at.
//
// The service_role key lives ONLY in this server-side function's env, never in
// the browser. Issue device keys with the register_thinklid() RPC (see auth_rls.sql).
//
// Deploy:  supabase functions deploy thinklid-ingest --no-verify-jwt
//   (--no-verify-jwt because devices present a DEVICE key, not a Supabase JWT)
//
// Request:
//   POST https://<project>.functions.supabase.co/thinklid-ingest
//   Authorization: Bearer <device_api_key>
//   Content-Type: application/json
//   { "serial":"TL-AU-0001", "fill_pct": 73, "weight_kg": 4.2,
//     "recorded_at":"2026-06-13T04:20:00Z" }      // serial/weight/recorded_at optional
//
// Batch form (gateway with several lids): { "readings": [ {serial, fill_pct,...}, ... ] }
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

async function sha256hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Reading {
  serial?: string;
  fill_pct: number;
  weight_kg?: number | null;
  recorded_at?: string;
}

function validate(r: Reading): string | null {
  if (typeof r.fill_pct !== "number" || Number.isNaN(r.fill_pct)) return "fill_pct (number) required";
  if (r.fill_pct < 0 || r.fill_pct > 100) return "fill_pct must be 0–100";
  if (r.weight_kg != null && (typeof r.weight_kg !== "number" || r.weight_kg < 0)) return "weight_kg must be a positive number";
  if (r.recorded_at != null && Number.isNaN(Date.parse(r.recorded_at))) return "recorded_at must be ISO-8601";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // --- device authentication ---
  const authz = req.headers.get("authorization") ?? "";
  const key = authz.replace(/^Bearer\s+/i, "").trim();
  if (!key) return json({ error: "missing device key (Authorization: Bearer <key>)" }, 401);

  const keyHash = await sha256hex(key);
  const { data: device, error: devErr } = await admin
    .from("devices")
    .select("id, bin_id, school_id, is_active, thinklid_serial")
    .eq("api_key_hash", keyHash)
    .maybeSingle();

  if (devErr) return json({ error: "device lookup failed", detail: devErr.message }, 500);
  if (!device || !device.is_active) return json({ error: "invalid or inactive device key" }, 403);
  if (!device.bin_id) return json({ error: "device is not linked to a bin yet" }, 409);

  // --- parse body (single or batch) ---
  let payload: unknown;
  try { payload = await req.json(); } catch { return json({ error: "invalid JSON body" }, 400); }

  const items: Reading[] = Array.isArray((payload as { readings?: Reading[] })?.readings)
    ? (payload as { readings: Reading[] }).readings
    : [payload as Reading];

  if (items.length === 0 || items.length > 500) return json({ error: "send 1–500 readings" }, 400);

  // --- validate + (optional) serial match ---
  const rows = [];
  for (const r of items) {
    const v = validate(r);
    if (v) return json({ error: v }, 400);
    if (r.serial && r.serial !== device.thinklid_serial) {
      return json({ error: `serial mismatch: key is bound to ${device.thinklid_serial}` }, 403);
    }
    rows.push({
      bin_id: device.bin_id,
      fill_pct: Math.round(r.fill_pct),
      weight_kg: r.weight_kg ?? null,
      recorded_at: r.recorded_at ?? new Date().toISOString(),
    });
  }

  // --- insert (service_role bypasses RLS) ---
  const { error: insErr } = await admin.from("bin_readings").insert(rows);
  if (insErr) return json({ error: "insert failed", detail: insErr.message }, 500);

  await admin.from("devices").update({ last_seen_at: new Date().toISOString() }).eq("id", device.id);

  return json({ ok: true, ingested: rows.length, bin_id: device.bin_id }, 201);
});
