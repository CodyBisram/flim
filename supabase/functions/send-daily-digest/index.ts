// ============================================================
// FLIM send-daily-digest  (Supabase Edge Function, Deno)
//
// ONE notification per person per day summarising what the people they follow posted, instead of
// a push per post. At a hundred follows, per-post notifications are an uninstall, and worse, they
// train people to switch notifications off entirely, which costs the reveal alerts that are the
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
//   Hourly, but only between 14:00 and 01:00 UTC, roughly 10am to 9pm US Eastern. The other two
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

// PostgREST caps any select at 1000 rows. `photos` crossed that (1808 rows on 2026-09-02) and a
// row fetch silently dropped everything past the cap; see send-one-shot-push's `neverShot` for the
// incident. Every query in this file that has no filter narrowing it to "this run's backlog" (i.e.
// it reads the WHOLE table: `device_tokens`, `digest_state`, `blocks`, `covered_post_windows`) is
// exactly that shape, so all four page through `.range()` instead of a single unbounded select.
// Ordered by a stable, unique column so a page boundary can't skip or repeat a row if the table is
// written to mid-pagination.
const PAGE_SIZE = 1000;
/// `failed` is true only when a page errored, so a caller that must fail CLOSED on an unreadable
/// table (covered_post_windows below) can tell "we saw zero rows" apart from "we couldn't read the
/// table," the same distinction `windowsError` used to make before this paged. Callers that already
/// treated a query error as "no rows" (device_tokens, digest_state, blocks: none of them ever
/// checked `error` before this change) keep that behavior unchanged; `rows` is whatever was
/// collected before the failing page, same as `data ?? []` would have been for a one-shot select.
async function fetchAllPages<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
  label: string,
): Promise<{ rows: T[]; failed: boolean }> {
  const out: T[] = [];
  let from = 0;
  for (;;) {
    const { data, error } = await page(from, from + PAGE_SIZE - 1);
    if (error) {
      console.warn(JSON.stringify({ at: "fetch_all_pages_failed", label, from, error: error.message }));
      return { rows: out, failed: true };
    }
    if (!data || data.length === 0) break;
    out.push(...data);
    if (data.length < PAGE_SIZE) break;
    from += PAGE_SIZE;
  }
  return { rows: out, failed: false };
}

// Resolved from the same pinned identity is_owner()/the auto-follow trigger use
// (public.owner_user_id(), supabase/migrations/2026-09-01_pin_owner_identity_everywhere.sql), not
// by matching a client-writable email column. This function runs under the SERVICE ROLE, so it
// calls owner_user_id() by RPC rather than is_owner(uuid) (authenticated-only, and the wrong
// shape besides: it answers "is this them", not "who is it"). Mirrors the same call in
// send-social-push. Cached for the life of this invocation: the id never changes mid-run.
let ownerUserIdCache: string | null | undefined; // undefined = not fetched yet this invocation

async function ownerUserId(): Promise<string | null> {
  if (ownerUserIdCache !== undefined) return ownerUserIdCache;
  const { data, error } = await supabase.rpc("owner_user_id");
  if (error || !data) {
    console.warn(JSON.stringify({ at: "owner_user_id_rpc_failed", error: error?.message }));
    ownerUserIdCache = null;
    return null;
  }
  ownerUserIdCache = data as string;
  return ownerUserIdCache;
}

// ---- Covered posts --------------------------------------------------------
//
// This function runs with the SERVICE ROLE, so RLS is bypassed entirely and the
// "posts: readable by authenticated" policy's covered_post_visible(...) clause
// (supabase/migrations/2026-08-12_covered_posts.sql) never applies here. Without an explicit
// check, a covered post, hidden from everyone except its author, the other two named
// accounts, and the owner, would be summarised in a digest sent to any of their followers,
// which is exactly the leak this section exists to close.
//
// Mirrors public.post_is_covered / public.covered_post_visible byte-for-byte: a post is
// covered only when its author has an ACTIVE covered_post_windows row whose half-open
// [window_start, window_end) contains the post's own created_at, and a covered post is
// visible only to the owner or to another ACTIVE covered_post_windows member (symmetric among
// the three, regardless of whose post it is). Fetched ONCE per invocation, evaluated in
// TypeScript, per the same "small table, fetch once" shape send-daily-digest already uses for
// blocks, not a per-post RPC round trip.

interface CoveredWindow {
  start: number;
  end: number;
  active: boolean;
}

interface CoveredPostContext {
  /** False if either lookup below failed. Every check fails CLOSED when this is false: a
   *  digest that goes out with fewer items is recoverable, an announced hidden post is not. */
  loaded: boolean;
  windowByAuthor: Map<string, CoveredWindow>;
  /** Owner ids, union active covered_post_windows member ids: exactly who covered_post_visible
   *  allows to see ANY covered post. */
  allowedViewers: Set<string>;
}

async function loadCoveredPostContext(): Promise<CoveredPostContext> {
  const windowByAuthor = new Map<string, CoveredWindow>();
  const allowedViewers = new Set<string>();

  // No filter narrows this to "this run's backlog": it is the WHOLE table, so it pages through
  // fetchAllPages the same as device_tokens/digest_state/blocks below rather than risk PostgREST's
  // 1000-row cap silently dropping a covered author. The table is one row per user (PK on
  // user_id) and is meant to stay tiny (the owner's named-account feature), so this is unlikely to
  // ever page past once, but "unlikely" is exactly the reasoning that let the photos bug happen.
  const { rows: windowRows, failed: windowsFailed } = await fetchAllPages<
    { user_id: string; window_start: string; window_end: string; active: boolean }
  >(
    (from, to) =>
      supabase.from("covered_post_windows")
        .select("user_id, window_start, window_end, active")
        .order("user_id", { ascending: true })
        .range(from, to),
    "covered_post_windows",
  );
  if (windowsFailed) {
    return { loaded: false, windowByAuthor, allowedViewers };
  }
  for (const row of windowRows) {
    const userId = row.user_id as string;
    const active = Boolean(row.active);
    windowByAuthor.set(userId, {
      start: new Date(row.window_start as string).getTime(),
      end: new Date(row.window_end as string).getTime(),
      active,
    });
    if (active) allowedViewers.add(userId);
  }

  const ownerId = await ownerUserId();
  if (!ownerId) {
    console.warn(JSON.stringify({ at: "covered_post_owner_lookup_failed" }));
    return { loaded: false, windowByAuthor, allowedViewers };
  }
  allowedViewers.add(ownerId);

  return { loaded: true, windowByAuthor, allowedViewers };
}

/// TRUE when `viewerId` may be told about a post authored by `authorId` at `createdAtIso`.
/// Mirrors public.covered_post_visible(viewer, author, created_at) exactly: not covered at all
/// -> visible to everyone; covered -> visible only to the owner or another active
/// covered_post_windows member. Fails CLOSED: if `ctx.loaded` is false (the windows or owner
/// lookup above errored), every post is treated as NOT visible to anyone, rather than risk
/// silently treating an uncheckable post as "not covered."
function coveredPostVisibleTo(
  ctx: CoveredPostContext,
  viewerId: string,
  authorId: string,
  createdAtIso: string,
): boolean {
  if (!ctx.loaded) return false;
  const w = ctx.windowByAuthor.get(authorId);
  if (!w || !w.active) return true; // not covered at all
  const t = new Date(createdAtIso).getTime();
  const covered = t >= w.start && t < w.end;
  if (!covered) return true;
  return ctx.allowedViewers.has(viewerId);
}

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
/// recognise is what makes this worth opening, "5 new photos" could be from anyone.
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

// Prunes a device token APNs has told us is genuinely dead, so it stops being retried on
// every future run. ONLY on 410 Unregistered: 400 BadDeviceToken is left alone on purpose,
// because that status is also what a valid production TestFlight token gets back from the
// SANDBOX host (see the `host` field above), an environment mismatch, not a dead device.
// Deleting on 400 would wipe out perfectly good tokens for every user the first time the
// environment was misconfigured, which is a far worse failure than a stale row sitting
// around. 410's body carries Apple's own guard against a race with a fresh registration:
// `timestamp` (ms since epoch) is when Apple decided the token went bad, so the DELETE only
// removes the row if it was NOT touched again after that moment. A token re-registered
// between us sending and this response arriving has a newer `updated_at` and survives.
// Never throws: a failed prune is a logged warning, not a reason to abandon the rest of the
// digest run.
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
  if (!res.ok) await deleteDeadToken(deviceToken, res.status, reason);
  return res.ok;
}

// ---- Run ----------------------------------------------------------------

Deno.serve(async (req: Request) => {
  // `?dry=true` runs every read exactly as a real run would, but never calls APNs and never
  // writes digest_state, so the owner can see the windowing effect below before the next real
  // 10:00 run. Defaults to a real send: the pg_cron job that actually drives this in production
  // calls the function URL with no query string at all, and that path must keep sending.
  const isDry = new URL(req.url).searchParams.get("dry") === "true";

  const now = Date.now();
  const maxWindowStart = new Date(now - MAX_WINDOW_HOURS * 3600_000);

  // Fetched once per run, evaluated per (recipient, post) below. See the "Covered posts"
  // section above for the fail-closed contract.
  const coveredCtx = await loadCoveredPostContext();

  // Everyone with a registered device is a candidate; nobody else can be notified anyway. No
  // filter narrows this to "this run": it is the WHOLE table, one row per device across every
  // account, so it pages through fetchAllPages rather than risk PostgREST's 1000-row cap silently
  // dropping devices past it, the same shape the photos-select bug (see the header on
  // fetchAllPages above) already taught this codebase once.
  const { rows: tokenRows } = await fetchAllPages<{ user_id: string; token: string }>(
    (from, to) =>
      supabase.from("device_tokens").select("user_id, token").order("token", { ascending: true }).range(from, to),
    "device_tokens",
  );
  const tokensByUser = new Map<string, string[]>();
  for (const row of tokenRows) {
    const list = tokensByUser.get(row.user_id) ?? [];
    list.push(row.token);
    tokensByUser.set(row.user_id, list);
  }
  if (tokensByUser.size === 0) return new Response("no devices");

  // Same shape: one row per account that has EVER received a digest, so this grows with the whole
  // user base over time, not with anything scoped to this run.
  const { rows: stateRows } = await fetchAllPages<{ user_id: string; last_sent_at: string }>(
    (from, to) =>
      supabase.from("digest_state").select("user_id, last_sent_at").order("user_id", { ascending: true })
        .range(from, to),
    "digest_state",
  );
  const lastSent = new Map<string, number>(
    stateRows.map((r) => [r.user_id, new Date(r.last_sent_at).getTime()]),
  );

  // The owed half of the feed gate (docs/PENDING.md): the digest is server-computed and has no
  // visibility into device-local "seen" state, and must never gain any, that's a published
  // privacy stance, not a preference. `client_versions.updated_at` is the closest proxy that
  // already exists for "this account looked at the feed since then": report_client_version
  // fires once per MainTabView appearance (Flim/Views/Main/MainTabView.swift), and the table is
  // one row per user, PRIMARY KEY (user_id) (supabase/migrations/2026-08-21_client_versions.sql),
  // so there is no per-device fan-out to reduce over, one lookup per recipient is the whole
  // answer. Scoped to just this run's recipients (tokensByUser's keys), not the whole table, and
  // paged the same way as the other whole/large reads above in case that set ever exceeds
  // PostgREST's 1000-row cap.
  const recipientIds = [...tokensByUser.keys()];
  const { rows: clientVersionRows } = await fetchAllPages<{ user_id: string; updated_at: string }>(
    (from, to) =>
      supabase.from("client_versions").select("user_id, updated_at")
        .in("user_id", recipientIds)
        .order("user_id", { ascending: true })
        .range(from, to),
    "client_versions",
  );
  const lastLaunch = new Map<string, number>(
    clientVersionRows.map((r) => [r.user_id, new Date(r.updated_at).getTime()]),
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

  // Same shape again: every block system-wide, not scoped to this run's candidates, so it grows
  // with total blocks across the whole platform over time.
  const { rows: blockRows } = await fetchAllPages<{ blocker_id: string; blocked_id: string }>(
    (from, to) =>
      supabase.from("blocks").select("blocker_id, blocked_id")
        .order("blocker_id", { ascending: true }).order("blocked_id", { ascending: true })
        .range(from, to),
    "blocks",
  );
  const blockPairs = new Set<string>();
  for (const b of blockRows) {
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
    const lastSentAt = lastSent.get(userId) ?? 0;
    if (now - lastSentAt < DIGEST_INTERVAL_HOURS * 3600_000) continue;

    const baseSince = Math.max(lastSentAt, now - MAX_WINDOW_HOURS * 3600_000);
    // Clamp to this user's last known launch, so the 10:00 push counts only what arrived since
    // they last opened the feed, not since their last digest, those two can differ by hours. A
    // recipient with no client_versions row (never on a build that reports, or hasn't relaunched
    // since updating) falls back to `baseSince` unchanged, exactly the pre-clamp behavior.
    const launchAt = lastLaunch.get(userId);
    const since = launchAt !== undefined ? Math.max(baseSince, launchAt) : baseSince;

    considered++;

    const theirs = recentPosts.filter((p) => {
      const poster = p.user_id as string;
      if (poster === userId) return false;                       // your own posts aren't news
      if (!following.has(poster)) return false;
      if (blockPairs.has(`${userId}|${poster}`)) return false;
      // Covered posts (see "Covered posts" above) are excluded from anyone the SQL policy
      // would also hide them from. This is the same check RLS would apply on a normal client
      // read of `posts`; it's re-implemented here only because this function bypasses RLS via
      // the service role, exactly like the block check just above it.
      if (!coveredPostVisibleTo(coveredCtx, userId, poster, p.created_at as string)) return false;
      return new Date(p.created_at).getTime() > since;
    });

    if (isDry) {
      // Never sends, never touches digest_state: same reads, same filter, logged instead of
      // acted on, so the owner can see the clamp's effect before the next real 10:00 run.
      console.log(JSON.stringify({
        at: "digest_dry_run",
        userId,
        since: new Date(since).toISOString(),
        baseSince: new Date(baseSince).toISOString(),
        launchAt: launchAt !== undefined ? new Date(launchAt).toISOString() : null,
        count: theirs.length,
        outcome: theirs.length === 0 ? "suppressed" : "would_send",
      }));
      continue;
    }

    // Zero after the clamp is suppressed exactly like zero was before this change (no followee
    // posted in the window at all): digest_state is deliberately left untouched, the same
    // invariant this file already had. Advancing it here would buy nothing, `since` is
    // recomputed fresh every run from client_versions, so a post the user already saw stays
    // suppressed on every later run too, without needing digest_state to remember why. It would
    // also cost something: the DIGEST_INTERVAL_HOURS gate above reads lastSentAt from
    // digest_state, and bumping it on a suppressed run would push back the next chance to
    // reconsider this user even after they open the app to something genuinely new.
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

  const summary = isDry
    ? `digest dry run: ${considered} considered, see digest_dry_run logs for per-recipient outcome`
    : `digest: ${sent} sent, ${considered} considered`;
  console.log(JSON.stringify({ at: "digest_run", dry: isDry, sent, considered }));
  return new Response(summary);
});
