// ============================================================
// FLIM send-daily-digest  (Supabase Edge Function, Deno)
//
// ONE notification per person per day summarising what the people they follow posted, instead of
// a push per post. At a hundred follows, per-post notifications are an uninstall, and worse, they
// train people to switch notifications off entirely — which costs the reveal alerts that are the
// whole point of the app. A digest is a fixed one-per-day cost no matter how active the network
// gets.
//
// Scheduled HOURLY, not daily. A once-a-day cron that misses its window sends nothing that day;
// running hourly and gating on `digest_state.last_sent_at` means a missed run is picked up on the
// next pass, and the covered window stretches to match rather than dropping posts.
//
// Only notifies people who: follow at least one person who posted in the window, have a device
// token, aren't blocked either way with the poster, and haven't already had a digest inside
// DIGEST_INTERVAL_HOURS.
//
// Deploy:
//   supabase functions deploy send-daily-digest --no-verify-jwt
// Requires: supabase/migrations/2026-08-03_daily_digest_state.sql
//
// SCHEDULED (pg_cron job `flim-daily-digest`):  0 14-23,0-1 * * *
//   Hourly, but only between 14:00 and 01:00 UTC — roughly 10am to 9pm US Eastern. The other two
//   push functions run every minute because they're reacting to something the user just did; this
//   one initiates contact, so the hour it fires is the hour someone's phone buzzes. Since each
//   person gets at most one digest per DIGEST_INTERVAL_HOURS, restricting WHEN the job runs is
//   what keeps a digest from landing at 4am: the first eligible run after their window expires is
//   always inside daytime.
//
//   The window assumes a US-Eastern-weighted user base, which is true today and won't stay true.
//   The proper fix is a per-user timezone (or just the hour they usually open the app) and a
//   send-window check per recipient; until then this is a blunt instrument that errs toward not
//   waking anyone up. To change it:
//     SELECT cron.unschedule('flim-daily-digest');
//     SELECT cron.schedule('flim-daily-digest', '<cron>', $$ SELECT net.http_post(url := '<fn url>'); $$);
//
// Uses the SAME APNs secrets as the other push functions (APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_ENVIRONMENT).
// ============================================================

// Pinned deliberately, see send-social-push: an unpinned `@2` re-resolves on every deploy and an
// upstream publishing problem then breaks deploys of code that hasn't changed.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY")!;
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.flim.app";
const APNS_HOST = (Deno.env.get("APNS_ENVIRONMENT") ?? "sandbox") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

/// How long between digests for one person. 20 rather than 24 so a run that drifts slightly later
/// each day (cron jitter, a slow pass) doesn't skip a whole day by arriving 23h58m after the last.
const DIGEST_INTERVAL_HOURS = 20;
/// Never look further back than this, so someone returning after a month gets "yesterday's
/// photos", not a summary of four hundred.
const MAX_WINDOW_HOURS = 48;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---- Copy ---------------------------------------------------------------
//
// Pure, and exported, so it can be exercised without APNs, a database, or a schedule. The wording
// is the whole feature: a digest people don't open is just a per-post notification with extra
// steps.

export interface DigestCopy {
  title: string;
  body: string;
}

/// Builds the notification for one person.
///
/// `handles` are the posters, most-recent first, WITHOUT the leading @. Names up to three people
/// because a notification title truncates around there on the lock screen, and a name you
/// recognise is what makes this worth opening — "5 new photos" could be from anyone.
export function digestCopy(handles: string[], photoCount: number): DigestCopy {
  const names = handles.map((h) => `@${h}`);
  const photos = photoCount === 1 ? "1 new photo" : `${photoCount} new photos`;

  let who: string;
  if (names.length === 1) {
    who = names[0];
  } else if (names.length === 2) {
    who = `${names[0]} and ${names[1]}`;
  } else if (names.length === 3) {
    who = `${names[0]}, ${names[1]} and ${names[2]}`;
  } else {
    const others = names.length - 2;
    who = `${names[0]}, ${names[1]} and ${others} others`;
  }

  // Who in the title, what in the body. The reverse ("5 new photos" / "from @ana…") buries the
  // only part that makes someone care.
  return {
    title: names.length === 1 ? `${who} posted` : `${who} posted`,
    body: photoCount === 1 && names.length === 1 ? "Tap to see it" : `${photos} to catch up on`,
  };
}

// ---- APNs ---------------------------------------------------------------

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
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

// Matches the `flim` contract every push function uses (see send-social-push for the full
// destination list). The digest always opens the feed, and the feed destination carries no id.
const FEED_ROUTE = { t: "feed" as const };

async function sendPush(deviceToken: string, title: string, body: string): Promise<boolean> {
  const jwt = await apnsAuthToken();
  const res = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      // Priority 5, not 10: a digest is not time-critical, and letting iOS deliver it on the
      // device's own schedule is both better for battery and less likely to arrive mid-sentence.
      "apns-priority": "5",
    },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, flim: FEED_ROUTE }),
  });
  const reason = res.ok ? undefined : await res.text();
  console.log(JSON.stringify({
    at: "apns_send", kind: "digest", ok: res.ok, status: res.status,
    host: APNS_HOST, apnsId: res.headers.get("apns-id"),
    token8: deviceToken.slice(0, 8), reason,
  }));
  return res.ok;
}

// ---- Run ----------------------------------------------------------------

Deno.serve(async () => {
  const now = Date.now();
  const maxWindowStart = new Date(now - MAX_WINDOW_HOURS * 3600_000);

  // Everyone with a registered device is a candidate; nobody else can be notified anyway.
  const { data: tokenRows } = await supabase.from("device_tokens").select("user_id, token");
  const tokensByUser = new Map<string, string[]>();
  for (const row of tokenRows ?? []) {
    const list = tokensByUser.get(row.user_id) ?? [];
    list.push(row.token);
    tokensByUser.set(row.user_id, list);
  }
  if (tokensByUser.size === 0) return new Response("no devices");

  const { data: stateRows } = await supabase.from("digest_state").select("user_id, last_sent_at");
  const lastSent = new Map<string, number>(
    (stateRows ?? []).map((r) => [r.user_id as string, new Date(r.last_sent_at).getTime()]),
  );

  // Posts inside the widest window any user could need. Fetched once, then filtered per user,
  // rather than a query per candidate.
  const { data: recentPosts } = await supabase
    .from("posts")
    .select("id, user_id, created_at")
    .eq("hidden", false)
    .gte("created_at", maxWindowStart.toISOString())
    .order("created_at", { ascending: false });
  if (!recentPosts || recentPosts.length === 0) return new Response("no recent posts");

  const posterIds = [...new Set(recentPosts.map((p) => p.user_id as string))];

  // Who follows those posters. One query, then grouped, for the same reason.
  const { data: followRows } = await supabase
    .from("follows")
    .select("follower_id, following_id")
    .in("following_id", posterIds);

  const followingByUser = new Map<string, Set<string>>();
  for (const f of followRows ?? []) {
    const set = followingByUser.get(f.follower_id) ?? new Set<string>();
    set.add(f.following_id);
    followingByUser.set(f.follower_id, set);
  }

  const { data: blockRows } = await supabase.from("blocks").select("blocker_id, blocked_id");
  const blockPairs = new Set<string>();
  for (const b of blockRows ?? []) {
    blockPairs.add(`${b.blocker_id}|${b.blocked_id}`);
    blockPairs.add(`${b.blocked_id}|${b.blocker_id}`);
  }

  const { data: profileRows } = await supabase.from("profiles").select("id, username").in("id", posterIds);
  const handleById = new Map<string, string>(
    (profileRows ?? []).map((p) => [p.id as string, (p.username as string) ?? "someone"]),
  );

  let sent = 0;
  let considered = 0;

  for (const [userId, tokens] of tokensByUser) {
    const following = followingByUser.get(userId);
    if (!following || following.size === 0) continue;

    // Window starts at the last digest actually sent, so a missed run rolls into the next one.
    // A user with no state yet gets the default window rather than their whole history.
    const since = Math.max(lastSent.get(userId) ?? 0, now - MAX_WINDOW_HOURS * 3600_000);
    if (now - (lastSent.get(userId) ?? 0) < DIGEST_INTERVAL_HOURS * 3600_000) continue;

    considered++;

    const theirs = recentPosts.filter((p) => {
      const poster = p.user_id as string;
      if (poster === userId) return false;                       // your own posts aren't news
      if (!following.has(poster)) return false;
      if (blockPairs.has(`${userId}|${poster}`)) return false;
      return new Date(p.created_at).getTime() > since;
    });
    if (theirs.length === 0) continue;

    // Posters most-recent first, deduped: `recentPosts` is already ordered that way.
    const handles: string[] = [];
    for (const p of theirs) {
      const h = handleById.get(p.user_id as string);
      if (h && !handles.includes(h)) handles.push(h);
    }
    if (handles.length === 0) continue;

    const { title, body } = digestCopy(handles, theirs.length);
    let delivered = false;
    for (const token of tokens) {
      if (await sendPush(token, title, body)) delivered = true;
    }

    // Recorded even if APNs rejected every token: the alternative is retrying a dead device every
    // hour forever. A real delivery problem shows up in the per-send log above.
    await supabase.from("digest_state")
      .upsert({ user_id: userId, last_sent_at: new Date(now).toISOString() }, { onConflict: "user_id" });
    if (delivered) sent++;
  }

  const summary = `digest: ${sent} sent, ${considered} considered`;
  console.log(JSON.stringify({ at: "digest_run", sent, considered }));
  return new Response(summary);
});
