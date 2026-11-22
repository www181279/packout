// Packout: read a clothing tag photo with Claude and return the fields for the item form.
// Secrets (Supabase > Edge Functions > Secrets): ANTHROPIC_API_KEY. Optional: TAG_MODEL.
// Deploy with "Verify JWT" turned OFF: the app sends its publishable key, checked below.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info, x-packout-team",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Only phones that hold this project's app key may use the function (and spend AI credits).
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

const TOOL = {
  name: "record_tag",
  description:
    "Record what is printed on a clothing price tag, hang tag or care label so it can be saved to a packing inventory. " +
    "Always call this tool exactly once. Use an empty string for anything that cannot be read or is not on the tag. " +
    "Never guess digits or letters that are not clearly visible.",
  strict: true,
  input_schema: {
    type: "object",
    additionalProperties: false,
    required: ["style", "color", "color_code", "size", "item_type", "brand", "gender", "upc", "description", "notes"],
    properties: {
      style: { type: "string", description: "The style number, following the style rules." },
      color: { type: "string", description: "Color name for the inventory, following the color rules." },
      color_code: { type: "string", description: "The color exactly as printed if it is a code (e.g. DZBL, HGRY), else empty." },
      size: { type: "string", description: "Size following the size rules." },
      item_type: { type: "string", description: "One value from the allowed type list, or a short plain name if none fits, or empty." },
      brand: { type: "string", description: "Brand name as normally written, e.g. U.S. Polo Assn., Jordache, Sonoma, EV1. Empty if not shown." },
      gender: { type: "string", enum: ["Women", "Men", "Girls", "Boys", "Baby", "Unisex", ""] },
      upc: { type: "string", description: "The barcode number printed under the barcode, digits only, all of them (usually 12). Empty if unreadable." },
      description: { type: "string", description: "The product description line as printed, e.g. STEVIE SHORT SLEEVE HOODIE." },
      notes: { type: "string", description: "Anything uncertain the packer should double-check, in a few words. Empty if all clear." },
    },
  },
};

function prompt(types: string[], sizes: string[], current: string) {
  return `You are reading clothing tags for a store that is packing its stock into boxes and pallets.
The first image is the tag. ${"A second image, if present, is the garment itself."}
${current ? `The packer has already entered style "${current}" for this item.` : ""}

STYLE RULES
- If the tag has a label like STYLE:, STYLE#, STYLE NO, use the value after it.
- Some tags print a store item number (8 digits starting with 34, e.g. 34000123) next to the real style (e.g. 211218ZK, EV27898C1, 21-WU-US-0406). Use the real style, not the 34... number.
- Some style codes end with a color code, e.g. 07-1035-AA-HGRY or 16-4168-LA-TIDYE where the last part is the color. Use the part before the color code as the style (07-1035-AA) and put the color code in color_code.
- Keep letters, digits, dashes and spaces exactly as printed. Uppercase.

COLOR RULES
- If a color word is printed (BLUE, HEATHER GREY, BURGANDY, LT SANDBLAST, 410 LIGHT WASH), use it in plain title case, fixing obvious misspellings (Burgundy).
- If only a code is printed (DZBL, EVBL, PKPZ, ANTR, DKWASH), put the code in color_code and set color to "CODE (plain color)" using the garment photo for the plain color, e.g. "DZBL (Blue)". Without a garment photo use just the code.

SIZE RULES
- Use one of: ${sizes.join(", ")} when the tag shows a letter size. Bilingual sizes: S/CH = S, M/M = M, L/G = L, XL/XG = XL, XXL/XXG = 2XL, XXXL/3XG = 3XL, XS/XCH = XS.
- Number sizes stay as printed: 8, 10, 12, 18, 7/8, 12-14, 32X34. Drop words like AVG/REG. If both a letter and a number are printed (L/G (12-14)), use the letter size.

TYPE RULES
- Choose from: ${types.join(", ")}. Map tag wording: TEE / T-SHIRT -> T-shirt, LONG SLEEVE TEE -> T-shirt, TANK -> Tank top, HOODIE -> Hoodie, JEAN / DNM / DENIM / SKINNY / BOOT CUT -> Jeans, JOGGER -> Joggers, DRESS -> Dress.
- If the tag has no type words, decide from the garment photo if there is one, else leave empty.

GENDER
- From the tag or department (MISSES, WOMENS -> Women; MENS -> Men; GIRLS -> Girls; BOYS -> Boys; BABY/INFANT/TODDLER -> Baby). Leave empty if not clear.

Call record_tag once with what you read.`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  if (!(await callerAllowed(req))) return json({ error: "This app is not allowed to use tag reading." }, 401);
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "NO_KEY", message: "Tag reading is not set up yet: the Anthropic key is missing in Supabase." }, 503);

  let body: { tag?: string; item?: string; types?: string[]; sizes?: string[]; style?: string };
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  if (!body.tag || body.tag.length > 6_000_000) return json({ error: "The tag photo is missing or too large." }, 400);

  const content: unknown[] = [{ type: "image", source: { type: "base64", media_type: "image/jpeg", data: body.tag } }];
  if (body.item && body.item.length < 6_000_000) content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: body.item } });
  content.push({ type: "text", text: prompt(body.types ?? [], body.sizes ?? [], (body.style ?? "").slice(0, 60)) });

  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("TAG_MODEL") || "claude-sonnet-5-5",
      max_tokens: 1000,
      tools: [TOOL],
      tool_choice: { type: "auto" },
      messages: [{ role: "user", content }],
    }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) return json({ error: "AI", message: d?.error?.message || `Tag reading failed (${r.status}).` }, 502);
  const use = (d.content ?? []).find((c: { type: string; name?: string }) => c.type === "tool_use" && c.name === "record_tag");
  if (use) return json(use.input);
  // Safety net: if the model answered in text, try to find the JSON in it.
  const text = (d.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("\n");
  const m = text.match(/\{[\s\S]*\}/);
  if (m) { try { return json(JSON.parse(m[0])); } catch { /* fall through */ } }
  return json({ error: "AI", message: "The tag could not be read. Take the photo again, closer and flat." }, 422);
});
