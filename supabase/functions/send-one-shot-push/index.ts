// ============================================================
// FLIM send-one-shot-push  (Supabase Edge Function, Deno)
//
// A single, manually invoked nudge to one cohort. NOT scheduled, and deliberately not wired to
// pg_cron: every other push here is reactive (something happened to you, you are told), and this
// one initiates contact for a product reason, so a human decides when it goes. Two campaigns have
// a scheduled caller the owner switches on and off in GitHub: founding-full
// (.github/workflows/founding-full.yml) and spotlight-weekly (.github/workflows/spotlight-weekly.yml,
// paused with the repo variable SPOTLIGHT_WEEKLY_PAUSED=true).
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
// A THIRD guard, because this deploys with --no-verify-jwt: every request must carry a shared
// secret header, `x-one-shot-secret`, matching the ONE_SHOT_PUSH_SECRET function secret. Without
// this, anyone holding the URL (it is not otherwise secret, but it should not need to be) could
// trigger a known campaign, dry run or for real. Checked FIRST, before anything else in the
// handler runs, and FAILS CLOSED: an unset ONE_SHOT_PUSH_SECRET refuses every request with 503
// rather than silently reopening the hole the first time this function is deployed before the
// secret exists.
//
// Deploy:
//   supabase functions deploy send-one-shot-push --no-verify-jwt
// Requires: supabase/migrations/2026-08-19_one_shot_push.sql
// Requires the ONE_SHOT_PUSH_SECRET function secret (see the guard above); set it with
//   supabase secrets set ONE_SHOT_PUSH_SECRET=<a long random value>
// then redeploy so the running function picks it up.
//
// Invoke (dry run):   curl -s -H "x-one-shot-secret: <secret>" "<fn url>?campaign=first-shot"
// Invoke (for real):  curl -s -H "x-one-shot-secret: <secret>" "<fn url>?campaign=first-shot&send=true"
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
// One APNs request may take this long before it is abandoned as a failed send (see
// send-social-push). A stalled connection must not hang a campaign halfway through its list.
const APNS_TIMEOUT_MS = 10_000;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// Read once, not through a helper called per-request, so a missing secret is decided the same way
// for the life of this instance rather than re-reading the environment on every hit.
const ONE_SHOT_PUSH_SECRET = Deno.env.get("ONE_SHOT_PUSH_SECRET");

/// Constant-time string comparison. Hashes both inputs to a fixed-length digest first (SHA-256,
/// 32 bytes always) so the comparison never has an early exit or a length check to time against;
/// a naive `a === b` or a byte loop that returns on the first mismatch leaks how many leading
/// characters were guessed correctly, and `x-one-shot-secret` is exactly the kind of static
/// bearer credential that leak matters for.
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

/// A person to contact, and the exact words for them. Copy is resolved PER RECIPIENT because
/// some of it is about their own state ("4 frames waiting"), and a campaign that rounded that to
/// a generic sentence would be the daily digest with extra steps.
type Recipient = { userId: string; title: string; body: string; route: unknown };

/// The campaigns this function knows how to send, by name. A campaign has to be listed here to be
/// sendable, so a typo in the query string cannot invent one and bypass the claim ledger.
const APP_NAME = "FLIM";

/// Every resolver is handed the request's one clock reading, so a campaign keyed by the week
/// (spotlight-weekly) resolves its cohort and its copy for the same week its claims are filed
/// under, even on a run that straddles Monday 04:00. Most ignore it.
type Resolver = (now: Date) => Promise<Recipient[]>;

const CAMPAIGNS: Record<string, Resolver> = {
  "first-shot": firstShotCohort,
  "still-no-shot": stillNoShotCohort,
  "checked-again": checkedAgainCohort,
  "islands": islandsCohort,
  "horror-nights": horrorNightsCohort,
  "epic-universe": epicUniverseCohort,
  "epic-red-shells": epicRedShellsCohort,
  "lys-check-in": lysCheckInCohort,
  "lys-check-in-2": lysCheckIn2Cohort,
  "epic-yoshi-line": epicYoshiLineCohort,
  "epic-lead-change": epicLeadChangeCohort,
  "epic-floor-shots": epicFloorShotsCohort,
  "epic-podium": epicPodiumCohort,
  "branb-epcot": branbEpcotCohort,
  "waiting-to-sort": waitingToSortCohort,
  "first-post": firstPostCohort,
  "first-photo": firstPhotoCohort,
  "invites-left": invitesLeftCohort,
  "invites-left-preview-a": invitesLeftPreviewA,
  "invites-left-preview-b": invitesLeftPreviewB,
  "update-1.6": update16Cohort,
  "update-1.6-preview": update16Preview,
  "founding-full": foundingFullCohort,
  "founding-full-preview": foundingFullPreview,
  "thank-you-preview": thankYouPreviewCohort,
  "thank-you": thankYouCohort,
  "thank-you-annie": thankYouAnnieCohort,
  "founding-seats-preview": foundingSeatsPreviewCohort,
  "founding-seats": foundingSeatsCohort,
  "founding-seats-inviters-preview": foundingSeatsInvitersPreviewCohort,
  "founding-seats-inviters": foundingSeatsInvitersCohort,
  "spotlight-weekend": spotlightWeekendCohort,
  "spotlight-weekend-update": spotlightWeekendUpdateCohort,
  "spotlight-weekly": spotlightWeeklyCohort,
  "spotlight-weekly-preview": spotlightWeeklyPreview,
};

/// The claim ledger's key for a campaign, when it is not the campaign's own name. A recurring
/// campaign claims under one key PER OCCURRENCE: `spotlight-weekly:2026-10-05` is that Spotlight
/// week's send, so a person hears from it at most once a week and a rerun inside the week claims
/// nothing, while next week's key starts empty. Anything not listed claims under its name, once
/// for good, as before.
const LEDGER_KEYS: Record<string, (now: Date) => string> = {
  "spotlight-weekly": (now) => `spotlight-weekly:${currentSpotlightWeekKey(now)}`,
  "spotlight-weekly-preview": (now) => `spotlight-weekly-preview:${currentSpotlightWeekKey(now)}`,
};

/// Founding 100 is running out (2026-09-25: 24 seats, about four a week). The badge is the one
/// scarcity FLIM has and nobody holding an invite has been told it ends. Sent to people who can
/// act on it: reachable, at least one invite left, and at least one post (the same bar
/// invites-left used, so the push reaches people who use the app, not everyone with a token).
/// The seat count is read at send time and said as a number; with none left the cohort is
/// empty and nothing sends. Lands on the invite sheet.
///
/// A failed count THROWS, never reads as zero (review OPEN #90, 2026-10-01): zero seats left is
/// what makes founding-full send, and the scheduled caller runs every half hour, so one
/// transient error used to send "The founding hundred is full" to every founder early and burn
/// the real send. A throw answers with a server error, the workflow's request fails, nothing is
/// sent, and the schedule tries again in half an hour.
async function foundingSeatsLeft(): Promise<number> {
  const { count, error } = await supabase
    .from("users").select("id", { count: "exact", head: true })
    .not("signup_ordinal", "is", null).neq("username", "applereview");
  if (error) throw new Error(`founding seat count failed: ${error.message}`);
  if (count === null) throw new Error("founding seat count came back empty");
  return Math.max(0, 100 - count);
}
function foundingSeatsTitle(left: number): string {
  return left === 1 ? "One seat left in the first hundred." : `${left} seats left in the first hundred.`;
}
const FOUNDING_SEATS_BODY =
  "Anyone you bring in while they last is one of the first hundred on FLIM, for good. Your invites are on your profile.";

async function foundingSeatsCohort(): Promise<Recipient[]> {
  const left = await foundingSeatsLeft();
  if (left === 0) return [];
  const out: Recipient[] = [];
  for (const id of await reachableUsers()) {
    const { data: u } = await supabase
      .from("users").select("username, invite_uses_remaining").eq("id", id).maybeSingle();
    const user = u as { username: string; invite_uses_remaining: number | null } | null;
    if (!user || user.username === "cody" || user.username === "applereview") continue;
    if (user.invite_uses_remaining === null || user.invite_uses_remaining <= 0) continue;
    const { count: posts, error } = await supabase
      .from("posts").select("id", { count: "exact", head: true }).eq("user_id", id);
    if (error || !posts) continue;
    out.push({ userId: id, title: foundingSeatsTitle(left), body: FOUNDING_SEATS_BODY, route: { t: "invite" } });
  }
  return out;
}

/// The people whose invite was redeemed in the last two weeks (2026-09-25, sent the same evening
/// as founding-seats, which pre-claimed these same people so nobody hears twice). It names the
/// friend who joined, says they took a founding seat, and gives the live count: the earn-back and
/// the scarcity in one push, to the people most likely to invite again. "Redeemed" is the moment
/// redeem_invite admitted the email (allowed_emails.added_at); the joined friend is named only
/// once an account exists for that email. The owner and the review account are excluded.
async function foundingSeatsInviterRows(): Promise<Recipient[]> {
  const left = await foundingSeatsLeft();
  const since = new Date(Date.now() - 14 * 24 * 3600 * 1000).toISOString();
  const { data: rows, error } = await supabase
    .from("allowed_emails").select("email, note, added_at")
    .like("note", "invited_by:%").gte("added_at", since);
  if (error || !rows) return [];
  const joinedBy = new Map<string, string[]>();
  for (const r of rows as { email: string; note: string }[]) {
    const inviter = /^invited_by:([0-9a-f-]{36})/.exec(r.note)?.[1];
    if (!inviter) continue;
    // Exact, case-insensitive: allowed_emails holds the lower-cased email, users.email may not be
    // (every SQL join here is lower(u.email) = ae.email). ILIKE with its wildcards escaped
    // (\ first, then % and _) narrows the read; the exact comparison below is what decides, so a
    // character PostgREST itself treats as a wildcard (*) can only widen the read, never match
    // the wrong person.
    const want = r.email.trim().toLowerCase();
    const pattern = want.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
    const { data: us } = await supabase
      .from("users").select("username, email").ilike("email", pattern).limit(10);
    const name = ((us ?? []) as { username: string; email: string | null }[])
      .find((x) => (x.email ?? "").trim().toLowerCase() === want)?.username;
    if (!name) continue;
    joinedBy.set(inviter, [...(joinedBy.get(inviter) ?? []), name]);
  }
  const reachable = new Set(await reachableUsers());
  const out: Recipient[] = [];
  for (const [inviterId, names] of joinedBy) {
    if (!reachable.has(inviterId)) continue;
    const { data: iu } = await supabase
      .from("users").select("username, invite_uses_remaining").eq("id", inviterId).maybeSingle();
    const inviter = iu as { username: string; invite_uses_remaining: number | null } | null;
    if (!inviter || inviter.username === "cody" || inviter.username === "applereview") continue;
    const title = names.length === 1
      ? `@${names[0]} joined with your invite.`
      : `@${names[0]} and ${names.length - 1 === 1 ? "one other" : `${names.length - 1} others`} joined with your invites.`;
    const they = names.length === 1 ? "They're" : "They're each";
    const seats = left === 1 ? "One seat is left" : `${left} seats are left`;
    const canInvite = inviter.invite_uses_remaining !== null && inviter.invite_uses_remaining > 0;
    const body = left > 0
      ? `${they} one of the first hundred on ${APP_NAME}. ${seats}${canInvite ? ", and your invites are on your profile." : "."}`
      : `${they} one of the first hundred on ${APP_NAME}.`;
    out.push({ userId: inviterId, title, body, route: { t: "invite" } });
  }
  return out;
}
async function foundingSeatsInvitersCohort(): Promise<Recipient[]> {
  return foundingSeatsInviterRows();
}
/// The owner alone, with the first real recipient's exact wording.
async function foundingSeatsInvitersPreviewCohort(): Promise<Recipient[]> {
  const sample = (await foundingSeatsInviterRows())[0];
  if (!sample) return [];
  return ownerOnly(sample.title, sample.body);
}

/// The owner alone, with the live count, to read on a lock screen before anyone else does.
async function foundingSeatsPreviewCohort(): Promise<Recipient[]> {
  return ownerOnly(foundingSeatsTitle(Math.max(1, await foundingSeatsLeft())), FOUNDING_SEATS_BODY);
}

/// One person, sent again at the owner's ask (2026-09-12). Its own campaign name, because the
/// claim ledger rightly refuses to send "thank-you" to the same account twice.
async function thankYouAnnieCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase.from("users").select("id").eq("username", "annie");
  return ((data ?? []) as { id: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({ userId: u.id, title: THANK_YOU_TITLE, body: THANK_YOU_BODY, route: { t: "profile", id: u.id } }));
}

const THANK_YOU_TITLE = "Thank you, from Cody";
const THANK_YOU_BODY =
  "For every roll, every reveal, and every time it broke and you came back anyway. FLIM is what it is because of you. " +
  "If you know one more person who belongs here, your code is on your profile.";

/// The owner alone, to see the thank-you on his own lock screen before it goes to everyone.
async function thankYouPreviewCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase.from("users").select("id").eq("username", "cody");
  return ((data ?? []) as { id: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({ userId: u.id, title: THANK_YOU_TITLE, body: THANK_YOU_BODY, route: { t: "profile", id: u.id } }));
}

/// Everyone reachable. Routes to the person's own profile, where the invite code lives.
async function thankYouCohort(): Promise<Recipient[]> {
  const ids = await reachableUsers();
  return ids.map((id) => ({ userId: id, title: THANK_YOU_TITLE, body: THANK_YOU_BODY, route: { t: "profile", id } }));
}

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

/// A named group rather than a rule: the owner's Islands of Adventure day, 2026-09-03. Copy
/// chosen by the owner. Usernames are resolved at run time so the list reads as people, and
/// anyone on it without a registered device simply does not appear in the dry run. Routes to the
/// Rolls tab, where making a roll lives; the camera would be the wrong doorstep.
const ISLANDS_GROUP = ["cody", "tristan", "lele", "sabs", "ricky", "branb", "trina"];

async function islandsCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", ISLANDS_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Islands of Adventure.",
      body: "Ready? Someone make the roll before we go, or the whole day ends up split across everyone's phones.",
      // Lands on the Rolls tab on builds that know the route (added 2026-09-03); older builds
      // treat an unknown destination as "just open the app", which is what this sent before.
      route: { t: "rolls" },
    }));
}

/// The owner's Horror Nights, 2026-09-05. "Jumbie" is the West Indian word for a spirit, the
/// owner's own register for the night. Same shape as `islandsCohort`: names resolved at run time,
/// anyone without a device drops out of the dry run. Routes to the Rolls tab.
const HORROR_NIGHTS_GROUP = ["sabs", "cody", "lele", "tristan", "ricky", "aly", "branb", "trina"];

async function horrorNightsCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", HORROR_NIGHTS_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Watch for jumbie.",
      body: "Horror Nights, tonight. The roll develops when you are all home safe.",
      route: { t: "rolls" },
    }));
}

/// Epic Universe, the day after Horror Nights, same eight. Mario Kart, because the group is
/// competitive about shot counts. Routes to the Rolls tab.
const EPIC_UNIVERSE_GROUP = ["sabs", "cody", "lele", "tristan", "ricky", "aly", "branb", "trina"];

async function epicUniverseCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Blue shell incoming.",
      body: "Someone is about to overtake your shot count. Whoever shoots the least is Baby Peach. Epic Universe.",
      route: { t: "rolls" },
    }));
}

/// The mid-day reminder at Epic Universe: the three lowest shot counts, named, to the whole
/// group. Same eight as `epicUniverseCohort`.
async function epicRedShellsCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Three red shells, locked on.",
      body: "Brandon, Aly, Trina. You are the bottom three. Start shooting.",
      route: { t: "rolls" },
    }));
}

/// One person: a member who shoots but had not posted in thirteen days, 2026-09-06. Resolved
/// by username so a rename cannot redirect it. Routes to the feed, where the post goes.
async function lysCheckInCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").eq("username", "alyssa");
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Lys, are you okay?",
      body: "Serious question. Thirteen days, no post. The feed is worried.",
      route: { t: "feed" },
    }));
}

/// Late afternoon at Epic Universe, from the Yoshi line: first and second place, one shot
/// apart. Same eight.
async function epicYoshiLineCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Tristan is in first. Ricky is one shot behind.",
      body: "Yoshi line is long enough to settle it. Shoot.",
      route: { t: "rolls" },
    }));
}

/// The lead changed hands in the Yoshi line. Same eight.
async function epicLeadChangeCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Yoooo. Ricky is in first now.",
      body: "53 to 48. Tristan got passed in the Yoshi line. Shoot.",
      route: { t: "rolls" },
    }));
}

/// The owner's own words from the park: the runner-up is padding his count. Same eight.
async function epicFloorShotsCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Tris is cheating.",
      body: "He is taking pictures of the floor. Somebody get him with a blue shell.",
      route: { t: "rolls" },
    }));
}

/// The follow-up, same afternoon: she opened the app twice after the first push (day-bucket
/// counters showed it), looked at the feed, and still did not post.
async function lysCheckIn2Cohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").eq("username", "alyssa");
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Lys. You opened the app.",
      body: "Twice. Ten minutes after we asked. Looked at the feed and left. Still no post. Why?",
      route: { t: "feed" },
    }));
}

/// The last one of the night, fifteen minutes before the Epic Universe roll developed. Same eight.
async function epicPodiumCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").in("username", EPIC_UNIVERSE_GROUP);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "Race over. Fifteen minutes to the podium.",
      body: "Ricky gold, Tristan silver, Sabs bronze. Trina, Baby Peach. 328 photos develop at 11:14.",
      route: { t: "rolls" },
    }));
}

/// One person, added by hand to a roll that had already developed (2026-09-09): the roll's own
/// develop push went out days before he was a member, so this is the one he never got. Opens
/// straight into that roll's reveal.
async function branbEpcotCohort(): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase
    .from("users").select("id, username").eq("username", "branb");
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({
      userId: u.id,
      title: "You are in Epcot 2026.",
      body: "The roll developed already. 221 frames are waiting for you.",
      route: { t: "reveal", id: "8056735a-ee74-4f86-ba63-ed60648e6226" },
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

/// The invite push (2026-09-15): everyone reachable who has shot and posted and still holds
/// invites. Two bodies, chosen per person by whether they have ever brought someone in
/// (allowed_emails.note carries the inviter), so nobody who has invited people is told they
/// never used one. Counts are substituted: invites left in the title, people brought in for
/// the second body. The owner (unlimited invites) is excluded. Route: own profile, where the
/// code lives. The never-shot (first-photo) and never-posted (first-post) groups are left out;
/// they were pushed the same afternoon.
function invitesLeftTitle(left: number): string {
  return left === 1 ? "You have 1 invite." : `You have ${left} invites.`;
}
const INVITES_LEFT_BODY_NEW =
  "Still unused. Your code is in your profile; anyone you send it to lands with you already followed.";
function invitesLeftBodyReturning(brought: number): string {
  const people = brought === 1 ? "1 person" : `${brought} people`;
  return `You've brought ${people} onto FLIM. Every one of them arrived following you, and the invite comes back when they shoot. Your code's in your profile.`;
}

async function invitesLeftCohort(): Promise<Recipient[]> {
  const reachable = await reachableUsers();
  const out: Recipient[] = [];
  for (const id of reachable) {
    const { data: u } = await supabase
      .from("users").select("id, username, invite_uses_remaining").eq("id", id).maybeSingle();
    const user = u as { id: string; username: string; invite_uses_remaining: number | null } | null;
    if (!user || user.username === "cody" || user.username === "applereview") continue;
    const left = user.invite_uses_remaining;
    if (left === null || left <= 0) continue;
    const { count: posts, error: e1 } = await supabase
      .from("posts").select("id", { count: "exact", head: true }).eq("user_id", id);
    if (e1 || !posts) continue;
    const { count: brought, error: e2 } = await supabase
      .from("allowed_emails").select("email", { count: "exact", head: true })
      .like("note", `invited_by:${id}%`);
    if (e2 || brought === null) continue;
    out.push({
      userId: id,
      title: invitesLeftTitle(left),
      body: brought > 0 ? invitesLeftBodyReturning(brought) : INVITES_LEFT_BODY_NEW,
      // Lands on the invite sheet on 1.5.4 and later; an older build treats an unknown route
      // as "open the app", so nobody gets a broken tap.
      route: { t: "invite" },
    });
  }
  return out;
}

// ------------------------------------------------------------
// update-1.6: FLIM v1.6 is on the App Store (2026-09-29). To everyone reachable whose app last
// reported a version below 1.6.0, or never reported one (builds older than the version census).
// The tap only opens the app: no build older than 1.6 can open the App Store from a push, and it
// does not need to, because `app_release_gate.latest_version` is 1.6.0 and the update prompt
// shows on that launch, with its own button to the App Store.

const UPDATE_16_TITLE = `${APP_NAME} v1.6 is out`;
const UPDATE_16_BODY =
  `Spotlight is here: put up one frame a week, and the team at ${APP_NAME} shows a few to everyone. Update to try it.`;

/// "1.5.3" < "1.6.0", compared numerically part by part; anything unparseable reads as old.
function versionBelow(version: string | null | undefined, target: string): boolean {
  if (!version) return true;
  const a = version.split(".").map((n) => parseInt(n, 10));
  const b = target.split(".").map((n) => parseInt(n, 10));
  if (a.some(Number.isNaN)) return true;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0, y = b[i] ?? 0;
    if (x !== y) return x < y;
  }
  return false;
}

async function update16Cohort(): Promise<Recipient[]> {
  const reachable = await reachableUsers();
  const { data: versions, error } = await supabase.from("client_versions").select("user_id, version");
  // A failed read must not read as "nobody has updated" and push everyone.
  if (error) throw new Error(`client_versions read failed: ${error.message}`);
  const versionOf = new Map(((versions ?? []) as { user_id: string; version: string }[])
    .map((r) => [r.user_id, r.version]));
  const { data: users, error: e2 } = await supabase.from("users").select("id, username").in("id", reachable);
  if (e2) throw new Error(`users read failed: ${e2.message}`);
  return ((users ?? []) as { id: string; username: string }[])
    .filter((u) => u.username !== "cody" && u.username !== "applereview")
    .filter((u) => versionBelow(versionOf.get(u.id), "1.6.0"))
    .map((u) => ({ userId: u.id, title: UPDATE_16_TITLE, body: UPDATE_16_BODY, route: { t: "feed" } }));
}

// ------------------------------------------------------------
// spotlight-weekend (2026-10-02, a Friday evening, the owner's copy): to everyone reachable on
// 1.6 or later who has not put a frame up for the current Spotlight week. The tap opens the
// camera, which is what "Take FLIM with you" asks for. spotlight-weekend-update: the same title
// to everyone reachable still below 1.6, where Spotlight does not exist; the tap opens the app,
// where the update prompt (`app_release_gate.latest_version`, 1.6.1) takes them to the App Store,
// the same path update-1.6 used.

const SPOTLIGHT_WEEKEND_TITLE = "Weekend plans?";
const SPOTLIGHT_WEEKEND_BODY = `Take ${APP_NAME} with you. One frame from tonight could go up for Spotlight.`;
const SPOTLIGHT_WEEKEND_UPDATE_BODY = `Update ${APP_NAME} to put a frame up for Spotlight.`;

/// The current Spotlight week's key, the same rule as `public.spotlight_week_key`: weeks start
/// Monday 04:00 America/New_York, keyed by that Monday's date ("2026-09-28").
function currentSpotlightWeekKey(now = new Date()): string {
  const shifted = new Date(now.getTime() - 4 * 3600 * 1000);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", weekday: "short",
  }).formatToParts(shifted);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const dow = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(get("weekday"));
  const monday = new Date(Date.UTC(+get("year"), +get("month") - 1, +get("day") - dow));
  return monday.toISOString().slice(0, 10);
}

async function versionsByUser(): Promise<Map<string, string>> {
  const { data, error } = await supabase.from("client_versions").select("user_id, version");
  // A failed read must not read as "nobody has updated" and push the wrong copy to everyone.
  if (error) throw new Error(`client_versions read failed: ${error.message}`);
  return new Map(((data ?? []) as { user_id: string; version: string }[]).map((r) => [r.user_id, r.version]));
}

async function reachableNamedUsers(): Promise<{ id: string; username: string }[]> {
  const reachable = await reachableUsers();
  const { data, error } = await supabase.from("users").select("id, username").in("id", reachable);
  if (error) throw new Error(`users read failed: ${error.message}`);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => u.username !== "cody" && u.username !== "applereview");
}

async function spotlightWeekendCohort(): Promise<Recipient[]> {
  const week = currentSpotlightWeekKey();
  const versionOf = await versionsByUser();
  const { data: entries, error } = await supabase
    .from("spotlight_entries").select("user_id").eq("week_key", week).is("removed_at", null);
  // A failed read must not read as "nobody has put one up" and nag the people who have.
  if (error) throw new Error(`spotlight_entries read failed: ${error.message}`);
  const entered = new Set(((entries ?? []) as { user_id: string }[]).map((e) => e.user_id));
  return (await reachableNamedUsers())
    .filter((u) => !versionBelow(versionOf.get(u.id), "1.6.0"))
    .filter((u) => !entered.has(u.id))
    .map((u) => ({ userId: u.id, title: SPOTLIGHT_WEEKEND_TITLE, body: SPOTLIGHT_WEEKEND_BODY,
                   route: { t: "camera" } }));
}

async function spotlightWeekendUpdateCohort(): Promise<Recipient[]> {
  const versionOf = await versionsByUser();
  return (await reachableNamedUsers())
    .filter((u) => versionBelow(versionOf.get(u.id), "1.6.0"))
    .map((u) => ({ userId: u.id, title: SPOTLIGHT_WEEKEND_TITLE, body: SPOTLIGHT_WEEKEND_UPDATE_BODY,
                   route: { t: "feed" } }));
}

// ------------------------------------------------------------
// spotlight-weekly (2026-10-06): spotlight-weekend, every weekend. The 2026-10-02 send beat every
// weekend before it (26 people shot on the Saturday against 15 to 18, 396 photos against 136 to
// 175), so .github/workflows/spotlight-weekly.yml sends it every Friday at 22:30 UTC. Same
// cohort as spotlight-weekend: reachable, on 1.6.0 or later, nothing put up for the current
// Spotlight week, the owner and the review account left out. The below-1.6 "update" variant is
// NOT repeated: those people had theirs on 2026-10-02. Claimed under `spotlight-weekly:<week>`
// (LEDGER_KEYS), so once per person per Spotlight week. The tap opens the camera.
//
// The copy rotates, one variant per Spotlight week in this order, counted from the week of
// 2026-10-05 (variant A), so two weeks in a row never read the same. A is the owner's approved
// spotlight-weekend copy. B, C and D are DRAFTS PENDING THE OWNER'S APPROVAL (2026-10-06): the
// first of them, B, goes out Friday 2026-10-16 unless it is approved, changed or removed first,
// or the workflow is paused. Reordering or removing a variant reshuffles every later week.

const SPOTLIGHT_WEEKLY_COPY: { title: string; body: string }[] = [
  // A. Approved; sent as spotlight-weekend on 2026-10-02.
  { title: SPOTLIGHT_WEEKEND_TITLE, body: SPOTLIGHT_WEEKEND_BODY },
  // B. Approved by the owner, 2026-10-06.
  { title: "Spotlight goes up Monday",
    body: "Shoot something this weekend and put your favorite frame up for it." },
  // C. Approved by the owner, 2026-10-06.
  { title: "Out tonight?",
    body: `Bring ${APP_NAME}. The best frame of your weekend could be in Monday's Spotlight.` },
  // D. Approved by the owner, 2026-10-06.
  { title: "One frame", body: "That's all Spotlight asks for this week. Make it a good one." },
];
const SPOTLIGHT_WEEKLY_FIRST_WEEK = "2026-10-05";
const WEEK_MS = 7 * 24 * 3600 * 1000;

/// This Spotlight week's variant: weeks since SPOTLIGHT_WEEKLY_FIRST_WEEK, modulo the number of
/// variants (a week before the first reads backwards round the list, never a negative index).
function spotlightWeeklyCopy(weekKey: string): { variant: string; title: string; body: string } {
  const weeks = Math.round(
    (Date.parse(`${weekKey}T00:00:00Z`) - Date.parse(`${SPOTLIGHT_WEEKLY_FIRST_WEEK}T00:00:00Z`)) / WEEK_MS,
  );
  const n = SPOTLIGHT_WEEKLY_COPY.length;
  const i = ((weeks % n) + n) % n;
  return { variant: String.fromCharCode(65 + i), ...SPOTLIGHT_WEEKLY_COPY[i] };
}

/// This week's copy and the next three, for the reply, so the rotation can be read before any of
/// it goes out.
function spotlightWeeklySchedule(now: Date): { week: string; variant: string; title: string; body: string }[] {
  const first = Date.parse(`${currentSpotlightWeekKey(now)}T00:00:00Z`);
  return [0, 1, 2, 3].map((k) => {
    const week = new Date(first + k * WEEK_MS).toISOString().slice(0, 10);
    return { week, ...spotlightWeeklyCopy(week) };
  });
}

async function spotlightWeeklyCohort(now: Date): Promise<Recipient[]> {
  const week = currentSpotlightWeekKey(now);
  const { title, body } = spotlightWeeklyCopy(week);
  const versionOf = await versionsByUser();
  const { data: entries, error } = await supabase
    .from("spotlight_entries").select("user_id").eq("week_key", week).is("removed_at", null);
  // A failed read must not read as "nobody has put one up" and nag the people who have.
  if (error) throw new Error(`spotlight_entries read failed: ${error.message}`);
  const entered = new Set(((entries ?? []) as { user_id: string }[]).map((e) => e.user_id));
  return (await reachableNamedUsers())
    .filter((u) => !versionBelow(versionOf.get(u.id), "1.6.0"))
    .filter((u) => !entered.has(u.id))
    .map((u) => ({ userId: u.id, title, body, route: { t: "camera" } }));
}

/// This week's spotlight-weekly push to the owner alone, the camera tap included. Claimed per
/// week (LEDGER_KEYS), so each week's copy can be previewed once; the dry run shows it without
/// sending anything.
async function spotlightWeeklyPreview(now: Date): Promise<Recipient[]> {
  const { title, body } = spotlightWeeklyCopy(currentSpotlightWeekKey(now));
  return (await ownerOnly(title, body)).map((r) => ({ ...r, route: { t: "camera" } }));
}

// ------------------------------------------------------------
// founding-full: the Founding 100 is full (written 2026-09-29, at 79 of 100). EMPTY until the
// last seat is taken: `foundingSeatsLeft()` must read 0, so the scheduled caller
// (.github/workflows/founding-full.yml) can invoke it with send=true every half hour and nothing
// goes out until the hundredth person joins. Then it goes once, per the claim ledger, to every
// reachable member of the first hundred (signup_ordinal 1 to 100), the owner and the review
// account excepted. The tap opens their own page.

// In the owner's own voice, his words (2026-09-29).
const FOUNDING_FULL_TITLE = "The founding hundred is full.";
const FOUNDING_FULL_BODY =
  "And you're one of them. You showed up before there was much to see and helped make this what it is. Thank you, from Cody.";

async function foundingFullCohort(): Promise<Recipient[]> {
  if (await foundingSeatsLeft() > 0) return [];
  const reachable = await reachableUsers();
  const { data, error } = await supabase
    .from("users").select("id, username, signup_ordinal")
    .in("id", reachable).not("signup_ordinal", "is", null).lte("signup_ordinal", 100);
  if (error) throw new Error(`users read failed: ${error.message}`);
  return ((data ?? []) as { id: string; username: string }[])
    .filter((u) => u.username !== "cody" && u.username !== "applereview")
    .map((u) => ({ userId: u.id, title: FOUNDING_FULL_TITLE, body: FOUNDING_FULL_BODY,
                   route: { t: "profile", id: u.id } }));
}

/// The same words to the owner alone, now, whatever the seat count.
async function foundingFullPreview(): Promise<Recipient[]> {
  return ownerOnly(FOUNDING_FULL_TITLE, FOUNDING_FULL_BODY);
}

/// The same push to the owner alone, to read on a lock screen before anyone else gets it.
async function update16Preview(): Promise<Recipient[]> {
  return (await ownerOnly(UPDATE_16_TITLE, UPDATE_16_BODY)).map((r) => ({ ...r, route: { t: "feed" } }));
}

/// The two bodies, to the owner alone, with sample counts, so both can be read on a lock
/// screen before anyone else sees either. Two names so both land (one claim per name).
async function ownerOnly(title: string, body: string): Promise<Recipient[]> {
  const reachable = new Set(await reachableUsers());
  const { data } = await supabase.from("users").select("id").eq("username", "cody");
  return ((data ?? []) as { id: string }[])
    .filter((u) => reachable.has(u.id))
    .map((u) => ({ userId: u.id, title, body, route: { t: "profile", id: u.id } }));
}
async function invitesLeftPreviewA(): Promise<Recipient[]> {
  return ownerOnly(invitesLeftTitle(3), INVITES_LEFT_BODY_NEW);
}
async function invitesLeftPreviewB(): Promise<Recipient[]> {
  return ownerOnly(invitesLeftTitle(3), invitesLeftBodyReturning(4));
}

/// The third touch for the never-shot cohort (2026-09-15), after "Take a shot." and "We
/// checked." went unanswered. Plain on purpose, at the owner's ask: no joke, no pressure, the
/// fact and where a first shot goes. Its own name so the ledger keeps the three touches apart.
async function firstPhotoCohort(): Promise<Recipient[]> {
  return (await neverShot()).map((userId) => ({
    userId,
    title: "Still no shots from you.",
    body: "No rush. Your first one goes to your Darkroom, and only you see it unless you post it.",
    route: { t: "camera" },
  }));
}

/// Everyone reachable who has taken at least one photo and never posted one (2026-09-15). The
/// audience is computed at send time, so it is one person today (owner's friend, shy) and
/// whoever shoots-but-never-posts later. Copy chosen by the owner from three rounds: the joke
/// is never on the person, the audience rule is said in plain words (posts are readable by
/// followers since 2026-09-13), and it is their call. Lands in the Darkroom, where the photos
/// are; the deck is for the unsorted, and these are mostly kept.
async function firstPostCohort(): Promise<Recipient[]> {
  const reachable = await reachableUsers();
  const out: Recipient[] = [];
  for (const id of reachable) {
    const { count: shots, error: e1 } = await supabase
      .from("photos").select("id", { count: "exact", head: true }).eq("user_id", id);
    if (e1 || !shots) continue;
    const { count: posts, error: e2 } = await supabase
      .from("posts").select("id", { count: "exact", head: true }).eq("user_id", id);
    // An error is not a zero: a failed count must never turn into "never posted".
    if (e2 || posts === null || posts > 0) continue;
    out.push({
      userId: id,
      title: "Post one.",
      body: "Just one. The rest can stay private. The people who follow you are the only ones who'll see it.",
      route: { t: "darkroom" },
    });
  }
  return out;
}

// PostgREST caps any select at 1000 rows, and a read past the cap drops the rest in silence (the
// `neverShot` incident above). The two whole-table reads below page through `.range()` on a stable
// order instead, and throw on an error: a failed read must never become a shorter cohort or an
// empty claim list.
const PAGE_SIZE = 1000;
async function fetchAllPages<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
  label: string,
): Promise<T[]> {
  const out: T[] = [];
  let from = 0;
  for (;;) {
    const { data, error } = await page(from, from + PAGE_SIZE - 1);
    if (error) throw new Error(`${label} read failed: ${error.message}`);
    if (!data || data.length === 0) break;
    out.push(...data);
    if (data.length < PAGE_SIZE) break;
    from += PAGE_SIZE;
  }
  return out;
}

/// Everyone with a registered device. Registering a token is the opt-in: there is no separate
/// preference column, so nobody else is reachable and nobody else should be considered.
async function reachableUsers(): Promise<string[]> {
  const rows = await fetchAllPages<{ user_id: string }>(
    (from, to) =>
      supabase.from("device_tokens").select("user_id").order("token", { ascending: true }).range(from, to),
    "device_tokens",
  );
  return [...new Set(rows.map((r) => r.user_id))];
}

/// Drops anyone this campaign has already claimed, on every run including the dry one, so the dry
/// run's count is the number that would ACTUALLY be sent rather than the cohort size.
async function unclaimed(campaign: string, people: Recipient[]): Promise<Recipient[]> {
  const rows = await fetchAllPages<{ user_id: string }>(
    (from, to) =>
      supabase.from("one_shot_push").select("user_id").eq("campaign", campaign)
        .order("user_id", { ascending: true }).range(from, to),
    "one_shot_push",
  );
  const already = new Set(rows.map((r) => r.user_id));
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

// Prunes a device token APNs has told us is genuinely dead, so it stops being retried on
// every future run. ONLY on 410 Unregistered: 400 BadDeviceToken is left alone on purpose,
// because that status is also what a valid production TestFlight token gets back from the
// SANDBOX host (see APNS_HOST above), an environment mismatch, not a dead device. Deleting
// on 400 would wipe out perfectly good tokens for every user the first time the environment
// was misconfigured, which is a far worse failure than a stale row sitting around. 410's
// body carries Apple's own guard against a race with a fresh registration: `timestamp` (ms
// since epoch) is when Apple decided the token went bad, so the DELETE only removes the row
// if it was NOT touched again after that moment. A token re-registered between us sending
// and this response arriving has a newer `updated_at` and survives.
// Never throws: a failed prune is a logged warning, not a reason to abandon the rest of the
// campaign send. Same as send-social-push's deleteDeadToken; a one-shot campaign should not
// leave a dead token behind for the next campaign to trip over either.
async function deleteDeadToken(deviceToken: string, status: number, body: string | undefined): Promise<void> {
  if (status !== 410) return;

  let invalidAtIso: string | null = null;
  try {
    const parsed = body ? JSON.parse(body) : null;
    if (parsed?.reason && parsed.reason !== "Unregistered") return; // not the case we handle
    if (typeof parsed?.timestamp === "number") invalidAtIso = new Date(parsed.timestamp).toISOString();
  } catch {
    // Malformed/missing body: still trust the 410 status itself, just skip the timestamp guard.
  }

  try {
    let query = supabase.from("device_tokens").delete().eq("token", deviceToken);
    if (invalidAtIso) query = query.lte("updated_at", invalidAtIso);
    const { data, error } = await query.select("user_id");
    if (error) {
      console.warn(JSON.stringify({ at: "device_token_prune_failed", token8: deviceToken.slice(0, 8), error: error.message }));
      return;
    }
    for (const row of (data ?? []) as { user_id: string }[]) {
      console.log(JSON.stringify({ at: "device_token_pruned", userId: row.user_id, token8: deviceToken.slice(0, 8), status }));
    }
  } catch (e) {
    console.warn(JSON.stringify({ at: "device_token_prune_failed", token8: deviceToken.slice(0, 8), error: String(e) }));
  }
}

// Returns the APNs status, or 0 when the request timed out or failed on the network: a failed
// send to this one device, never the end of the campaign.
async function push(token: string, title: string, body: string, route: unknown): Promise<number> {
  const jwt = await apnsAuthToken();
  let res: Response;
  let reason: string | undefined;
  try {
    res = await fetch(`${APNS_HOST}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "5",
      },
      body: JSON.stringify({ aps: { alert: { title, body }, sound: "flim_social.caf" }, flim: route }),
      signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
    });
    reason = res.ok ? undefined : await res.text();
  } catch (e) {
    console.warn(JSON.stringify({ at: "apns_send", ok: false, token8: token.slice(0, 8), error: String(e) }));
    return 0;
  }
  if (!res.ok) await deleteDeadToken(token, res.status, reason);
  return res.status;
}

// ------------------------------------------------------------

Deno.serve(async (req) => {
  // Checked before anything else, including which campaign was asked for: this function deploys
  // with --no-verify-jwt, so nothing upstream of this handler stops an anonymous request. FAILS
  // CLOSED: an unset secret refuses EVERY request, dry run included, rather than let a deploy that
  // lands before `supabase secrets set ONE_SHOT_PUSH_SECRET=...` has run reopen the hole.
  if (!ONE_SHOT_PUSH_SECRET) {
    return Response.json(
      { error: "ONE_SHOT_PUSH_SECRET is not set. Refusing every request until it is." },
      { status: 503 },
    );
  }
  const provided = req.headers.get("x-one-shot-secret") ?? "";
  if (!(await timingSafeEqual(provided, ONE_SHOT_PUSH_SECRET))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const url = new URL(req.url);
  const now = new Date();
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
  // The key every claim of this run is filed under: the campaign's name, or its occurrence's key
  // for a recurring campaign (LEDGER_KEYS). Read once, from the same clock the cohort reads.
  const ledger = LEDGER_KEYS[name]?.(now) ?? name;
  // Nothing has been claimed yet, so a failure here says exactly that: `claimed: 0` tells a
  // scheduled caller that nobody was burned and the next run can simply try again.
  let recipients: Recipient[];
  try {
    const resolved = (await resolve(now)).filter((r) => !only || r.userId === only);
    recipients = await unclaimed(ledger, resolved);
  } catch (e) {
    console.error(JSON.stringify({ at: "one_shot_push_cohort_failed", campaign: name, error: String(e) }));
    return Response.json({ error: `cohort failed: ${String(e)}`, campaign: name, ledger, claimed: 0 }, { status: 500 });
  }
  const schedule = name === "spotlight-weekly" || name === "spotlight-weekly-preview"
    ? { copy: spotlightWeeklySchedule(now) } : {};
  if (!send) {
    return Response.json({
      dryRun: true, campaign: name, ledger, wouldSend: recipients.length, ...schedule,
      preview: recipients.map((r) => ({ userId: r.userId, title: r.title, body: r.body })),
      note: "Nothing was sent. Re-invoke with &send=true to actually send.",
    });
  }

  // The APNs signing key, BEFORE the first claim: a key that cannot sign used to throw from the
  // first push, after that person was claimed, losing the reply, and every rerun then claimed and
  // lost one more person.
  if (recipients.length > 0) {
    try {
      await apnsAuthToken();
    } catch (e) {
      console.error(JSON.stringify({ at: "one_shot_push_apns_key_failed", campaign: name, error: String(e) }));
      return Response.json({ error: `APNs key failed: ${String(e)}`, campaign: name, ledger, claimed: 0 }, { status: 500 });
    }
  }

  let sent = 0;
  let failed = 0;
  let skipped = 0;
  for (const person of recipients) {
    // Claim first. A duplicate key here means another run already has this person.
    const { error: claimErr } = await supabase
      .from("one_shot_push").insert({ campaign: ledger, user_id: person.userId });
    if (claimErr) {
      skipped++;
      continue;
    }

    // Counted as failed, never as sent: the claim stays (a rerun skips this person, the ledger's
    // chosen direction) and sent_at stays empty, so the ledger shows it did not go. A throw is
    // this one person's failure too, never the end of the run with the reply lost.
    let delivered = false;
    try {
      const { data: tokens, error: tokensErr } = await supabase
        .from("device_tokens").select("token").eq("user_id", person.userId);
      if (tokensErr) console.warn(JSON.stringify({ at: "device_tokens_read_failed", userId: person.userId, error: tokensErr.message }));
      for (const row of (tokens ?? []) as { token: string }[]) {
        const status = await push(row.token, person.title, person.body, person.route);
        if (status === 200) delivered = true;
        else console.warn(JSON.stringify({ at: "push_failed", userId: person.userId, status }));
      }
    } catch (e) {
      console.warn(JSON.stringify({ at: "push_threw", userId: person.userId, error: String(e) }));
    }
    if (delivered) {
      sent++;
      await supabase.from("one_shot_push")
        .update({ sent_at: new Date().toISOString() })
        .eq("campaign", ledger).eq("user_id", person.userId);
    } else {
      failed++;
    }
  }

  // claimed is this run's new claims, each one either sent or failed. A scheduled caller alerts
  // on failed > 0: those people are claimed for good and were not reached. skipped is people
  // another run claimed first (or a claim insert that failed), neither contacted nor counted.
  console.log(JSON.stringify({ at: "one_shot_push_done", campaign: name, ledger, sent, failed, skipped }));
  return Response.json({ dryRun: false, campaign: name, ledger, claimed: sent + failed, sent, failed, skipped, ...schedule });
});
