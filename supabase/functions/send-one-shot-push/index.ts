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

/// A person to contact, and the exact words for them. Copy is resolved PER RECIPIENT because
/// some of it is about their own state ("4 frames waiting"), and a campaign that rounded that to
/// a generic sentence would be the daily digest with extra steps.
type Recipient = { userId: string; title: string; body: string; route: unknown };

/// The campaigns this function knows how to send, by name. A campaign has to be listed here to be
/// sendable, so a typo in the query string cannot invent one and bypass the claim ledger.
const CAMPAIGNS: Record<string, () => Promise<Recipient[]>> = {
  "first-shot": firstShotCohort,
  "still-no-shot": stillNoShotCohort,
  "checked-again": checkedAgainCohort,
  "waiting-to-sort": waitingToSortCohort,
};

/// Everyone reachable who has never taken a single photograph.
///
/// "Never shot" is zero rows in `photos`, not zero POSTS: someone with frames sitting unsorted in
/// their darkroom has taken a photograph and is a different problem, addressed by the campaign
/// below.
///
/// No minimum account age. Considered and rejected: a brand new account that has not shot yet is
/// arguably mid-onboarding rather than disengaged, but the userbase is small enough that leaving
/// people out costs more than the risk of nudging someone early.
/// Counted per person, server-side, never by fetching photo rows: PostgREST caps a select at
/// 1000 rows, and once `photos` passed that (1808 rows on 2026-09-02) a row fetch silently
/// dropped the shooters past the cap and reported them as never having shot. A dry run showed 13
/// where the database said 7, and six people who had taken photographs would have been told they
/// had not. One HEAD request per reachable account is a few dozen requests, once, by hand.
async function neverShot(): Promise<string[]> {
  const reachable = await reachableUsers();
  const out: string[] = [];
  for (const id of reachable) {
    const { count, error } = await supabase
      .from("photos").select("id", { count: "exact", head: true }).eq("user_id", id);
    // An error is not a zero: a failed count must never turn into "never shot".
    if (error || count === null) continue;
    if (count === 0) out.push(id);
  }
  return out;
}

async function firstShotCohort(): Promise<Recipient[]> {
  return (await neverShot()).map((userId) => ({
    userId,
    title: "Take a shot.",
    // Names the thing, on purpose. Saying "you haven't taken one yet" to somebody who has not is
    // the whole point of a campaign aimed at exactly that.
    //
    // Direct, and not shouted. All caps was the ask and is the wrong instrument: these are by
    // definition the least engaged people on the platform and so the likeliest to answer a
    // notification that reads as spam by turning notifications off, which would cost the reveal
    // alerts that are the whole point.
    //
    // The body removes the two objections that are left: effort, and exposure. A personal frame
    // develops instantly and sits in the sort deck until its owner publishes it, so both halves
    // of that sentence are literally true.
    //
    // Lands on the camera. Reaching it is measurably not the barrier: of the accounts that signed
    // up on or after 2026-08-12, twenty of twenty-one reached a camera the app confirmed was
    // authorized and eleven shot. Deciding to is the barrier, so land on the decision.
    body: "You haven't taken one yet. It develops the instant you do, and nobody sees it until you say so.",
    route: { t: "camera" },
  }));
}

/// The same cohort, a second touch. Sent 2026-09-02 to the seven people still reachable and still
/// at zero, six of whom had the straight "Take a shot." two weeks earlier and did not bite.
///
/// A second nudge to the least engaged people on the platform has to be lighter than the first,
/// not louder: the objection the first one answered (exposure) is answered again by "literally
/// anything", and the rest is a joke at the app's expense rather than theirs. Owner picked this
/// copy from four drafts. Its own campaign name so the ledger keeps the two touches apart, and so
/// a re-run of `first-shot` still sends nothing.
async function stillNoShotCohort(): Promise<Recipient[]> {
  return (await neverShot()).map((userId) => ({
    userId,
    title: "We checked.",
    body: "Not a single shot. The camera is right there, and the first one can be of literally anything.",
    route: { t: "camera" },
  }));
}

/// The sequel to "We checked.", minutes later, to one person. Sent 2026-09-03 to a day-old account
/// the owner wanted to needle twice, with `?user=` so nobody else in the cohort is swept up.
/// Same rule as every second touch: drier than the first, never louder, and the joke stays at the
/// camera's expense. Owner picked this from three drafts.
async function checkedAgainCohort(): Promise<Recipient[]> {
  return (await neverShot()).map((userId) => ({
    userId,
    title: "We checked again.",
    body: "Still nothing. That's fine. The camera can wait. It's a camera.",
    route: { t: "camera" },
  }));
}

/// How long a deck has to have been sitting before it is worth mentioning.
///
/// The point of the floor is the person it excludes. The heaviest poster on the platform had four
/// unsorted frames from the SAME DAY when this was written: telling somebody who is actively
/// shooting that they have frames waiting is describing their afternoon back to them.
const STALE_DECK_HOURS = 48;

/// Everyone reachable whose sort deck has been sitting for a while.
///
/// Deliberately about SORTING rather than posting, which is what it looks like from the outside.
/// Of the four accounts that have shot and never posted, two have every frame still unsorted, so
/// "post to your feed" names a step they have not reached: in the sort deck, swipe-right IS
/// posting. Naming the wrong step is how a nudge gets ignored by someone who would have acted.
async function waitingToSortCohort(): Promise<Recipient[]> {
  const reachable = await reachableUsers();
  if (reachable.length === 0) return [];

  // Same per-person counting as `neverShot`, for the same reason: a row fetch is capped at
  // 1000 and would under-count decks past it. One request per person returns the exact count
  // and the oldest unsorted frame together.
  const cutoff = Date.now() - STALE_DECK_HOURS * 3600_000;
  const decks = new Map<string, { count: number; oldest: number }>();
  for (const id of reachable) {
    const { data, count, error } = await supabase
      .from("photos").select("taken_at", { count: "exact" })
      .eq("user_id", id).eq("is_sorted", false)
      .order("taken_at", { ascending: true }).limit(1);
    if (error || !count || !data?.length) continue;
    decks.set(id, { count, oldest: new Date((data[0] as { taken_at: string }).taken_at).getTime() });
  }

  const out: Recipient[] = [];
  for (const [userId, deck] of decks) {
    if (deck.oldest > cutoff) continue;                 // still actively shooting, leave alone
    const frames = deck.count === 1 ? "1 frame" : `${deck.count} frames`;
    out.push({
      userId,
      title: `${frames} waiting to sort`,
      // Says what sorting IS, because the count alone assumes they remember. Keep or post is the
      // whole decision, and naming it is what makes this different from a badge count.
      body: "They developed while you were out. Keep them, or post the ones worth sharing.",
      route: { t: "sortdeck" },
    });
  }
  return out;
}

/// Everyone with a registered device. Registering a token is the opt-in: there is no separate
/// preference column, so nobody else is reachable and nobody else should be considered.
async function reachableUsers(): Promise<string[]> {
  const { data } = await supabase.from("device_tokens").select("user_id");
  return [...new Set(((data ?? []) as { user_id: string }[]).map((r) => r.user_id))];
}

/// Drops anyone this campaign has already claimed, on every run including the dry one, so the dry
/// run's count is the number that would ACTUALLY be sent rather than the cohort size.
async function unclaimed(campaign: string, people: Recipient[]): Promise<Recipient[]> {
  const { data } = await supabase
    .from("one_shot_push").select("user_id").eq("campaign", campaign);
  const already = new Set(((data ?? []) as { user_id: string }[]).map((r) => r.user_id));
  return people.filter((p) => !already.has(p.userId));
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
  const resolve = CAMPAIGNS[name];

  if (!resolve) {
    return Response.json(
      { error: "unknown campaign", known: Object.keys(CAMPAIGNS) }, { status: 400 },
    );
  }

  // `?user=<uuid>` narrows any campaign to one person. For the owner's hand-aimed sends: the
  // campaign still defines the copy and the eligibility rule, the filter only stops everyone
  // else who qualifies from being swept up in a send meant for one account.
  const only = url.searchParams.get("user");
  const resolved = (await resolve()).filter((r) => !only || r.userId === only);
  const recipients = await unclaimed(name, resolved);
  if (!send) {
    return Response.json({
      dryRun: true, campaign: name, wouldSend: recipients.length,
      preview: recipients.map((r) => ({ userId: r.userId, title: r.title, body: r.body })),
      note: "Nothing was sent. Re-invoke with &send=true to actually send.",
    });
  }

  let sent = 0;
  let failed = 0;
  for (const person of recipients) {
    // Claim first. A duplicate key here means another run already has this person.
    const { error: claimErr } = await supabase
      .from("one_shot_push").insert({ campaign: name, user_id: person.userId });
    if (claimErr) continue;

    const { data: tokens } = await supabase
      .from("device_tokens").select("token").eq("user_id", person.userId);
    let delivered = false;
    for (const row of (tokens ?? []) as { token: string }[]) {
      const status = await push(row.token, person.title, person.body, person.route);
      if (status === 200) delivered = true;
      else console.warn(JSON.stringify({ at: "push_failed", userId: person.userId, status }));
    }
    if (delivered) {
      sent++;
      await supabase.from("one_shot_push")
        .update({ sent_at: new Date().toISOString() })
        .eq("campaign", name).eq("user_id", person.userId);
    } else {
      failed++;
    }
  }

  console.log(JSON.stringify({ at: "one_shot_push_done", campaign: name, sent, failed }));
  return Response.json({ dryRun: false, campaign: name, sent, failed });
});
