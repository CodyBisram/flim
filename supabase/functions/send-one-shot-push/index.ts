// ============================================================
// FLIM send-one-shot-push  (Supabase Edge Function, Deno)
//
// A single, manually invoked nudge to one cohort. NOT scheduled, and deliberately not wired to
// pg_cron: every other push here is reactive (something happened to you, you are told), and this
// one initiates contact for a product reason, so a human decides when it goes.
//
// Two guards, because a push cannot be unsent:
//
//   1. DRY RUN BY DEFAULT. Without `?send=true` it resolves the cohort, reports the count and a
//      sample, and sends nothing. That is the only way to see who is about to be contacted.
//   2. A CLAIM LEDGER. `one_shot_push` has a primary key on (campaign, user_id) and a row is
//      claimed BEFORE the send. A second invocation claims nothing and sends nothing. If the
//      function dies mid-run the claims stay and those people are skipped, which is the right
//      direction to fail: one missed nudge beats a second one.
//
// Deploy:
//   supabase functions deploy send-one-shot-push --no-verify-jwt
// Requires: supabase/migrations/2026-08-19_one_shot_push.sql
//
// Invoke (dry run):   curl -s "<fn url>?campaign=first-shot"
// Invoke (for real):  curl -s "<fn url>?campaign=first-shot&send=true"
//
// Uses the SAME APNs secrets as the other push functions (APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_ENVIRONMENT).
// ============================================================

// Pinned deliberately, see send-social-push: an unpinned `@2` re-resolves on every deploy and an
// upstream publishing problem then breaks deploys of code that has not changed.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

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

/// Accounts younger than this are left alone. Somebody who signed up an hour ago and has not
/// shot yet is not disengaged, they are mid-onboarding, and a nudge reads as nagging.
const MIN_ACCOUNT_AGE_HOURS = 24;

/// The campaigns this function knows how to send, by name. A campaign has to be added here to be
/// sendable, so a typo in the query string cannot invent one and bypass the claim ledger.
const CAMPAIGNS: Record<string, { title: string; body: string; route: unknown }> = {
  "first-shot": {
    title: "Your camera is still empty",
    body: "Take one shot. It develops the moment you do, and nobody sees it until you say so.",
    route: { t: "camera" },
  },
};

// ------------------------------------------------------------
// Cohort

/// Everyone who has never taken a single photograph, can actually be reached, and has been around
/// long enough for that to mean something.
///
/// "Never shot" is zero rows in `photos`, not zero POSTS: someone with frames sitting unsorted in
/// their darkroom has taken a photograph and is a different problem entirely.
async function cohort(campaign: string): Promise<string[]> {
  // Everyone with a registered device. Registering a token is the opt-in: there is no separate
  // preference column, so nobody else is reachable and nobody else should be considered.
  const { data: tokenRows } = await supabase.from("device_tokens").select("user_id");
  const reachable = [...new Set(((tokenRows ?? []) as { user_id: string }[]).map((r) => r.user_id))];
  if (reachable.length === 0) return [];

  // Who among them has ever taken a frame. One query, not one per person.
  const { data: shooters } = await supabase
    .from("photos").select("user_id").in("user_id", reachable);
  const hasShot = new Set(((shooters ?? []) as { user_id: string }[]).map((r) => r.user_id));

  const cutoff = new Date(Date.now() - MIN_ACCOUNT_AGE_HOURS * 3600_000).toISOString();
  const { data: profiles } = await supabase
    .from("profiles").select("id, created_at")
    .in("id", reachable).lte("created_at", cutoff);

  const eligible = ((profiles ?? []) as { id: string }[])
    .map((p) => p.id)
    .filter((id) => !hasShot.has(id));

  // Anyone already claimed by this campaign is out, on every run including the dry one, so the
  // dry run's count is the number that would ACTUALLY be sent rather than the cohort size.
  const { data: claimed } = await supabase
    .from("one_shot_push").select("user_id").eq("campaign", campaign);
  const already = new Set(((claimed ?? []) as { user_id: string }[]).map((r) => r.user_id));
  return eligible.filter((id) => !already.has(id));
}

// ------------------------------------------------------------
// APNs, the same as every other push function here

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
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
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
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

async function push(token: string, title: string, body: string, route: unknown): Promise<number> {
  const jwt = await apnsAuthToken();
  const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "5",
    },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, flim: route }),
  });
  return res.status;
}

// ------------------------------------------------------------

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const name = url.searchParams.get("campaign") ?? "";
  const send = url.searchParams.get("send") === "true";
  const copy = CAMPAIGNS[name];

  if (!copy) {
    return Response.json(
      { error: "unknown campaign", known: Object.keys(CAMPAIGNS) }, { status: 400 },
    );
  }

  const recipients = await cohort(name);
  if (!send) {
    return Response.json({
      dryRun: true, campaign: name, wouldSend: recipients.length,
      copy, sample: recipients.slice(0, 5),
      note: "Nothing was sent. Re-invoke with &send=true to actually send.",
    });
  }

  let sent = 0;
  let failed = 0;
  for (const userId of recipients) {
    // Claim first. A duplicate key here means another run already has this person.
    const { error: claimErr } = await supabase
      .from("one_shot_push").insert({ campaign: name, user_id: userId });
    if (claimErr) continue;

    const { data: tokens } = await supabase
      .from("device_tokens").select("token").eq("user_id", userId);
    let delivered = false;
    for (const row of (tokens ?? []) as { token: string }[]) {
      const status = await push(row.token, copy.title, copy.body, copy.route);
      if (status === 200) delivered = true;
      else console.warn(JSON.stringify({ at: "push_failed", userId, status }));
    }
    if (delivered) {
      sent++;
      await supabase.from("one_shot_push")
        .update({ sent_at: new Date().toISOString() })
        .eq("campaign", name).eq("user_id", userId);
    } else {
      failed++;
    }
  }

  console.log(JSON.stringify({ at: "one_shot_push_done", campaign: name, sent, failed }));
  return Response.json({ dryRun: false, campaign: name, sent, failed });
});
