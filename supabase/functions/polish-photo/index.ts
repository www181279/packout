// Packout: remove the background from an item photo with Photoroom (Basic plan, no AI redrawing).
// The garment pixels are returned untouched; the app does straightening, centering and the white background.
// Secrets (Supabase > Edge Functions > Secrets): PHOTOROOM_API_KEY.
// Deploy with "Verify JWT" turned OFF: the app sends its publishable key, checked below.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info, x-packout-team",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function callerAllowed(req: Request): Promise<boolean> {
  const key = req.headers.get("apikey") ?? "";
  if (!key) return false;
  // The database answers true only for phones with the team code (or for everyone while no code is set).
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/packout_is_team`, {
    method: "POST", body: "{}",
    headers: { apikey: key, "Content-Type": "application/json", "x-packout-team": req.headers.get("x-packout-team") ?? "" },
  });
  return r.ok && (await r.json()) === true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  if (!(await callerAllowed(req))) return json({ error: "This app is not allowed to polish photos." }, 401);
  const key = Deno.env.get("PHOTOROOM_API_KEY");
  if (!key) return json({ error: "NO_KEY", message: "Photo polishing is not set up yet: the Photoroom key is missing in Supabase." }, 503);

  let path = "";
  try { path = String((await req.json()).path || ""); } catch { /* handled below */ }
  if (!/^[0-9a-f-]{36}\.jpg$/i.test(path)) return json({ error: "Unknown photo." }, 400);

  // The original photo, exactly as the employee took it (after the app's size reduction).
  const src = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/item-photos/${path}`);
  if (!src.ok) return json({ error: "The original photo was not found." }, 404);
  const form = new FormData();
  form.append("image_file", new Blob([await src.arrayBuffer()], { type: "image/jpeg" }), "item.jpg");
  form.append("format", "png");

  const r = await fetch("https://sdk.photoroom.com/v1/segment", { method: "POST", headers: { "x-api-key": key }, body: form });
  if (!r.ok) {
    const t = await r.text().catch(() => "");
    return json({ error: "PHOTOROOM", message: `Background removal failed (${r.status}). ${t.slice(0, 200)}` }, 502);
  }
  return new Response(await r.arrayBuffer(), { headers: { ...CORS, "Content-Type": "image/png", "Cache-Control": "no-store" } });
});
