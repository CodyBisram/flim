// ============================================================
// FLIM public-screening  (Supabase Edge Function, Deno). v2, product rule 9.
//
// The one door a signed-out browser has into FLIM. Two requests, both keyed by a screening
// link's 24-character token:
//
//   GET ?t=TOKEN          the screening: kind, title, when the link ends, how many people took
//                         the prints (never who), and each print as an opaque id + when taken.
//   GET ?t=TOKEN&p=ID     one print's image bytes.
//
// Why a function and not an anon grant: the database grants nothing to anon for this.
// `screening_by_token` is executable by service_role only and decides, at EVERY request, whether
// the link still plays (stopped, expired, its sharer left the roll) and what plays (hidden, put
// away, covered and blocked prints drop out). A stopped link stops serving images at once.
//
// Why the bytes come through here instead of signed storage URLs: a storage path is
// `<user id>/<photo id>_feed.jpg`, and a signed URL carries it. Handing those out would name each
// print's account and show which prints share an author, which the "no names" decision rules
// out. A print's id here is a hash of the token and its path: stable for the link, meaningless
// without the server, different for every link.
//
// Every token that does not play answers 404, whatever the reason, so the page cannot tell an
// expired link from one that never existed. Tokens are never logged.
//
// Deploy (FLIM Dev only until v2 launches):
//   supabase functions deploy public-screening --no-verify-jwt --project-ref kwhgbrdznaogkdyqitvi
// ============================================================

// Pinned deliberately, see send-social-push.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

const TOKEN = /^[A-Za-z0-9_-]{24}$/;
const PRINT_ID = /^[0-9a-f]{32}$/;
/// The only storage path this function will ever read: `<account id>/<name>.jpg`. Paths are
/// client-writable and this reads with the service key, which bypasses every policy: a `..` or a
/// query string here would point that key at anything the API serves. The read enforces the same
/// shape; this is the second lock, independent of the database.
const PRINT_PATH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[A-Za-z0-9_-]+\.jpe?g$/;
/// How long one isolate reuses a read. A viewing asks for every print in a burst of requests;
/// without this each one re-ran the whole read. Short, so a stopped link stops serving at once.
const READ_REUSE_MS = 5_000;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const common = {
  // Public by design: the token is the secret and there are no cookies to ride along.
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, OPTIONS",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    // Never cached: a stopped link must stop at once.
    headers: { ...common, "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

interface ScreeningPrint {
  path: string;
  takenAt: string;
  burst: string | null;
  sharpness: number | null;
}

interface Screening {
  kind: "roll" | "month";
  title: string;
  expiresAt: string;
  people: number;
  prints: ScreeningPrint[];
}

/// A print's public id: the first 128 bits of SHA-256(token, path), hex.
async function printId(token: string, path: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${token}\n${path}`));
  return [...new Uint8Array(digest).slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type Read = { screening: Screening | null; ids: string[] };
/// In flight or landed, per token: a page asks for every print at once, and they share one read.
const reads = new Map<string, { at: number; read: Promise<Read | "error"> }>();

/// The screening and its print ids, for READ_REUSE_MS. A print whose path is not the one allowed
/// shape is dropped here, so it is neither listed nor served.
function read(token: string): Promise<Read | "error"> {
  const held = reads.get(token);
  if (held && Date.now() - held.at < READ_REUSE_MS) return held.read;
  const fresh = (async (): Promise<Read | "error"> => {
    const { data, error } = await supabase.rpc("screening_by_token", { p_token: token });
    if (error) {
      console.error("screening_by_token failed:", error.code ?? "", error.message);
      reads.delete(token);   // a failure is not kept: the next request tries again
      return "error";
    }
    const screening = (data as Screening | null) ?? null;
    if (screening) screening.prints = screening.prints.filter((p) => PRINT_PATH.test(p.path));
    const ids = screening ? await Promise.all(screening.prints.map((p) => printId(token, p.path))) : [];
    return { screening, ids };
  })();
  if (reads.size > 500) reads.clear();
  reads.set(token, { at: Date.now(), read: fresh });
  return fresh;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: common });
  if (req.method !== "GET") return json(405, { error: "method" });

  const params = new URL(req.url).searchParams;
  const token = params.get("t") ?? "";
  const wanted = params.get("p");
  if (!TOKEN.test(token) || (wanted !== null && !PRINT_ID.test(wanted))) return json(404, { error: "gone" });

  const result = await read(token);
  if (result === "error") return json(503, { error: "unavailable" });
  const { screening, ids } = result;
  if (!screening) return json(404, { error: "gone" });

  if (wanted === null) {
    // A burst's database id would be the same on every link; hashed per link like the prints.
    const bursts = await Promise.all(screening.prints.map((p) => p.burst ? printId(token, `burst:${p.burst}`) : null));
    return json(200, {
      kind: screening.kind,
      title: screening.title,
      expiresAt: screening.expiresAt,
      people: screening.people,
      prints: screening.prints.map((p, i) => ({
        id: ids[i],
        takenAt: p.takenAt,
        burst: bursts[i],
        sharpness: p.sharpness,
      })),
    });
  }

  const index = ids.indexOf(wanted);
  if (index < 0) return json(404, { error: "gone" });
  const path = screening.prints[index].path;
  if (!PRINT_PATH.test(path)) return json(404, { error: "gone" });
  const { data: file, error } = await supabase.storage.from("photos").download(path);
  if (error || !file) {
    console.error("download failed:", error?.message ?? "no file");
    return json(404, { error: "gone" });
  }
  return new Response(file.stream(), {
    status: 200,
    headers: {
      ...common,
      // Fixed, never passed through: only JPEG paths are ever read.
      "content-type": "image/jpeg",
      // The viewer's own browser may keep a print it already saw for a few minutes; nothing
      // shared (CDNs) may, so a stopped link is not served on from a cache.
      "cache-control": "private, max-age=600",
    },
  });
});
