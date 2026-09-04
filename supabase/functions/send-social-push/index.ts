// ============================================================
// FLIM send-social-push  (Supabase Edge Function, Deno)
//
// Scheduled (e.g. every minute) function that notifies a post's OWNER when
// someone else comments or reacts on their post, and a roll photo's OWNER when
// someone reacts to their roll shot (the reveal pull-back loop). Reactions are
// batched per person (one push listing that person's emoji), so a burst of
// reactions from one friend is a single notification, the way Lapse did it, not
// one-per-emoji.
//
// Also notifies everyone ELSE already in a post's comment thread when a new comment lands
// ("{name} also commented"), not just the post's owner: the owner's own push is suppressed by
// `notify()`'s self-check whenever the owner is the one replying, which used to mean nobody
// still in the conversation heard about it. Distinct copy from the owner's "{name} commented"
// so it never reads as "your photo got commented on."
//
// Also notifies people TAGGED in a post's photo when it gets reacted to, aggregated per
// POST rather than per reactor or per reacting person ("3 people reacted to a photo
// you're in"), so a popular post doesn't multiply the owner's per-reactor noise across
// everyone tagged in it. See the comment above that block for the dedup-with-owner and
// idempotency reasoning.
//
// Also notifies a comment's AUTHOR when someone likes it, batched per comment the same
// way reactions are batched per post ("3 people liked your comment"), never one push per
// like, and never for a self-like.
//
// Also notifies the APP OWNER whenever a content report lands (photo_reports /
// user_reports) so UGC can be actioned within 24h (App Store Guideline 1.2).
// Same poll + push_sent-flag pattern as everything else here; auto-hide at >=2
// distinct reporters is a separate DB trigger (auto_hide_reported in schema.sql).
//
// Deploy:
//   supabase functions deploy send-social-push --no-verify-jwt
// Schedule (Dashboard → Edge Functions → Schedules, or pg_cron): every 1 minute
//
// Uses the SAME APNs secrets as send-develop-push (APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_ENVIRONMENT). SUPABASE_URL /
// SUPABASE_SERVICE_ROLE_KEY are injected automatically.
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

// PostgREST caps any select at 1000 rows. `photos` crossed that (1808 rows on 2026-09-02) and a
// row fetch silently dropped everything past the cap; see send-one-shot-push's `neverShot` for the
// incident. The only query in this file with no filter narrowing it to "this run" is the
// covered_post_windows read below (loadCoveredPostContext), so it pages through `.range()` instead
// of one unbounded select. `failed` lets a caller that must fail CLOSED on an unreadable table
// (covered_post_windows) tell "we saw zero rows" apart from "we couldn't read the table."
const PAGE_SIZE = 1000;
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

// Names the DESTINATION the notification opens, not the event that caused it, so a future
// notification type that opens something already reachable needs no client change. `id` is
// omitted for destinations that need none (the daily digest, elsewhere). `comments` is set on
// "post" pushes that are specifically about a comment (opens the thread already showing), and
// now also on "reveal" pushes about a comment on a roll photo, for the same reason. `photo` is
// "reveal"-only: the specific roll-photo id a comment/mention/reaction landed on, so the client
// can open straight to that photo inside the roll instead of just the roll itself. Older app
// builds parse only `t` and `id`, ignore fields they don't recognize, and keep landing on the
// roll, so this is additive and backward compatible, not a breaking change.
interface FlimRoute {
  t: "reveal" | "post" | "profile" | "feed";
  id?: string;
  photo?: string;
  comments?: true;
}

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
// push run.
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

async function sendPush(
  deviceToken: string,
  title: string,
  body?: string,
  flim?: FlimRoute,
): Promise<boolean> {
  const jwt = await apnsAuthToken();
  // `body` is omitted from `alert` entirely when absent/empty, never sent as `body: ""`. APNs's
  // `alert` dictionary only requires `title`; a real title-only alert renders as a clean
  // single-line banner, while an explicit empty-string body risks a blank second line depending
  // on surface (lock screen, notification center, watchOS mirroring). Used by the "New follower"
  // push, the one push in this file with nothing left to say once the actor's name is in the
  // title.
  const alert: Record<string, string> = { title };
  if (body) alert.body = body;
  const payload: Record<string, unknown> = { aps: { alert, sound: "default" } };
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
  if (!res.ok) await deleteDeadToken(deviceToken, res.status, reason);
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

// --- Blocks. This function runs with the SERVICE ROLE, so RLS is bypassed entirely and
//     `is_blocked_either_way` never applies here. Every notification path has to ask explicitly.
//
//     Without this, blocking severed visibility but not contact: a blocked person could comment
//     on your post, mention you, tag you, or react, and you'd still get the push, even though RLS
//     correctly hid the content itself so tapping the notification showed you nothing. Blocking
//     has to mean the other person can't reach you, notifications included.
const blockCache = new Map<string, boolean>();

async function blockedEitherWay(a: string, b: string): Promise<boolean> {
  if (a === b) return false;
  const key = [a, b].sort().join("|");
  const cached = blockCache.get(key);
  if (cached !== undefined) return cached;
  const { data } = await supabase
    .from("blocks")
    .select("blocker_id")
    .or(`and(blocker_id.eq.${a},blocked_id.eq.${b}),and(blocker_id.eq.${b},blocked_id.eq.${a})`)
    .limit(1);
  const blocked = (data ?? []).length > 0;
  blockCache.set(key, blocked);
  return blocked;
}

/// Sends one notification from `fromId` to `toId`, unless either has blocked the other, or they
/// are the same person. The single door every user-to-user push goes through, so a new
/// notification type can't forget the check.
async function notify(
  toId: string | undefined,
  fromId: string,
  title: string,
  body?: string,
  flim?: FlimRoute,
): Promise<number> {
  if (!toId || toId === fromId) return 0;
  if (await blockedEitherWay(toId, fromId)) return 0;
  let sent = 0;
  for (const token of await tokensFor(toId)) {
    if (await sendPush(token, title, body, flim)) sent++;
  }
  return sent;
}

// --- App owner: resolved from the same pinned identity is_owner()/the auto-follow trigger use
//     (public.owner_user_id(), supabase/migrations/2026-09-01_pin_owner_identity_everywhere.sql),
//     not by matching a client-writable email column. This function runs under the SERVICE ROLE,
//     so it calls owner_user_id() by RPC rather than is_owner(uuid) (authenticated-only, and the
//     wrong shape besides: it answers "is this them", not "who is it"). Cached for the life of
//     this invocation: the id never changes mid-run. If the owner has no registered device, the
//     report still sits in the table for the daily-check query in the migration.
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

async function ownerTokens(): Promise<string[]> {
  const id = await ownerUserId();
  if (!id) return [];
  return [...new Set(await tokensFor(id))];
}

// --- Covered posts. This function runs with the SERVICE ROLE, so RLS is bypassed entirely
//     and the "posts: readable by authenticated" policy's covered_post_visible(...) clause
//     (supabase/migrations/2026-08-12_covered_posts.sql) never applies here, the same reason
//     `blockedEitherWay` above has to re-implement blocks by hand. Without an explicit check,
//     a covered post, hidden from everyone except its author, the other two named accounts,
//     and the owner, could still generate a push to someone outside that set (a tag on a new
//     covered post, or a mention inside a comment on one), telling them a post exists that
//     they can never open.
//
//     Mirrors public.post_is_covered / public.covered_post_visible byte-for-byte: a post is
//     covered only when its author has an ACTIVE covered_post_windows row whose half-open
//     [window_start, window_end) contains the post's own created_at, and a covered post is
//     visible only to the owner or to another ACTIVE covered_post_windows member (symmetric
//     among the three, regardless of whose post it is). Fetched ONCE per invocation and
//     evaluated in TypeScript, the same "small table, fetch once" shape blockCache uses, not a
//     per-post RPC round trip.
interface CoveredWindow {
  start: number;
  end: number;
  active: boolean;
}

interface CoveredPostContext {
  /** False if either lookup below failed. Every check fails CLOSED when this is false: a run
   *  that sends fewer pushes is recoverable, an announced hidden post is not. */
  loaded: boolean;
  windowByAuthor: Map<string, CoveredWindow>;
  /** Owner ids, union active covered_post_windows member ids: exactly who
   *  covered_post_visible allows to see ANY covered post. */
  allowedViewers: Set<string>;
}

async function loadCoveredPostContext(): Promise<CoveredPostContext> {
  const windowByAuthor = new Map<string, CoveredWindow>();
  const allowedViewers = new Set<string>();

  // No filter narrows this to "this run": it is the WHOLE table, so it pages through
  // fetchAllPages (see its header, above) rather than risk PostgREST's 1000-row cap silently
  // dropping a covered author. The table is one row per user (PK on user_id) and is meant to stay
  // tiny (the owner's named-account feature), so this is unlikely to ever page past once, but
  // "unlikely" is exactly the reasoning that let the photos bug happen.
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
/// lookup above errored), every post is treated as NOT visible to anyone.
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

// --- @mentions. Mirrors Flim/Models/Mentions.swift: an @ only starts a mention at a word
//     boundary (so an email address doesn't mention its domain), and a username is letters,
//     digits and underscore, matching AuthService.isValidUsername. Usernames are stored
//     lowercased, so the lookup is too.
function mentionedUsernames(text: string): string[] {
  const found = new Set<string>();
  for (const match of text.matchAll(/(^|\s)@([A-Za-z0-9_]+)/g)) {
    found.add(match[2].toLowerCase());
  }
  return [...found];
}

/// Resolves mentioned handles to user ids, dropping any that match nobody (a typo, or someone who
/// has since changed their username).
async function mentionedUserIds(text: string): Promise<string[]> {
  const names = mentionedUsernames(text);
  if (names.length === 0) return [];
  const { data } = await supabase.from("users").select("id").in("username", names);
  return (data ?? []).map((u) => u.id as string);
}

// ============================================================
// Reaction emoji safety.
//
// The reaction picker (EmojiCatalog.swift) generates its palette at runtime from Unicode scalar
// properties, filtered only by what the SENDER's OWN device can draw. That means a reaction typed
// on a newer iPhone can be a codepoint the RECIPIENT's older iPhone has no glyph for. Inside the
// app, an unrenderable reaction falls back to a neutral placeholder chip (ReactionGlyph.swift,
// ReactionRenderabilityCache) because the app controls that draw call. A push notification's
// banner is drawn by iOS's own notification UI, where there is no such control, so an unknown
// emoji there becomes a tofu box on someone's lock screen, the most visible possible way to look
// broken.
//
// The floor is FLIM's deployment target, iOS 18.0 (project.yml), which ships Unicode Emoji 15.1.
// Any emoji ASSIGNED at or before Emoji 15.1 is guaranteed safe to draw on every FLIM user's
// phone; anything assigned later (Emoji 16.0, shipped in iOS 18.4; Emoji 17.0, shipped in iOS 26)
// is not, because a recipient still on iOS 18.0-18.3 has no glyph for it yet. This intentionally
// tracks Unicode's OWN version metadata rather than a hand-picked "common emoji" list: emoji-data.txt
// (https://unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt, the current cumulative revision, so
// every codepoint's introduction version is authoritative back to Emoji 0.6) tags every assigned
// codepoint with the exact Emoji version it first appeared in.
//
// SAFE_SCALAR_RANGES below is every codepoint tagged "Emoji" in that file with version < 16.0,
// restricted to the same scan window EmojiCatalog.swift's own picker walks (0x2000-0x2BFF,
// 0x1F000-0x1FAFF), with the component-only sub-ranges removed (skin-tone modifiers 0x1F3FB-
// 0x1F3FF, bare regional-indicator letters 0x1F1E6-0x1F1FF; flags are handled separately below),
// mirroring isStandalonePictograph's exclusions in EmojiCatalog.swift exactly. Within that window,
// Emoji 16.0 added exactly 7 new single-scalar pictographs and Emoji 17.0 added 7 more, all 14
// deliberately absent from these ranges: harp U+1FA89, shovel U+1FA8F, leafless tree U+1FABE,
// fingerprint U+1FAC6, root vegetable U+1FADC, splatter U+1FADF, face with bags under eyes
// U+1FAE9 (all E16.0); landslide U+1F6D8, trombone U+1FA8A, treasure chest U+1FA8E, hairy
// creature U+1FAC8, orca U+1FACD, distorted face U+1FAEA, fight cloud U+1FAEF (all E17.0). To
// regenerate this table if the safety floor ever moves, re-run that same filter (property ==
// "Emoji", version < target) against a current emoji-data.txt.
//
// Country/region flags and ZWJ sequences aren't single scalars, so they're checked separately,
// below, against the same "assigned by Emoji 15.1" bar.
const SAFE_SCALAR_RANGES: readonly (readonly [number, number])[] = [
  [0x203C, 0x203C], [0x2049, 0x2049], [0x2122, 0x2122], [0x2139, 0x2139], [0x2194, 0x2199], [0x21A9, 0x21AA],
  [0x231A, 0x231B], [0x2328, 0x2328], [0x23CF, 0x23CF], [0x23E9, 0x23F3], [0x23F8, 0x23FA], [0x24C2, 0x24C2],
  [0x25AA, 0x25AB], [0x25B6, 0x25B6], [0x25C0, 0x25C0], [0x25FB, 0x25FE], [0x2600, 0x2604], [0x260E, 0x260E],
  [0x2611, 0x2611], [0x2614, 0x2615], [0x2618, 0x2618], [0x261D, 0x261D], [0x2620, 0x2620], [0x2622, 0x2623],
  [0x2626, 0x2626], [0x262A, 0x262A], [0x262E, 0x262F], [0x2638, 0x263A], [0x2640, 0x2640], [0x2642, 0x2642],
  [0x2648, 0x2653], [0x265F, 0x2660], [0x2663, 0x2663], [0x2665, 0x2666], [0x2668, 0x2668], [0x267B, 0x267B],
  [0x267E, 0x267F], [0x2692, 0x2697], [0x2699, 0x2699], [0x269B, 0x269C], [0x26A0, 0x26A1], [0x26A7, 0x26A7],
  [0x26AA, 0x26AB], [0x26B0, 0x26B1], [0x26BD, 0x26BE], [0x26C4, 0x26C5], [0x26C8, 0x26C8], [0x26CE, 0x26CF],
  [0x26D1, 0x26D1], [0x26D3, 0x26D4], [0x26E9, 0x26EA], [0x26F0, 0x26F5], [0x26F7, 0x26FA], [0x26FD, 0x26FD],
  [0x2702, 0x2702], [0x2705, 0x2705], [0x2708, 0x270D], [0x270F, 0x270F], [0x2712, 0x2712], [0x2714, 0x2714],
  [0x2716, 0x2716], [0x271D, 0x271D], [0x2721, 0x2721], [0x2728, 0x2728], [0x2733, 0x2734], [0x2744, 0x2744],
  [0x2747, 0x2747], [0x274C, 0x274C], [0x274E, 0x274E], [0x2753, 0x2755], [0x2757, 0x2757], [0x2763, 0x2764],
  [0x2795, 0x2797], [0x27A1, 0x27A1], [0x27B0, 0x27B0], [0x27BF, 0x27BF], [0x2934, 0x2935], [0x2B05, 0x2B07],
  [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55], [0x1F004, 0x1F004], [0x1F0CF, 0x1F0CF], [0x1F170, 0x1F171],
  [0x1F17E, 0x1F17F], [0x1F18E, 0x1F18E], [0x1F191, 0x1F19A], [0x1F201, 0x1F202], [0x1F21A, 0x1F21A], [0x1F22F, 0x1F22F],
  [0x1F232, 0x1F23A], [0x1F250, 0x1F251], [0x1F300, 0x1F321], [0x1F324, 0x1F393], [0x1F396, 0x1F397], [0x1F399, 0x1F39B],
  [0x1F39E, 0x1F3F0], [0x1F3F3, 0x1F3F5], [0x1F3F7, 0x1F3FA], [0x1F400, 0x1F4FD], [0x1F4FF, 0x1F53D], [0x1F549, 0x1F54E],
  [0x1F550, 0x1F567], [0x1F56F, 0x1F570], [0x1F573, 0x1F57A], [0x1F587, 0x1F587], [0x1F58A, 0x1F58D], [0x1F590, 0x1F590],
  [0x1F595, 0x1F596], [0x1F5A4, 0x1F5A5], [0x1F5A8, 0x1F5A8], [0x1F5B1, 0x1F5B2], [0x1F5BC, 0x1F5BC], [0x1F5C2, 0x1F5C4],
  [0x1F5D1, 0x1F5D3], [0x1F5DC, 0x1F5DE], [0x1F5E1, 0x1F5E1], [0x1F5E3, 0x1F5E3], [0x1F5E8, 0x1F5E8], [0x1F5EF, 0x1F5EF],
  [0x1F5F3, 0x1F5F3], [0x1F5FA, 0x1F64F], [0x1F680, 0x1F6C5], [0x1F6CB, 0x1F6D2], [0x1F6D5, 0x1F6D7], [0x1F6DC, 0x1F6E5],
  [0x1F6E9, 0x1F6E9], [0x1F6EB, 0x1F6EC], [0x1F6F0, 0x1F6F0], [0x1F6F3, 0x1F6FC], [0x1F7E0, 0x1F7EB], [0x1F7F0, 0x1F7F0],
  [0x1F90C, 0x1F93A], [0x1F93C, 0x1F945], [0x1F947, 0x1F9FF], [0x1FA70, 0x1FA7C], [0x1FA80, 0x1FA88], [0x1FA90, 0x1FABD],
  [0x1FABF, 0x1FAC5], [0x1FACE, 0x1FADB], [0x1FAE0, 0x1FAE8], [0x1FAF0, 0x1FAF8],
];

// Two-letter regional-indicator codes for every RGI_Emoji_Flag_Sequence Unicode's own
// emoji-sequences.txt (https://unicode.org/Public/emoji/16.0/emoji-sequences.txt) tags with a
// version before E16.0. Emoji 16.0's only addition to this list within the whole revision was the
// flag for Sark ("CQ"), deliberately absent here for the same reason the 14 scalars above are:
// iOS 18.0-18.3 has no glyph for it. Country flags outnumber every other emoji category (258
// entries), which is why they're their own table rather than folded into SAFE_SCALAR_RANGES: a
// flag is TWO regional-indicator letters, never a single scalar, and "is this pair an officially
// recognized flag" isn't answerable from a codepoint range the way a single pictograph is (most
// of the 676 possible two-letter combinations aren't a flag at all).
const SAFE_FLAG_CODES = new Set<string>([
  "AC", "AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR", "AS", "AT",
  "AU", "AW", "AX", "AZ", "BA", "BB", "BD", "BE", "BF", "BG", "BH", "BI", "BJ",
  "BL", "BM", "BN", "BO", "BQ", "BR", "BS", "BT", "BV", "BW", "BY", "BZ", "CA",
  "CC", "CD", "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN", "CO", "CP", "CR",
  "CU", "CV", "CW", "CX", "CY", "CZ", "DE", "DG", "DJ", "DK", "DM", "DO", "DZ",
  "EA", "EC", "EE", "EG", "EH", "ER", "ES", "ET", "EU", "FI", "FJ", "FK", "FM",
  "FO", "FR", "GA", "GB", "GD", "GE", "GF", "GG", "GH", "GI", "GL", "GM", "GN",
  "GP", "GQ", "GR", "GS", "GT", "GU", "GW", "GY", "HK", "HM", "HN", "HR", "HT",
  "HU", "IC", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR", "IS", "IT", "JE",
  "JM", "JO", "JP", "KE", "KG", "KH", "KI", "KM", "KN", "KP", "KR", "KW", "KY",
  "KZ", "LA", "LB", "LC", "LI", "LK", "LR", "LS", "LT", "LU", "LV", "LY", "MA",
  "MC", "MD", "ME", "MF", "MG", "MH", "MK", "ML", "MM", "MN", "MO", "MP", "MQ",
  "MR", "MS", "MT", "MU", "MV", "MW", "MX", "MY", "MZ", "NA", "NC", "NE", "NF",
  "NG", "NI", "NL", "NO", "NP", "NR", "NU", "NZ", "OM", "PA", "PE", "PF", "PG",
  "PH", "PK", "PL", "PM", "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO",
  "RS", "RU", "RW", "SA", "SB", "SC", "SD", "SE", "SG", "SH", "SI", "SJ", "SK",
  "SL", "SM", "SN", "SO", "SR", "SS", "ST", "SV", "SX", "SY", "SZ", "TA", "TC",
  "TD", "TF", "TG", "TH", "TJ", "TK", "TL", "TM", "TN", "TO", "TR", "TT", "TV",
  "TW", "TZ", "UA", "UG", "UM", "UN", "US", "UY", "UZ", "VA", "VC", "VE", "VG",
  "VI", "VN", "VU", "WF", "WS", "XK", "YE", "YT", "ZA", "ZM", "ZW",
]);

// The complete, closed set of ZWJ sequences and Unicode-tag subdivision flags FLIM's OWN reaction
// picker can ever produce (EmojiCatalog.swift's `zwjTemplates` + `subdivisionFlags`, copied here
// verbatim; keep the two lists in sync if that file's set ever changes). Unlike single scalars and
// flags, Unicode exposes no scalar-level property that says "these components combine into a real
// sequence", so there is no way to derive this list from a version filter the way the two tables
// above are derived; it has to be the same finite, curated list the client itself is limited to.
// Every entry here was individually checked against Unicode's emoji-zwj-sequences.txt
// (https://unicode.org/Public/emoji/16.0/emoji-zwj-sequences.txt): the newest is E15.1 (the
// phoenix and the brown mushroom), so this list needs no further
// version filtering, it already IS the filtered result. Emoji 16.0 added zero new RGI ZWJ
// sequences, and Emoji 17.0 has not published an RGI ZWJ list yet, so nothing here is at risk of
// having quietly become unsafe; if EmojiCatalog.swift's zwjTemplates ever grows, re-check each
// new entry's version the same way before adding it here.
const SAFE_MULTI_SCALAR_SEQUENCES = new Set<string>([
  // People and Body: gender-neutral professions/roles (all E12.0-E12.1).
  "\u{1F9D1}\u{200D}\u{1F4BB}", "\u{1F9D1}\u{200D}\u{1F3A8}", "\u{1F9D1}\u{200D}\u{1F373}",
  "\u{1F9D1}\u{200D}\u{1F33E}", "\u{1F9D1}\u{200D}\u{1F680}", "\u{1F9D1}\u{200D}\u{1F692}",
  "\u{1F9D1}\u{200D}\u{2695}\u{FE0F}", "\u{1F9D1}\u{200D}\u{1F3EB}", "\u{1F9D1}\u{200D}\u{2696}\u{FE0F}",
  "\u{1F9D1}\u{200D}\u{2708}\u{FE0F}", "\u{1F9D1}\u{200D}\u{1F527}", "\u{1F9D1}\u{200D}\u{1F52C}",
  "\u{1F9D1}\u{200D}\u{1F3A4}", "\u{1F9D1}\u{200D}\u{1F393}", "\u{1F9D1}\u{200D}\u{1F3ED}",
  "\u{1F9D1}\u{200D}\u{1F4BC}",
  "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}", "\u{1F9D1}\u{200D}\u{1F9AF}", "\u{1F9D1}\u{200D}\u{1F9BD}",
  "\u{1F9D1}\u{200D}\u{1F9BC}", "\u{1F441}\u{FE0F}\u{200D}\u{1F5E8}\u{FE0F}",
  // Smileys and Emotion: faces that only exist as ZWJ sequences (E13.1).
  "\u{1F635}\u{200D}\u{1F4AB}", "\u{1F62E}\u{200D}\u{1F4A8}", "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}",
  // Flags: not representable as a single scalar or a regional-indicator pair.
  "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "\u{1F3F4}\u{200D}\u{2620}\u{FE0F}", "\u{1F3F3}\u{FE0F}\u{200D}\u{26A7}\u{FE0F}",
  // Animals and Nature: concepts that only exist as ZWJ sequences.
  "\u{1F408}\u{200D}\u{2B1B}", "\u{1F415}\u{200D}\u{1F9BA}", "\u{1F43B}\u{200D}\u{2744}\u{FE0F}",
  "\u{1F426}\u{200D}\u{2B1B}", "\u{1F426}\u{200D}\u{1F525}",
  // Food and Drink: same story, this specific concept only exists as a ZWJ sequence (E15.1).
  "\u{1F344}\u{200D}\u{1F7EB}",
  // Subdivision flags (Unicode TAG-character sequences, England/Scotland/Wales; all E5.0).
  "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
  "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
  "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}",
]);

/// True only when `emoji` is guaranteed to render on every FLIM user's phone: iOS 18.0 (the app's
/// deployment floor) already ships Emoji 15.1, so anything assigned at or before that revision is
/// safe for everyone, and anything assigned after it, or not recognized at all, is not. FAILS
/// CLOSED: an emoji this function has never seen a version for (a brand-new one, a malformed
/// string, a skin-tone/gender ZWJ variant FLIM's own picker doesn't offer) returns false, not a
/// guess. Structural cases, matching exactly what a FLIM client can ever produce
/// (EmojiCatalog.swift): a single safe scalar with an optional trailing variation selector
/// (U+FE0F), one of the closed set of ZWJ/tag sequences in SAFE_MULTI_SCALAR_SEQUENCES, or a
/// two-letter regional-indicator flag pair in SAFE_FLAG_CODES.
function isSafeReactionEmoji(emoji: string): boolean {
  if (SAFE_MULTI_SCALAR_SEQUENCES.has(emoji)) return true;

  const codePoints = Array.from(emoji).map((c) => c.codePointAt(0)!);

  // Country/region flag: exactly two regional-indicator letters (U+1F1E6..U+1F1FF each).
  if (codePoints.length === 2 && codePoints.every((cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF)) {
    const code = codePoints.map((cp) => String.fromCharCode(0x41 + (cp - 0x1F1E6))).join("");
    return SAFE_FLAG_CODES.has(code);
  }

  const isSafeScalar = (cp: number) => SAFE_SCALAR_RANGES.some(([lo, hi]) => cp >= lo && cp <= hi);

  // A single safe scalar, alone or with the emoji variation selector appended.
  if (codePoints.length === 1) return isSafeScalar(codePoints[0]);
  if (codePoints.length === 2 && codePoints[1] === 0xFE0F) return isSafeScalar(codePoints[0]);

  // A safe scalar carrying a skin-tone modifier. The modifiers themselves (U+1F3FB..U+1F3FF) are
  // Emoji 2.0, from 2015, so they render everywhere this app can run; only the base emoji decides
  // safety. Without this, ✌🏽 and 💪🏽 fell back to a bare "to your photo" while the identical
  // reaction without a modifier got its emoji. Measured against production, skin-tone variants are
  // about 1% of reactions, so the cost was small, but it fell on people making a deliberate choice
  // about how they are represented, which is the wrong place to be silently lossy.
  if (codePoints.length === 2 && codePoints[1] >= 0x1F3FB && codePoints[1] <= 0x1F3FF) {
    return isSafeScalar(codePoints[0]);
  }
  if (codePoints.length === 3 && codePoints[1] === 0xFE0F
      && codePoints[2] >= 0x1F3FB && codePoints[2] <= 0x1F3FF) {
    return isSafeScalar(codePoints[0]);
  }

  return false;
}

/// Builds the reaction body: `"❤️ to your photo"` when the emoji is known-safe for every FLIM
/// user (see isSafeReactionEmoji above), otherwise exactly today's wording, `"to your photo"`,
/// verbatim, never a guess. Shared by both reaction push sites (post reactions, roll-photo
/// reactions) so the fallback text can't drift between them. Placement is the BODY, not the
/// title: every other push in this file keeps its title to exactly "{name} + verb" ({name}
/// commented, {name} tagged you, {name} mentioned you, {name} liked your comment) and puts the
/// event-specific detail in the body; putting the emoji in the title would make this the one push
/// whose title carries extra content, and it reads worse split across two lines ("{name} reacted
/// ❤️" / "to your photo") than kept together in one ("{name} reacted" / "❤️ to your photo").
function reactionBody(emoji: string): string {
  return isSafeReactionEmoji(emoji) ? `${emoji} to your photo` : "to your photo";
}

Deno.serve(async () => {
  let sent = 0;

  // Fetched once per run, evaluated per (recipient, post) below wherever a recipient isn't
  // guaranteed to be the post's own author. See the "Covered posts" section above for the
  // fail-closed contract.
  const coveredCtx = await loadCoveredPostContext();

  // ---- Comments: one push per comment, to the post owner (never self), to anyone @mentioned,
  //      and to everyone ELSE who already has a comment on this same post ("thread
  //      participants"). Before this block existed, only the post's OWNER was ever told about a
  //      new comment; someone who commented earlier and got a reply had no way to find out short
  //      of reopening the post. Confirmed in production: ricky posted, tristan commented, ricky
  //      replied, tristan got nothing, because `notify()` correctly self-suppresses the owner
  //      push when the owner IS the commenter. Thread participants close that gap with their own
  //      distinct copy, "{name} also commented", never the owner's "{name} commented": an
  //      identical-looking push would read as "your photo got a comment" to someone whose photo
  //      it isn't.
  // `hidden` is pulled through the join, same as the tagged-photo-reactions block further down,
  // so a comment (or an @mention inside one) on a post that's been auto-hidden (auto_hide_reported
  // at >=2 distinct reporters, or set_photo_hidden) never announces it. "posts: readable by
  // authenticated" requires NOT hidden with NO owner exception (unlike photos, which has one for
  // exactly this reason), so a hidden post cannot be opened by ANYONE right now, including its own
  // author: the owner's own comment notification is suppressed too, deliberately, not just
  // everyone else's, because tapping it would land them on the same "post not found" as any other
  // recipient. If that RLS exception is ever added for posts, this guard should be revisited.
  // The new thread-participant push sits INSIDE this same hidden-post skip, not beside it: it is
  // reached only when the post is not hidden, the same as the owner and mention pushes above it.
  const { data: comments } = await supabase
    .from("post_comments")
    .select("id, post_id, user_id, body, posts(user_id, hidden, created_at)")
    .eq("push_sent", false);

  for (const c of comments ?? []) {
    const postMeta = (c as { posts?: { user_id?: string; hidden?: boolean; created_at?: string } }).posts;
    if (postMeta?.hidden) {
      // Mark done without notifying anyone, mirroring the tagged-photo-reactions guard below:
      // an unmarked skip would be re-evaluated by every future poll forever.
      await supabase.from("post_comments").update({ push_sent: true }).eq("id", c.id);
      continue;
    }
    const ownerId = postMeta?.user_id;
    const name = await handle(c.user_id);
    const preview = c.body.length > 90 ? c.body.slice(0, 87) + "…" : c.body;
    // Tracks who has already been pushed for this comment, so someone who is the post owner,
    // @mentioned in it, and/or an earlier thread participant, all at once, gets exactly one
    // notification, the strongest one that applies (owner > mention > thread), rather than one
    // per role.
    // All three of this comment's pushes (owner, mention, thread) land on the SAME comment, on
    // the SAME post, so they share one route. Built fresh per comment row (from this row's own
    // post_id), never hoisted, so nothing from a previous row's iteration can leak in.
    const route: FlimRoute = { t: "post", id: c.post_id, comments: true };
    const notified = new Set<string>([c.user_id]);
    // The owner push never needs a covered-post check: ownerId IS the post's author, so if the
    // post is covered, its own author is trivially allowed to be told about activity on it.
    if (ownerId) {
      notified.add(ownerId);
      sent += await notify(ownerId, c.user_id, `${name} commented`, preview, route);
    }
    // Capped: one comment can name any number of people, and without a limit a single comment
    // could fan out into dozens of pushes. Five is generous for a real conversation and useless
    // as a megaphone.
    let mentionPushes = 0;
    for (const uid of await mentionedUserIds(c.body)) {
      if (notified.has(uid) || mentionPushes >= 5) continue;
      // A mention, unlike the owner push above, can name ANYONE, including someone outside the
      // covered-post allowed set, this is the exact leak the "Covered posts" section exists to
      // close: telling a stranger they were mentioned in a post they can never open.
      if (ownerId && postMeta?.created_at && !coveredPostVisibleTo(coveredCtx, uid, ownerId, postMeta.created_at)) {
        continue;
      }
      notified.add(uid);
      mentionPushes++;
      sent += await notify(uid, c.user_id, `${name} mentioned you`, preview, route);
    }
    // Thread participants: everyone who already has a comment on this same post, other than
    // this comment's own author, and other than anyone already notified above as the owner or a
    // mention (`notified` covers both). Read fresh per comment row rather than reused across
    // rows, so a post with several unsent comments in the same poll always reflects the current
    // set of commenters. Same title shape as every other push in this file (actor + verb), with
    // "also" doing the work of distinguishing this from the owner's "{name} commented": without
    // it, a thread participant would see an identical-looking push and reasonably think it was
    // their own photo that got commented on.
    const { data: threadRows } = await supabase
      .from("post_comments")
      .select("user_id")
      .eq("post_id", c.post_id)
      .neq("user_id", c.user_id);
    const threadParticipants = new Set<string>((threadRows ?? []).map((r) => r.user_id as string));
    for (const uid of threadParticipants) {
      if (notified.has(uid)) continue;
      // Same covered-post leak as the mention loop above: a thread participant can be anyone who
      // once commented, including someone outside the covered-post allowed set if the post's
      // covered window opened after their comment landed.
      if (ownerId && postMeta?.created_at && !coveredPostVisibleTo(coveredCtx, uid, ownerId, postMeta.created_at)) {
        continue;
      }
      notified.add(uid);
      sent += await notify(uid, c.user_id, `${name} also commented`, preview, route);
    }
    await supabase.from("post_comments").update({ push_sent: true }).eq("id", c.id);
  }

  // ---- New posts: notify people tagged in the photo + @mentioned in the caption ----
  // `hidden` is selected directly (this query already reads straight from `posts`, no join
  // needed) so a post that was auto-hidden within the ~60s before this poll never announces a
  // tag. Same reasoning and same "skip everyone, including the owner, but still mark sent" shape
  // as the comments block above; see its comment for why the owner is not exempted.
  const { data: newPosts } = await supabase
    .from("posts")
    .select("id, user_id, caption, created_at, hidden")
    .eq("push_sent", false);

  for (const p of newPosts ?? []) {
    if (p.hidden) {
      await supabase.from("posts").update({ push_sent: true }).eq("id", p.id);
      continue;
    }
    const name = await handle(p.user_id);
    // Notify each person tagged in the photo (never the poster).
    //
    // Also marks every one of THESE tag rows push_sent = true below (not just the post), because
    // post_tags now carries its own push_sent column for the "tag added after publishing" block
    // further down, which polls post_tags directly wherever push_sent = false. Without marking
    // them here, that block would see these same at-creation tags as still unsent the moment this
    // post's own push_sent flips true, and fire a second, duplicate "tagged you" push for each.
    const { data: tagRows } = await supabase.from("post_tags").select("id, tagged_user_id").eq("post_id", p.id);
    const notified = new Set<string>([p.user_id]);
    for (const t of tagRows ?? []) {
      const uid = t.tagged_user_id as string;
      if (notified.has(uid)) continue;
      // The post itself may be covered (this IS the confirmed leak: a brand-new covered post,
      // tagging someone outside the allowed set, was notified regardless). `p.user_id` is the
      // post's own author, so this asks exactly what covered_post_visible would ask RLS.
      if (!coveredPostVisibleTo(coveredCtx, uid, p.user_id, p.created_at as string)) continue;
      notified.add(uid);
      sent += await notify(uid, p.user_id, `${name} tagged you`, "in a photo", { t: "post", id: p.id });
    }
    if (tagRows && tagRows.length > 0) {
      await supabase.from("post_tags").update({ push_sent: true }).in("id", tagRows.map((t) => t.id));
    }
    await supabase.from("posts").update({ push_sent: true }).eq("id", p.id);
  }

  // ---- Tags added AFTER publishing: notify someone tagged via "Edit tags"
  //      (FeedService.setTags, Flim/Services/FeedService.swift) on a post whose OWN push_sent is
  //      already true. The "New posts" block above only scans posts where push_sent = false, and
  //      marks every tag that exists on the post AT THAT MOMENT as push_sent = true (the update
  //      just above), so a tag added LATER, once the post has already been announced, would
  //      otherwise never be picked up by anything: the post never becomes push_sent = false again,
  //      and the new post_tags row sits at its own default of push_sent = false forever, telling
  //      no one, while the app UI still reports the tag as saved. This block is that missing path:
  //      it polls post_tags directly, independent of the post's own push_sent, so it is the only
  //      block that can see this kind of row.
  //
  //      Requires post_tags.push_sent (supabase/migrations/2026-08-17_post_tags_push_sent.sql,
  //      mirrored into schema.sql), added the same shape comment_likes got in
  //      2026-08-12_comment_likes_push_sent.sql: a one-time backfill marks every EXISTING tag row
  //      push_sent = TRUE at migration time (not filtered by any date cutoff, for the same reason
  //      that migration gives; a manual, possibly-delayed deploy makes a fixed cutoff wrong), so
  //      the very first poll after this column exists does not fire a "tagged you" push for every
  //      tag ever created. Unlike comment_likes, post_tags already carries a real, non-composite
  //      `id` primary key, so no surrogate id column is needed here, only push_sent itself.
  //
  //      Same guards as the tags-on-a-new-post block above: the hidden-post check ("posts:
  //      readable by authenticated" has no owner exception, so a hidden post can't be opened by
  //      anyone right now, its own author included, see the comments-block note near the top of
  //      this function) and the covered-post visibility check. Adds an explicit self-tag guard
  //      (only the post's owner can INSERT a post_tags row, so a self-tag means the owner tagged
  //      themselves in their own photo); `notify()`'s own toId===fromId check would already no-op
  //      this case, since fromId here is always the post's owner, but checking first avoids an
  //      unnecessary `handle()` lookup and says the intent plainly. `notify()` remains the one door
  //      that enforces blocks in both directions, same as every other push in this file.
  //
  //      Marked done the same single `.in("id", ids)` shape every other id-keyed table here uses:
  //      every fetched row is marked push_sent = true, whether it produced a push or was skipped
  //      (hidden post, self-tag, covered-post visibility, or a block), so nothing here is ever
  //      re-evaluated by a future poll.
  const { data: laterTags } = await supabase
    .from("post_tags")
    .select("id, post_id, tagged_user_id, posts(user_id, hidden, created_at)")
    .eq("push_sent", false);

  for (const t of laterTags ?? []) {
    const postMeta = (t as { posts?: { user_id?: string; hidden?: boolean; created_at?: string } }).posts;
    const ownerId = postMeta?.user_id;
    const taggedId = t.tagged_user_id as string;
    if (!ownerId || !postMeta?.created_at) continue; // fail-closed: no post metadata, no push
    if (postMeta.hidden) continue; // hidden post, nobody (including its author) can open it right now
    if (taggedId === ownerId) continue; // self-tag: the owner tagged themselves in their own photo
    if (!coveredPostVisibleTo(coveredCtx, taggedId, ownerId, postMeta.created_at)) continue;

    const name = await handle(ownerId);
    sent += await notify(taggedId, ownerId, `${name} tagged you`, "in a photo", { t: "post", id: t.post_id });
  }
  if (laterTags && laterTags.length > 0) {
    await supabase.from("post_tags").update({ push_sent: true }).in("id", laterTags.map((t) => t.id));
  }

  // ---- Reactions: batch per (post, reactor) → one push listing their emoji, to the OWNER ----
  // `hidden` is pulled through the join so the tagged-people block below (which reads from this
  // same `reactions` array) can skip a hidden post/photo without a second query. `created_at` is
  // pulled through the same join so that same block can evaluate covered-post visibility for
  // tagged people without a second query either.
  const { data: reactions } = await supabase
    .from("post_reactions")
    .select("id, post_id, user_id, emoji, posts(user_id, hidden, created_at)")
    .eq("push_sent", false);

  const groups = new Map<
    string,
    { postId: string; ownerId?: string; reactorId: string; emojis: string[]; ids: string[] }
  >();
  for (const r of reactions ?? []) {
    const key = `${r.post_id}|${r.user_id}`;
    const g = groups.get(key) ?? {
      postId: r.post_id,
      ownerId: (r as { posts?: { user_id?: string } }).posts?.user_id,
      reactorId: r.user_id,
      emojis: [] as string[],
      ids: [] as string[],
    };
    g.emojis.push(r.emoji);
    g.ids.push(r.id);
    groups.set(key, g);
  }

  for (const g of groups.values()) {
    if (g.ownerId && g.ownerId !== g.reactorId) {
      const name = await handle(g.reactorId);
      // The emoji shown is the LAST one in this batch (`g.emojis` is appended in fetch order), so
      // a reactor who left several before this run picked up sees the most recent one, not an
      // arbitrary first. `reactionBody` decides whether it's safe to show at all; see the
      // "Reaction emoji safety" section above for the full derivation and the fail-closed
      // fallback to exactly today's "to your photo".
      sent += await notify(
        g.ownerId,
        g.reactorId,
        `${name} reacted`,
        reactionBody(g.emojis[g.emojis.length - 1]),
        { t: "post", id: g.postId },
      );
    }
    await supabase.from("post_reactions").update({ push_sent: true }).in("id", g.ids);
  }

  // ---- Reactions (continued): notify people TAGGED in the photo, once per post per run, never
  //      once per reactor. Copying the owner batching above verbatim would multiply that noise
  //      across everyone tagged (eight reactors -> eight pushes to EACH tagged person, not just
  //      the owner), so this aggregates every reactor across the WHOLE post into a single push
  //      per (post, tagged person): "<name> reacted" / "to a photo you're in" for one reactor,
  //      "<n> people reacted" / "to a photo you're in" for more than one.
  //
  //      Idempotency: this reads the SAME `reactions` rows fetched above (push_sent = false), and
  //      those exact row ids are marked push_sent = true in the owner loop just above, before any
  //      notify() call below runs. There's no separate flag for this feature to fall out of sync
  //      with: one query, one set of reaction ids, one place they get marked done. A second run
  //      only ever sees reactions that arrived after this one, so a reaction can't produce a
  //      second "reacted to a photo you're in" push any more than it can produce a second owner
  //      push.
  //
  //      Dedup with the owner path: if the post's owner is also tagged in it, skip them here
  //      unconditionally (`taggedId === p.ownerId`), the same way the comment path above always
  //      adds ownerId to its `notified` set regardless of whether that push actually sent. The
  //      owner already has their own reaction push (or is excluded from it by `notify()`'s
  //      self-check); this block is for everyone ELSE tagged in the photo.
  const postAgg = new Map<
    string,
    { ownerId?: string; hidden: boolean; createdAt?: string; reactorIds: Set<string> }
  >();
  for (const r of reactions ?? []) {
    const meta = (r as { posts?: { user_id?: string; hidden?: boolean; created_at?: string } }).posts;
    const p = postAgg.get(r.post_id) ??
      { ownerId: meta?.user_id, hidden: meta?.hidden ?? false, createdAt: meta?.created_at, reactorIds: new Set<string>() };
    p.reactorIds.add(r.user_id);
    postAgg.set(r.post_id, p);
  }

  const reactedPostIds = [...postAgg.keys()];
  const tagsByPost = new Map<string, string[]>();
  if (reactedPostIds.length > 0) {
    const { data: tagRows } = await supabase
      .from("post_tags")
      .select("post_id, tagged_user_id")
      .in("post_id", reactedPostIds);
    for (const t of tagRows ?? []) {
      const arr = tagsByPost.get(t.post_id) ?? [];
      arr.push(t.tagged_user_id as string);
      tagsByPost.set(t.post_id, arr);
    }
  }

  for (const [postId, p] of postAgg) {
    if (p.hidden) continue; // hidden post, or its photo (which hides the post via the same trigger)
    const tagged = tagsByPost.get(postId);
    if (!tagged || tagged.length === 0) continue;

    // Capped at 20 pushes per post: a photo can be tagged with any number of people, and without
    // a limit a single popular post could fan out unbounded. Matches the reasoning behind the
    // 5-mention cap on comments above, sized up because tags are set by the post's owner (not
    // free text), so a large real group photo is the worst case, not an attacker.
    let pushesForPost = 0;
    for (const taggedId of tagged) {
      if (pushesForPost >= 20) break;
      if (taggedId === p.ownerId) continue;
      // Same leak this whole section closes, on the reaction path: a tagged person outside the
      // covered-post allowed set must not be told a covered post got reacted to.
      if (p.ownerId && p.createdAt && !coveredPostVisibleTo(coveredCtx, taggedId, p.ownerId, p.createdAt)) {
        continue;
      }
      // Never notify someone about their own reaction: count only reactions from OTHER people.
      const others = [...p.reactorIds].filter((id) => id !== taggedId);
      if (others.length === 0) continue;

      const title = others.length === 1
        ? `${await handle(others[0])} reacted`
        : `${others.length} people reacted`;
      pushesForPost++;
      // No emoji here on purpose, unlike the owner push above: `postAgg` only tracks WHO reacted
      // (`reactorIds`), not what with, and even if it did, a >1-reactor push has no single emoji
      // to attribute without picking one and calling it representative, exactly the guess
      // "Reaction emoji safety" above exists to avoid. Making the 1-reactor case show an emoji
      // while the 2+ case never can would also read as inconsistent rather than deliberate.
      // `others[0]` stands in for the block check, the same simplification the roll-photo-comments
      // thread notification below uses when several people are folded into one push.
      sent += await notify(taggedId, others[0], title, "to a photo you're in", { t: "post", id: postId });
    }
  }

  // ---- Roll photo comments: notify the OWNER + that photo's THREAD (people who already
  //      commented on the same photo), never the whole roll. Skip anyone who muted the roll.
  const { data: photoComments } = await supabase
    .from("photo_comments")
    .select("id, photo_id, user_id, body, photos(user_id, roll_id)")
    .eq("push_sent", false);

  const byPhoto = new Map<string, {
    ownerId?: string; rollId?: string; items: { id: string; userId: string; body: string }[];
  }>();
  for (const pc of photoComments ?? []) {
    const meta = (pc as { photos?: { user_id?: string; roll_id?: string } }).photos;
    const g = byPhoto.get(pc.photo_id) ?? { ownerId: meta?.user_id, rollId: meta?.roll_id, items: [] };
    g.items.push({ id: pc.id, userId: pc.user_id, body: pc.body });
    byPhoto.set(pc.photo_id, g);
  }

  for (const [photoId, g] of byPhoto) {
    // The thread = everyone who has ever commented on this photo, plus the owner.
    const { data: allC } = await supabase.from("photo_comments").select("user_id").eq("photo_id", photoId);
    const thread = new Set<string>((allC ?? []).map((c) => c.user_id));
    if (g.ownerId) thread.add(g.ownerId);

    // People who muted this roll get nothing.
    let muted = new Set<string>();
    if (g.rollId) {
      const { data: m } = await supabase.from("roll_notification_mutes").select("user_id").eq("roll_id", g.rollId);
      muted = new Set((m ?? []).map((x) => x.user_id));
    }

    // People @mentioned in these comments who aren't already in the thread. Mentions used to be
    // scanned on post_comments only, so an @ on a ROLL photo highlighted and linked in the app
    // and notified nobody. A mention is an explicit summons; it should reach someone whether or
    // not they've commented on that photo before.
    const mentioned = new Set<string>();
    for (const it of g.items) {
      for (const uid of await mentionedUserIds(it.body)) mentioned.add(uid);
    }
    for (const uid of mentioned) {
      if (!muted.has(uid)) thread.add(uid);
    }

    for (const recipient of thread) {
      if (muted.has(recipient)) continue;
      const fromOthers = g.items.filter((it) => it.userId !== recipient);  // never notify about your own
      if (fromOthers.length === 0) continue;

      let title: string, body: string;
      if (fromOthers.length === 1) {
        title = `${await handle(fromOthers[0].userId)} commented`;
        const b = fromOthers[0].body;
        body = b.length > 90 ? b.slice(0, 87) + "…" : b;
      } else {
        title = `${fromOthers.length} new comments`;
        body = "on a roll photo";
      }
      // Routes into the roll AND straight to this photo inside it, `comments: true` so the
      // client opens with the photo's comment thread already showing, matching the "post" +
      // comments treatment above. Built fresh per photo group from that group's own rollId and
      // photoId, so it can't drift onto another photo's roll. Omitted entirely when a photo
      // somehow has no roll_id, leaving the client's safe "no routing data" fallback instead of
      // a guess; `photo` is only ever set alongside a present `id`, never on its own.
      const route: FlimRoute | undefined = g.rollId
        ? { t: "reveal", id: g.rollId, photo: photoId, comments: true }
        : undefined;
      // `fromOthers[0].userId` is the sole/most recent commenter; blocks are checked against
      // them, so a blocked person can't reach you through a roll photo either.
      sent += await notify(recipient, fromOthers[0].userId, title, body, route);
    }

    await supabase.from("photo_comments").update({ push_sent: true }).in("id", g.items.map((it) => it.id));
  }

  // ---- Roll photo reactions: notify the photo's OWNER (never self), batched per reactor.
  //      This is the reveal's pull-back loop: a reaction left during the reveal pings whoever
  //      shot it, so even someone who revealed early (and saw it thin) gets drawn back once the
  //      group responds. Skip anyone who muted the roll. Same batch shape as post reactions,
  //      plus the roll-mute check from the photo-comments block above.
  const { data: photoReactions } = await supabase
    .from("photo_reactions")
    .select("id, photo_id, user_id, emoji, photos(user_id, roll_id)")
    .eq("push_sent", false);

  const rxByKey = new Map<string, {
    ownerId?: string; rollId?: string; photoId: string; reactorId: string; emojis: string[]; ids: string[];
  }>();
  for (const r of photoReactions ?? []) {
    const meta = (r as { photos?: { user_id?: string; roll_id?: string } }).photos;
    const key = `${r.photo_id}|${r.user_id}`;
    const g = rxByKey.get(key) ??
      { ownerId: meta?.user_id, rollId: meta?.roll_id, photoId: r.photo_id, reactorId: r.user_id,
        emojis: [] as string[], ids: [] as string[] };
    g.emojis.push(r.emoji);
    g.ids.push(r.id);
    rxByKey.set(key, g);
  }

  // Cache roll mutes per roll so a burst of reactions across one roll doesn't re-query it.
  const mutesByRoll = new Map<string, Set<string>>();
  async function mutedInRoll(rollId?: string): Promise<Set<string>> {
    if (!rollId) return new Set();
    const cached = mutesByRoll.get(rollId);
    if (cached) return cached;
    const { data: m } = await supabase.from("roll_notification_mutes").select("user_id").eq("roll_id", rollId);
    const set = new Set<string>((m ?? []).map((x) => x.user_id));
    mutesByRoll.set(rollId, set);
    return set;
  }

  for (const g of rxByKey.values()) {
    if (g.ownerId && g.ownerId !== g.reactorId && !(await mutedInRoll(g.rollId)).has(g.ownerId)) {
      const name = await handle(g.reactorId);
      // Same emoji treatment as the post-reactions push above: `reactionBody` shows the LAST
      // emoji in this batch only when it's safe for every FLIM user (see "Reaction emoji safety"
      // above), otherwise falls back to exactly today's "to your photo". Route omission (no
      // `flim` payload when a photo somehow has no roll_id) is the same "omit rather than guess"
      // treatment as the roll-photo-comments route above, unrelated to the emoji decision. `photo`
      // is included so a reaction opens straight to the reacted-on photo inside the roll, same as
      // the comments route, but WITHOUT `comments: true`: a reaction has no thread to show.
      sent += await notify(
        g.ownerId,
        g.reactorId,
        `${name} reacted`,
        reactionBody(g.emojis[g.emojis.length - 1]),
        g.rollId ? { t: "reveal", id: g.rollId, photo: g.photoId } : undefined,
      );
    }
    await supabase.from("photo_reactions").update({ push_sent: true }).in("id", g.ids);
  }

  // ---- Comment likes: batch every NEW like on a comment into ONE push to the comment's
  //      AUTHOR, "<name> liked your comment" for a single liker, "<n> people liked your
  //      comment" for more, the same shape as the tagged-photo-reactions block above
  //      (post_reactions) that folds every reactor on a post into one push per recipient,
  //      rather than one push per like. A popular comment must not fire a push per like.
  //
  //      Self-likes are dropped while the group is built, before any notify() call, so a
  //      comment's own author liking their own comment can never itself put anyone in the
  //      group; notify()'s own self-check is a second, redundant guard on top of that.
  //      `notify()` still re-checks blocks in both directions before anything is sent, same
  //      door every user-to-user push here goes through.
  //
  //      comment_likes has no id in its original schema (composite PK
  //      (comment_id, user_id)); a surrogate `id` was added alongside `push_sent` in
  //      2026-08-12_comment_likes_push_sent.sql specifically so a whole group can be marked
  //      done with one `.in("id", ids)`, the same shape every other push_sent table here
  //      uses, instead of one UPDATE per (comment_id, user_id) pair (the shape the
  //      composite-keyed `follows` block below has to fall back to).
  //
  //      Every row this reads is marked push_sent = true once processed, including rows
  //      that were the ONLY like in their group and turned out to be a self-like: an
  //      unmarked skip would be re-evaluated by every future poll forever.
  const { data: commentLikes } = await supabase
    .from("comment_likes")
    .select("id, comment_id, user_id, post_comments(user_id, body, post_id)")
    .eq("push_sent", false);

  const likesByComment = new Map<string, {
    authorId?: string; body: string; postId?: string; likerIds: Set<string>; ids: string[];
  }>();
  for (const cl of commentLikes ?? []) {
    const meta = (cl as { post_comments?: { user_id?: string; body?: string; post_id?: string } }).post_comments;
    const g = likesByComment.get(cl.comment_id) ?? {
      authorId: meta?.user_id,
      body: meta?.body ?? "",
      postId: meta?.post_id,
      likerIds: new Set<string>(),
      ids: [],
    };
    // Never let a self-like into the group: liking your own comment must never notify you.
    if (meta?.user_id !== cl.user_id) g.likerIds.add(cl.user_id);
    g.ids.push(cl.id);
    likesByComment.set(cl.comment_id, g);
  }

  for (const g of likesByComment.values()) {
    if (g.authorId && g.likerIds.size > 0) {
      const likers = [...g.likerIds];
      const title = likers.length === 1
        ? `${await handle(likers[0])} liked your comment`
        : `${likers.length} people liked your comment`;
      // Truncated the same way the comment-notification preview above is, not quoted.
      const preview = g.body.length > 90 ? g.body.slice(0, 87) + "…" : g.body;
      // Opens the post with the comment thread showing, same route the original
      // comment-notification uses. `likers[0]` stands in for the block check, the same
      // simplification the tagged-photo-reactions and roll-photo-comments blocks above use
      // when several people are folded into one push.
      sent += await notify(
        g.authorId,
        likers[0],
        title,
        preview,
        g.postId ? { t: "post", id: g.postId, comments: true } : undefined,
      );
    }
    await supabase.from("comment_likes").update({ push_sent: true }).in("id", g.ids);
  }

  // ---- New followers → notify the person who was followed.
  //
  //      The one social event that reached the in-app Activity feed but never the phone:
  //      someone could follow you and nothing would tell you unless you opened Activity.
  //
  //      The flag is flipped whether or not a push actually went out (no device registered,
  //      blocked either way, self-follow), so a row can never be retried forever. `notify`
  //      is the single door that enforces blocks.
  const { data: follows } = await supabase
    .from("follows")
    .select("follower_id, following_id")
    .eq("push_sent", false);

  for (const f of follows ?? []) {
    const name = await handle(f.follower_id);
    // Title-only: matches the house shape every other push in this file uses, the actor's name +
    // verb in the title ("{name} commented", "{name} tagged you", "{name} liked your comment"),
    // rather than the inverted "New follower" title / "{name} started following you" body this
    // used to have. There's nothing left to say in the body once the name and the event are both
    // in the title, and `sendPush` omits the `body` key entirely when none is given (see above
    // its definition), so this renders as a clean single-line banner, never a blank second line.
    // Still routes to the follower's profile.
    sent += await notify(f.following_id, f.follower_id, `${name} started following you`, undefined, {
      t: "profile",
      id: f.follower_id,
    });
    // Composite primary key (follower_id, following_id): both halves are needed to address
    // the row, and there is no surrogate id to use instead.
    await supabase
      .from("follows")
      .update({ push_sent: true })
      .eq("follower_id", f.follower_id)
      .eq("following_id", f.following_id);
  }

  // ---- Content reports → notify the app OWNER (Guideline 1.2, act within 24h).
  //      Every report pushes (not just the >=2-reporter auto-hide threshold), so a
  //      first report is seen immediately. push_sent is flipped regardless of
  //      whether the owner has a device registered (same as the blocks above);
  //      the migration's daily-check query is the backstop for the no-device case.
  const ownerPushTokens = await ownerTokens();

  const { data: photoReports } = await supabase
    .from("photo_reports")
    .select("id, photo_id, reason")
    .eq("push_sent", false);

  for (const r of photoReports ?? []) {
    const body = r.reason ? `Reason: ${r.reason}` : "A photo was reported. Review in the dashboard.";
    for (const token of ownerPushTokens) {
      if (await sendPush(token, "Photo reported", body)) sent++;
    }
    await supabase.from("photo_reports").update({ push_sent: true }).eq("id", r.id);
  }

  const { data: userReports } = await supabase
    .from("user_reports")
    .select("id, reported_id, reason")
    .eq("push_sent", false);

  for (const r of userReports ?? []) {
    const who = await handle(r.reported_id);
    const body = r.reason ? `${who}: ${r.reason}` : `${who} was reported. Review in the dashboard.`;
    for (const token of ownerPushTokens) {
      if (await sendPush(token, "User reported", body)) sent++;
    }
    await supabase.from("user_reports").update({ push_sent: true }).eq("id", r.id);
  }

  // --- Badges deliberately send NOTHING. They are discovered, not announced: earning is
  //     silent, the Home avatar's dot and the profile's "New badge to see" pill do the telling,
  //     and the reveal happens in the picker when the person chooses to look. A push per badge
  //     shipped here on 2026-08-18 and was removed a day later when the design settled; if the
  //     idea comes back, know that `earned_badges.push_sent` still exists but is no longer
  //     flipped, so "false" means "earned since 2026-08-19", not "queued".

  return new Response(`sent ${sent} social push(es)`);
});
