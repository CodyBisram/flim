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
// omitted for destinations that need none (the daily digest, elsewhere). `comments` is set only
// on "post" pushes that are specifically about a comment, so the client can open with the
// comment thread already showing.
interface FlimRoute {
  t: "reveal" | "post" | "profile" | "feed";
  id?: string;
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
  body: string,
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

// --- App owner: the single place the owner is named. Matches the `note = 'owner'`
//     seed in allowed_emails (schema.sql). Report notifications go to whichever
//     account(s) sign in with this email; resolved by email (case-insensitive) so
//     no raw user UUID is hardcoded. If the owner has no registered device, the
//     report still sits in the table for the daily-check query in the migration.
const OWNER_EMAIL = "codyysb@gmail.com";

async function ownerTokens(): Promise<string[]> {
  const { data: owners } = await supabase.from("users").select("id").ilike("email", OWNER_EMAIL);
  const tokens: string[] = [];
  for (const o of owners ?? []) tokens.push(...(await tokensFor(o.id)));
  return [...new Set(tokens)];
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

  const { data: windowRows, error: windowsError } = await supabase
    .from("covered_post_windows")
    .select("user_id, window_start, window_end, active");
  if (windowsError) {
    console.warn(JSON.stringify({ at: "covered_post_windows_fetch_failed", error: windowsError.message }));
    return { loaded: false, windowByAuthor, allowedViewers };
  }
  for (const row of windowRows ?? []) {
    const userId = row.user_id as string;
    const active = Boolean(row.active);
    windowByAuthor.set(userId, {
      start: new Date(row.window_start as string).getTime(),
      end: new Date(row.window_end as string).getTime(),
      active,
    });
    if (active) allowedViewers.add(userId);
  }

  const { data: ownerRows, error: ownerError } = await supabase
    .from("users")
    .select("id")
    .ilike("email", OWNER_EMAIL);
  if (ownerError) {
    console.warn(JSON.stringify({ at: "covered_post_owner_lookup_failed", error: ownerError.message }));
    return { loaded: false, windowByAuthor, allowedViewers };
  }
  for (const o of ownerRows ?? []) allowedViewers.add(o.id as string);

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

Deno.serve(async () => {
  let sent = 0;

  // Fetched once per run, evaluated per (recipient, post) below wherever a recipient isn't
  // guaranteed to be the post's own author. See the "Covered posts" section above for the
  // fail-closed contract.
  const coveredCtx = await loadCoveredPostContext();

  // ---- Comments: one push per comment, to the post owner (never self) ----
  const { data: comments } = await supabase
    .from("post_comments")
    .select("id, post_id, user_id, body, posts(user_id, created_at)")
    .eq("push_sent", false);

  for (const c of comments ?? []) {
    const postMeta = (c as { posts?: { user_id?: string; created_at?: string } }).posts;
    const ownerId = postMeta?.user_id;
    const name = await handle(c.user_id);
    const preview = c.body.length > 90 ? c.body.slice(0, 87) + "…" : c.body;
    // Tracks who has already been pushed for this comment, so someone who is BOTH the post owner
    // and @mentioned in it gets one notification rather than two.
    // Both this comment's owner-push and its mention-pushes land on the SAME comment, on the
    // SAME post, so they share one route. Built fresh per comment row (from this row's own
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
    await supabase.from("post_comments").update({ push_sent: true }).eq("id", c.id);
  }

  // ---- New posts: notify people tagged in the photo + @mentioned in the caption ----
  const { data: newPosts } = await supabase
    .from("posts")
    .select("id, user_id, caption, created_at")
    .eq("push_sent", false);

  for (const p of newPosts ?? []) {
    const name = await handle(p.user_id);
    // Notify each person tagged in the photo (never the poster).
    const { data: tagRows } = await supabase.from("post_tags").select("tagged_user_id").eq("post_id", p.id);
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
    await supabase.from("posts").update({ push_sent: true }).eq("id", p.id);
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
      emojis: [],
      ids: [],
    };
    g.emojis.push(r.emoji);
    g.ids.push(r.id);
    groups.set(key, g);
  }

  for (const g of groups.values()) {
    if (g.ownerId && g.ownerId !== g.reactorId) {
      const name = await handle(g.reactorId);
      // Deliberately WITHOUT the emoji. The picker now offers every emoji the sender's OS can
      // draw, so a reaction chosen on a newer iPhone can be a character an older one has no
      // glyph for. Inside the app an unrenderable reaction falls back to a placeholder chip, but
      // a push title is drawn by iOS's own notification UI where we have no such control, and a
      // tofu box in a banner is the most visible possible way to look broken. The reaction is one
      // tap away in the app.
      sent += await notify(g.ownerId, g.reactorId, `${name} reacted`, "to your photo", {
        t: "post",
        id: g.postId,
      });
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
      // Routes into the roll itself (no per-photo destination exists in the contract), built
      // fresh per photo group from that group's own rollId, so it can't drift onto another
      // photo's roll. Omitted entirely when a photo somehow has no roll_id, leaving the client's
      // safe "no routing data" fallback instead of a guess.
      const route: FlimRoute | undefined = g.rollId ? { t: "reveal", id: g.rollId } : undefined;
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
    ownerId?: string; rollId?: string; reactorId: string; emojis: string[]; ids: string[];
  }>();
  for (const r of photoReactions ?? []) {
    const meta = (r as { photos?: { user_id?: string; roll_id?: string } }).photos;
    const key = `${r.photo_id}|${r.user_id}`;
    const g = rxByKey.get(key) ??
      { ownerId: meta?.user_id, rollId: meta?.roll_id, reactorId: r.user_id, emojis: [], ids: [] };
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
      // Deliberately WITHOUT the emoji. The picker now offers every emoji the sender's OS can
      // draw, so a reaction chosen on a newer iPhone can be a character an older one has no
      // glyph for. Inside the app an unrenderable reaction falls back to a placeholder chip, but
      // a push title is drawn by iOS's own notification UI where we have no such control, and a
      // tofu box in a banner is the most visible possible way to look broken. The reaction is one
      // tap away in the app. Same "omit rather than guess" treatment as the roll-photo-comments
      // route above when a photo somehow has no roll_id.
      sent += await notify(
        g.ownerId,
        g.reactorId,
        `${name} reacted`,
        "to your photo",
        g.rollId ? { t: "reveal", id: g.rollId } : undefined,
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
    // Title/body split the way the report pushes do. No "tap to see their profile": these
    // payloads carry no deep link, a tap just opens the app, and promising a destination the
    // notification cannot reach is worse than saying only what happened.
    sent += await notify(f.following_id, f.follower_id, "New follower", `${name} started following you`, {
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

  return new Response(`sent ${sent} social push(es)`);
});
