// ============================================================
// FLIM — send-social-push  (Supabase Edge Function, Deno)
//
// Scheduled (e.g. every minute) function that notifies a post's OWNER when
// someone else comments or reacts on their post. Reactions are batched per
// person (one push listing that person's emoji), so a burst of reactions from
// one friend is a single notification — the way Lapse did it, not one-per-emoji.
//
// Deploy:
//   supabase functions deploy send-social-push --no-verify-jwt
// Schedule (Dashboard → Edge Functions → Schedules, or pg_cron): every 1 minute
//
// Uses the SAME APNs secrets as send-develop-push (APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_ENVIRONMENT). SUPABASE_URL /
// SUPABASE_SERVICE_ROLE_KEY are injected automatically.
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

async function sendPush(deviceToken: string, title: string, body: string): Promise<boolean> {
  const jwt = await apnsAuthToken();
  const res = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" } }),
  });
  if (!res.ok) {
    console.error("APNs error", res.status, await res.text(), "token", deviceToken.slice(0, 8));
  }
  return res.ok;
}

async function handle(userId: string): Promise<string> {
  const { data } = await supabase.from("profiles").select("username").eq("id", userId).single();
  return data?.username ? `@${data.username}` : "Someone";
}

async function tokensFor(userId: string): Promise<string[]> {
  const { data } = await supabase.from("device_tokens").select("token").eq("user_id", userId);
  return (data ?? []).map((t) => t.token);
}

Deno.serve(async () => {
  let sent = 0;

  // ---- Comments: one push per comment, to the post owner (never self) ----
  const { data: comments } = await supabase
    .from("post_comments")
    .select("id, post_id, user_id, body, posts(user_id)")
    .eq("push_sent", false);

  for (const c of comments ?? []) {
    const ownerId = (c as { posts?: { user_id?: string } }).posts?.user_id;
    if (ownerId && ownerId !== c.user_id) {
      const name = await handle(c.user_id);
      const preview = c.body.length > 90 ? c.body.slice(0, 87) + "…" : c.body;
      for (const token of await tokensFor(ownerId)) {
        if (await sendPush(token, `${name} commented`, preview)) sent++;
      }
    }
    await supabase.from("post_comments").update({ push_sent: true }).eq("id", c.id);
  }

  // ---- Reactions: batch per (post, reactor) → one push listing their emoji ----
  const { data: reactions } = await supabase
    .from("post_reactions")
    .select("id, post_id, user_id, emoji, posts(user_id)")
    .eq("push_sent", false);

  const groups = new Map<string, { ownerId?: string; reactorId: string; emojis: string[]; ids: string[] }>();
  for (const r of reactions ?? []) {
    const key = `${r.post_id}|${r.user_id}`;
    const g = groups.get(key) ??
      { ownerId: (r as { posts?: { user_id?: string } }).posts?.user_id, reactorId: r.user_id, emojis: [], ids: [] };
    g.emojis.push(r.emoji);
    g.ids.push(r.id);
    groups.set(key, g);
  }

  for (const g of groups.values()) {
    if (g.ownerId && g.ownerId !== g.reactorId) {
      const name = await handle(g.reactorId);
      const emojis = [...new Set(g.emojis)].join(" ");
      for (const token of await tokensFor(g.ownerId)) {
        if (await sendPush(token, `${name} reacted ${emojis}`, "to your photo")) sent++;
      }
    }
    await supabase.from("post_reactions").update({ push_sent: true }).in("id", g.ids);
  }

  return new Response(`sent ${sent} social push(es)`);
});
