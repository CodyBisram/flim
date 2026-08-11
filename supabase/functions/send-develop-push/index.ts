// ============================================================
// FLIM, send-develop-push  (Supabase Edge Function, Deno)
//
// Scheduled (e.g. every minute) function that finds photos which have just
// developed in a shared roll and sends ONE APNs push per (roll, recipient), 
// regardless of how many shots the roll holds.
//
// Recipient rule: only roll-mates who took ZERO shots in the developed batch.
// Anyone who shot into the roll already got a LOCAL "your roll developed"
// notification on their own device at capture time (NotificationService
// .scheduleRollDevelopNotification, one per roll), so pushing them again would
// double-notify the same event. The remote push exists for the OTHER members,
// who took no shots and would otherwise never learn the roll is ready.
//
// Personal instants (roll_id NULL) develop immediately and never push, the
// `roll_id is not null` filter below excludes them.
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

// Pinned deliberately. An unpinned `@2` re-resolves to the newest 2.x on EVERY deploy, so an
// upstream publishing problem breaks deploys of code that hasn't changed: 2.112.0 ships without a
// denonext build of its auth-js dependency, which 404s at bundle time and made this function
// undeployable while the running copy carried on fine. A pin means the version only moves when
// someone moves it.
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

// Names the DESTINATION the notification opens (a roll that just developed), matching the same
// `flim` contract every push function uses. See send-social-push for the full destination list;
// this function only ever sends "reveal".
interface FlimRoute {
  t: "reveal";
  id: string;
}

async function sendPush(
  deviceToken: string,
  title: string,
  body: string,
  flim?: FlimRoute,
): Promise<boolean> {
  const jwt = await apnsAuthToken();
  const payload: Record<string, unknown> = { aps: { alert: { title, body }, sound: "default" } };
  if (flim) payload.flim = flim;
  const res = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  // Structured per-send record: `host` shows which APNs environment we hit, so a
  // sandbox/production mismatch (production TestFlight token rejected by sandbox
  // with 400 BadDeviceToken) is visible in the logs without guesswork. `reason`
  // is only read on failure (Apple returns JSON like {"reason":"BadDeviceToken"}).
  const reason = res.ok ? undefined : await res.text();
  console.log(JSON.stringify({
    at: "apns_send",
    ok: res.ok,
    status: res.status,
    host: APNS_HOST,
    apnsId: res.headers.get("apns-id"),
    token8: deviceToken.slice(0, 8),
    reason,
  }));
  return res.ok;
}

// Blocks. This function runs with the SERVICE ROLE, so RLS is bypassed entirely and
// `is_blocked_either_way` never applies here; every push path has to ask explicitly, same
// reasoning as send-social-push's `blockedEitherWay` and send-daily-digest's `blockPairs`. This
// payload is roll-level (name + shot count, not authored content), but every other push path
// already checks blocks, and "every push path checks blocks" is a much easier invariant to keep
// than a list of exceptions. Loaded once per run and reused across every roll in the batch, same
// shape as send-daily-digest's blockPairs (many recipients x many sources, unlike
// send-social-push's single-notify()-call door).
async function loadBlockPairs(): Promise<Set<string>> {
  const { data } = await supabase.from("blocks").select("blocker_id, blocked_id");
  const pairs = new Set<string>();
  for (const b of data ?? []) {
    pairs.add(`${b.blocker_id}|${b.blocked_id}`);
    pairs.add(`${b.blocked_id}|${b.blocker_id}`);
  }
  return pairs;
}

Deno.serve(async () => {
  // 1. Photos that have developed, belong to a roll, and haven't pushed yet.
  //    Personal instants (roll_id NULL) are excluded, they develop immediately
  //    and never generate a remote push.
  const { data: photos, error } = await supabase
    .from("photos")
    .select("id, user_id, roll_id, rolls(name)")
    .lte("develops_at", new Date().toISOString())
    .eq("push_sent", false)
    .not("roll_id", "is", null);

  if (error) return new Response(`query failed: ${error.message}`, { status: 500 });
  if (!photos?.length) return new Response("nothing to send");

  const blockPairs = await loadBlockPairs();

  // 2. Collapse the batch into one entry per roll. `shooters` = everyone who took
  //    a shot in this developed batch (they already got a local notification);
  //    `photoIds` = every photo of the roll to flip push_sent on once we're done.
  type Row = { id: string; user_id: string; roll_id: string; rolls?: { name?: string } };
  const rolls = new Map<string, { name: string; shooters: Set<string>; photoIds: string[] }>();
  for (const p of photos as Row[]) {
    const g = rolls.get(p.roll_id) ?? {
      name: p.rolls?.name ?? "your roll",
      shooters: new Set<string>(),
      photoIds: [],
    };
    g.shooters.add(p.user_id);
    g.photoIds.push(p.id);
    rolls.set(p.roll_id, g);
  }

  let sent = 0;
  for (const [rollId, g] of rolls) {
    // 3. Recipients = roll members who took NO shots in this batch. Shooters are
    //    skipped because they already have the on-device local notification.
    //    Also skipped: anyone blocked either-way with ANY shooter in this batch — the
    //    roll developing is not their business to hear about from someone they've cut
    //    contact with, the same way a blocked commenter's push never reaches you.
    const { data: members } = await supabase
      .from("roll_members")
      .select("user_id")
      .eq("roll_id", rollId);

    const recipientIds = (members ?? [])
      .map((m) => m.user_id as string)
      .filter((uid) => !g.shooters.has(uid))
      .filter((uid) => ![...g.shooters].some((shooter) => blockPairs.has(`${uid}|${shooter}`)));

    if (recipientIds.length) {
      const { data: tokens } = await supabase
        .from("device_tokens")
        .select("token")
        .in("user_id", recipientIds);

      // One push per (roll, recipient device), naming the roll + total shot count.
      const count = g.photoIds.length;
      const title = `"${g.name}" developed 🎞`;
      const body = `${count} shot${count === 1 ? "" : "s"} ${count === 1 ? "is" : "are"} ready.`;
      const uniqueTokens = [...new Set((tokens ?? []).map((t) => t.token as string))];
      // Built fresh from THIS iteration's rollId, never hoisted above the loop, so a run that
      // processes several rolls back-to-back can't carry one roll's id into another's pushes.
      const route: FlimRoute = { t: "reveal", id: rollId };
      for (const token of uniqueTokens) {
        if (await sendPush(token, title, body, route)) sent++;
      }
    }

    // 4. Mark every photo of the batch as pushed regardless of send outcome, so a
    //    dead token or a member with no device can't make us retry this roll forever.
    await supabase.from("photos").update({ push_sent: true }).in("id", g.photoIds);
  }

  return new Response(`sent ${sent} push(es) for ${rolls.size} roll(s)`);
});
