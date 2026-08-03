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
): Promise<number> {
  if (!toId || toId === fromId) return 0;
  if (await blockedEitherWay(toId, fromId)) return 0;
  let sent = 0;
  for (const token of await tokensFor(toId)) {
    if (await sendPush(token, title, body)) sent++;
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

  // ---- Comments: one push per comment, to the post owner (never self) ----
  const { data: comments } = await supabase
    .from("post_comments")
    .select("id, post_id, user_id, body, posts(user_id)")
    .eq("push_sent", false);

  for (const c of comments ?? []) {
    const ownerId = (c as { posts?: { user_id?: string } }).posts?.user_id;
    const name = await handle(c.user_id);
    const preview = c.body.length > 90 ? c.body.slice(0, 87) + "…" : c.body;
    // Tracks who has already been pushed for this comment, so someone who is BOTH the post owner
    // and @mentioned in it gets one notification rather than two.
    const notified = new Set<string>([c.user_id]);
    if (ownerId) {
      notified.add(ownerId);
      sent += await notify(ownerId, c.user_id, `${name} commented`, preview);
    }
    // Capped: one comment can name any number of people, and without a limit a single comment
    // could fan out into dozens of pushes. Five is generous for a real conversation and useless
    // as a megaphone.
    let mentionPushes = 0;
    for (const uid of await mentionedUserIds(c.body)) {
      if (notified.has(uid) || mentionPushes >= 5) continue;
      notified.add(uid);
      mentionPushes++;
      sent += await notify(uid, c.user_id, `${name} mentioned you`, preview);
    }
    await supabase.from("post_comments").update({ push_sent: true }).eq("id", c.id);
  }

  // ---- New posts: notify people tagged in the photo + @mentioned in the caption ----
  const { data: newPosts } = await supabase
    .from("posts")
    .select("id, user_id, caption")
    .eq("push_sent", false);

  for (const p of newPosts ?? []) {
    const name = await handle(p.user_id);
    // Notify each person tagged in the photo (never the poster).
    const { data: tagRows } = await supabase.from("post_tags").select("tagged_user_id").eq("post_id", p.id);
    const notified = new Set<string>([p.user_id]);
    for (const t of tagRows ?? []) {
      const uid = t.tagged_user_id as string;
      if (!notified.has(uid)) {
        notified.add(uid);
        sent += await notify(uid, p.user_id, `${name} tagged you`, "in a photo");
      }
    }
    await supabase.from("posts").update({ push_sent: true }).eq("id", p.id);
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
      sent += await notify(g.ownerId, g.reactorId, `${name} reacted ${emojis}`, "to your photo");
    }
    await supabase.from("post_reactions").update({ push_sent: true }).in("id", g.ids);
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
      // `fromOthers[0].userId` is the sole/most recent commenter; blocks are checked against
      // them, so a blocked person can't reach you through a roll photo either.
      sent += await notify(recipient, fromOthers[0].userId, title, body);
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
      const emojis = [...new Set(g.emojis)].join(" ");
      sent += await notify(g.ownerId, g.reactorId, `${name} reacted ${emojis}`, "to your photo");
    }
    await supabase.from("photo_reactions").update({ push_sent: true }).in("id", g.ids);
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
