// ============================================================
// FLIM — send-develop-push  (Supabase Edge Function, Deno)
//
// Scheduled (e.g. every minute) function that finds photos which have just
// developed in a shared roll and sends an APNs push to every roll-mate EXCEPT
// the photo's owner (the owner already gets a local notification on-device).
//
// Deploy:
//   supabase functions deploy send-develop-push --no-verify-jwt
// Schedule (Dashboard → Edge Functions → Schedules, or pg_cron):
//   every 1 minute
//
// Required function secrets (supabase secrets set ...):
//   APNS_KEY_ID         – 10-char key ID from your .p8
//   APNS_TEAM_ID        – Apple Developer team ID
//   APNS_PRIVATE_KEY    – contents of the AuthKey_XXXX.p8 (PEM, with newlines)
//   APNS_BUNDLE_ID      – com.flim.app
//   APNS_ENVIRONMENT    – "sandbox" | "production"  (default: sandbox)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

// --- APNs auth token (ES256 JWT), cached for <1h per Apple's guidance ---
let cachedToken: { jwt: string; issuedAt: number } | null = null;

async function apnsAuthToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 3000) return cachedToken.jwt;

  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const payload = { iss: APNS_TEAM_ID, iat: now };

  const enc = (obj: unknown) =>
    btoa(JSON.stringify(obj)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const signingInput = `${enc(header)}.${enc(payload)}`;

  const key = await importPrivateKey(APNS_PRIVATE_KEY);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${signingInput}.${sigB64}`;
  cachedToken = { jwt, issuedAt: now };
  return jwt;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

async function sendPush(deviceToken: string, title: string, body: string) {
  const jwt = await apnsAuthToken();
  const res = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({
      aps: { alert: { title, body }, sound: "default" },
    }),
  });
  if (!res.ok) {
    console.error("APNs error", res.status, await res.text(), "token", deviceToken.slice(0, 8));
  }
  return res.ok;
}

Deno.serve(async () => {
  // 1. Photos that have developed, belong to a roll, and haven't pushed yet.
  const { data: photos, error } = await supabase
    .from("photos")
    .select("id, user_id, roll_id, rolls(name)")
    .lte("develops_at", new Date().toISOString())
    .eq("push_sent", false)
    .not("roll_id", "is", null);

  if (error) return new Response(`query failed: ${error.message}`, { status: 500 });
  if (!photos?.length) return new Response("nothing to send");

  let sent = 0;
  for (const photo of photos) {
    // 2. Roll members minus the photo owner.
    const { data: members } = await supabase
      .from("roll_members")
      .select("user_id")
      .eq("roll_id", photo.roll_id)
      .neq("user_id", photo.user_id);

    const userIds = (members ?? []).map((m) => m.user_id);
    if (userIds.length) {
      const { data: tokens } = await supabase
        .from("device_tokens")
        .select("token")
        .in("user_id", userIds);

      const rollName = (photo as { rolls?: { name?: string } }).rolls?.name ?? "your roll";
      for (const t of tokens ?? []) {
        if (await sendPush(t.token, "A photo developed 📸", `A new shot is ready in "${rollName}".`)) {
          sent++;
        }
      }
    }

    // 3. Mark as pushed regardless so we don't retry forever.
    await supabase.from("photos").update({ push_sent: true }).eq("id", photo.id);
  }

  return new Response(`sent ${sent} push(es) for ${photos.length} photo(s)`);
});
