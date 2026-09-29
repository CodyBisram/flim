// ============================================================
// FLIM notify-owner  (Supabase Edge Function, Deno)
//
// One push, to the owner's own devices only, with a title and body the caller supplies. Built for
// the App Store watcher (.github/workflows/asc-watch.yml): "1.6.1 is In Review", "1.6.1 is live".
// It can reach nobody else: the recipient is the owner's fixed auth id, the same one
// public.owner_user_id() returns, never taken from the request.
//
// Deploys with --no-verify-jwt, so every request must carry `x-owner-notify-secret` matching the
// OWNER_NOTIFY_SECRET function secret. Checked FIRST and FAILS CLOSED: with the secret unset,
// every request is refused with 503, the same guard as send-one-shot-push.
//
// Deploy:
//   supabase secrets set OWNER_NOTIFY_SECRET=<the value in ~/.flim/owner-notify-secret>
//   supabase functions deploy notify-owner --no-verify-jwt
//
// Invoke:
//   curl -s -X POST -H "x-owner-notify-secret: <secret>" -H "content-type: application/json" \
//     -d '{"title":"FLIM 1.6.1","body":"In Review."}' "<fn url>"
//
// Uses the SAME APNs secrets as the other push functions (APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_ENVIRONMENT).
// ============================================================

// Pinned deliberately, see send-social-push.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

const OWNER_USER_ID = "f43287d4-f239-415b-af45-650bbee62e83";

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY")!;
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.flim.app";
const APNS_HOST = (Deno.env.get("APNS_ENVIRONMENT") ?? "sandbox") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const OWNER_NOTIFY_SECRET = Deno.env.get("OWNER_NOTIFY_SECRET");

/// Constant-time comparison over fixed-length digests, as in send-one-shot-push.
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [aHash, bHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const aBytes = new Uint8Array(aHash);
  const bBytes = new Uint8Array(bHash);
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) diff |= aBytes[i] ^ bBytes[i];
  return diff === 0;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

async function apnsAuthToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const enc = (obj: unknown) =>
    btoa(JSON.stringify(obj)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const signingInput = `${enc({ alg: "ES256", kid: APNS_KEY_ID })}.${enc({ iss: APNS_TEAM_ID, iat: now })}`;
  const key = await importPrivateKey(APNS_PRIVATE_KEY);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${signingInput}.${sigB64}`;
}

Deno.serve(async (req) => {
  if (!OWNER_NOTIFY_SECRET) {
    return Response.json({ error: "OWNER_NOTIFY_SECRET is not set. Refusing every request until it is." }, { status: 503 });
  }
  if (!(await timingSafeEqual(req.headers.get("x-owner-notify-secret") ?? "", OWNER_NOTIFY_SECRET))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  if (req.method !== "POST") return Response.json({ error: "POST only" }, { status: 405 });

  let title = "", body = "";
  try {
    const json = await req.json();
    title = String(json?.title ?? "").trim().slice(0, 80);
    body = String(json?.body ?? "").trim().slice(0, 240);
  } catch {
    return Response.json({ error: "expected JSON {title, body}" }, { status: 400 });
  }
  if (!title || !body) return Response.json({ error: "title and body are required" }, { status: 400 });

  const { data, error } = await supabase.from("device_tokens").select("token").eq("user_id", OWNER_USER_ID);
  if (error) return Response.json({ error: "device_tokens read failed" }, { status: 502 });
  const tokens = ((data ?? []) as { token: string }[]).map((r) => r.token);
  if (tokens.length === 0) return Response.json({ sent: 0, devices: 0 });

  const jwt = await apnsAuthToken();
  let sent = 0;
  const statuses: number[] = [];
  for (const token of tokens) {
    try {
      const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": APNS_BUNDLE_ID,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" } }),
        signal: AbortSignal.timeout(10_000),
      });
      statuses.push(res.status);
      if (res.ok) sent++;
    } catch {
      statuses.push(0);
    }
  }
  console.log(JSON.stringify({ at: "owner_notified", sent, devices: tokens.length, statuses }));
  return Response.json({ sent, devices: tokens.length, statuses });
});
