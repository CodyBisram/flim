// ============================================================
// FLIM photo delivery Worker
//
// Serves photo bytes from R2 instead of Supabase Storage, which is the whole point of the
// migration: R2 charges nothing for egress, and egress is the only FLIM cost that grows with
// LOOKING rather than shooting, i.e. the only unbounded one.
//
// Authorization is NOT reimplemented here, deliberately. Postgres RLS is the single authority on
// who can see which photo, so this Worker asks it: the caller presents their ordinary Supabase
// session JWT, the Worker verifies the signature locally (HS256 against SUPABASE_JWT_SECRET, no
// round trip), then calls the `can_view_photo` RPC AS that user, so the answer inherits every
// current and future policy: roll membership, follower gating, covered posts, blocks. A yes is
// cached at the edge for ten minutes per (user, photo), so the Postgres cost is one tiny query
// per user per photo per ten minutes, not per view.
//
//   GET /photo/<path>            with Authorization: Bearer <supabase user JWT>
//     -> 200 image bytes from R2 (edge-cached), 403, or 404
//
// Bindings (set in wrangler.toml / dashboard):
//   PHOTOS        R2 bucket binding
//   SUPABASE_URL  https://wxvwamwrjlrvqmuaafjv.supabase.co
//   SUPABASE_JWT_SECRET  (secret) the project's JWT secret
//   SUPABASE_ANON_KEY    the anon key, required as apikey on RPC calls
// ============================================================

async function verifyJWT(token, secret) {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const data = enc.encode(parts[0] + "." + parts[1]);
  const sig = Uint8Array.from(atob(parts[2].replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
  if (!await crypto.subtle.verify("HMAC", key, sig, data)) return null;
  const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
  if (payload.exp && payload.exp < Date.now() / 1000) return null;
  return payload;
}

async function canView(env, token, path) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/can_view_photo`, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_path: path }),
  });
  if (!res.ok) return false;
  return (await res.json()) === true;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/photo/")) return new Response("not found", { status: 404 });
    const path = decodeURIComponent(url.pathname.slice("/photo/".length));
    // Paths are `<user uuid>/<photo uuid>[_thumb|_feed].jpg`; reject anything shaped otherwise
    // before it reaches R2 or Postgres.
    if (!/^[0-9a-f-]{36}\/[0-9a-f-]{36}(_thumb|_feed)?\.(jpg|jpeg|png|heic)$/.test(path)) {
      return new Response("bad path", { status: 400 });
    }

    const auth = request.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
    if (!token) return new Response("unauthorized", { status: 401 });
    const claims = await verifyJWT(token, env.SUPABASE_JWT_SECRET);
    if (!claims?.sub) return new Response("unauthorized", { status: 401 });

    // Edge-cache the AUTHORIZATION VERDICT per (user, photo), not just the bytes: the bytes are
    // the same for everyone, but whether you may have them is not.
    const verdictKey = new Request(`https://verdict.internal/${claims.sub}/${path}`);
    const cache = caches.default;
    let allowed = await cache.match(verdictKey);
    if (!allowed) {
      const ok = await canView(env, token, path);
      if (!ok) return new Response("forbidden", { status: 403 });
      ctx.waitUntil(cache.put(verdictKey, new Response("1", {
        headers: { "Cache-Control": "max-age=600" },
      })));
    }

    const object = await env.PHOTOS.get(path);
    if (!object) return new Response("not migrated", { status: 404 });
    return new Response(object.body, {
      headers: {
        "Content-Type": object.httpMetadata?.contentType ?? "image/jpeg",
        // Immutable: a FLIM photo's bytes never change after upload, so the client may cache
        // forever keyed by path. This header plus a path-keyed client cache is most of the win.
        "Cache-Control": "private, max-age=31536000, immutable",
        ETag: object.httpEtag,
      },
    });
  },
};
