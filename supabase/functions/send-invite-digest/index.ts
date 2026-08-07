// ============================================================
// FLIM send-invite-digest  (Supabase Edge Function, Deno)
//
// The website's "request an invite" form writes straight into
// public.invite_requests through the anon request_invite RPC, nobody watches
// that table by staring at the dashboard. This is the one email a day that
// tells the owner someone is waiting, with the SQL already written so acting
// on it is a copy and paste from a phone, not a trip to the SQL editor.
//
// Sends AT MOST one email per run, and only when there is something to say.
// A quiet day with zero pending requests sends nothing at all: an inbox that
// gets a "0 requests today" email every morning trains you to stop reading
// it, which is exactly the day a real request slips by unnoticed.
//
// Reading the digest never marks anything handled. handled only flips two
// ways: public.approve_invite_request(), or a deliberate manual UPDATE. This
// function only SELECTs. The tempting shortcut here is to stamp rows as
// "notified" after sending so the next run doesn't repeat them, but that
// quietly drops a request from every future digest the moment the owner is
// slow to act on it, before it was ever approved or declined. Repetition
// until somebody actually resolves the row is the point.
//
// Deploy:
//   supabase functions deploy send-invite-digest --no-verify-jwt
// Requires: supabase/migrations/2026-08-07_invite_requests.sql
//           supabase/migrations/2026-08-07_approve_invite_request.sql
// Requires the RESEND_API_KEY secret:
//   supabase secrets set RESEND_API_KEY=re_...
//
// SCHEDULED (pg_cron job `flim-invite-digest`):  0 13 * * *
//   Once daily, not hourly like send-daily-digest: this isn't reacting to
//   something that just happened, it's a standing summary of a queue that
//   only grows a few rows a day at most. 13:00 UTC is 9am Eastern during
//   daylight time and 8am during standard time, which lands before the
//   10am-to-9pm Eastern window send-daily-digest uses for its own sends, so
//   the invite queue is the first thing waiting when the owner's day starts
//   rather than something buried under whatever arrives later.
//
//   To schedule or change it:
//     SELECT cron.schedule('flim-invite-digest', '0 13 * * *',
//       $$ SELECT net.http_post(url := '<fn url>'); $$);
// ============================================================

// Pinned deliberately, see send-daily-digest: an unpinned `@2` re-resolves on
// every deploy and an upstream publishing problem then breaks deploys of code
// that hasn't changed.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.111.0";

// Mirrors the constant in send-social-push. There is one owner, and this is
// their address, not something worth deriving from a table.
const OWNER_EMAIL = "codyysb@gmail.com";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

interface PendingRequest {
  email: string;
  note: string | null;
  created_at: string;
}

// ---- Formatting -----------------------------------------------------------

/// Anything below came from a public, unauthenticated form. It gets read by a
/// mail client as HTML, so it must never be spliced into markup raw: a note
/// field is free text from a stranger, and an email address only has to
/// satisfy request_invite's loose regex, which does not forbid angle
/// brackets or quotes.
function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/// The SQL block is meant to be pasted straight into the SQL editor and run,
/// so a single quote inside an attacker-controlled email has to be escaped
/// for SQL, not just for HTML, or a crafted address could break out of the
/// string literal the owner is about to execute.
function sqlLiteral(value: string): string {
  return value.replace(/'/g, "''");
}

function timeAgo(iso: string): string {
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 60_000));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function buildEmail(pending: PendingRequest[]): { subject: string; html: string; text: string } {
  const subject = pending.length === 1
    ? "FLIM: 1 invite request waiting"
    : `FLIM: ${pending.length} invite requests waiting`;

  const textLines: string[] = [];
  const htmlItems: string[] = [];
  const approveLines: string[] = [];

  for (const row of pending) {
    const ago = timeAgo(row.created_at);
    const noteText = row.note?.trim() ? row.note.trim() : null;

    textLines.push(`- ${row.email} (${ago})`);
    if (noteText) textLines.push(`  note: "${noteText}"`);

    htmlItems.push(
      `<li><strong>${escapeHtml(row.email)}</strong> ` +
        `<span style="color:#888888">(${escapeHtml(ago)})</span>` +
        (noteText ? `<br><span style="color:#555555">note: "${escapeHtml(noteText)}"</span>` : "") +
        `</li>`,
    );

    approveLines.push(`SELECT public.approve_invite_request('${sqlLiteral(row.email)}');`);
  }

  const declineNote =
    "To turn someone down without allowlisting them, so they stop reappearing here:\n" +
    "  UPDATE public.invite_requests SET handled = TRUE WHERE email = '<their email>';";

  const text =
    `${pending.length} invite request${pending.length === 1 ? "" : "s"} waiting.\n\n` +
    `${textLines.join("\n")}\n\n` +
    `Run in the Supabase SQL editor to approve:\n\n${approveLines.join("\n")}\n\n` +
    `${declineNote}\n`;

  const sqlBlockHtml = escapeHtml(approveLines.join("\n"));
  const declineBlockHtml = escapeHtml(
    "UPDATE public.invite_requests SET handled = TRUE WHERE email = '<their email>';",
  );

  const html = `
    <div style="font-family: -apple-system, sans-serif; font-size: 15px; color: #111111;">
      <p>${pending.length} invite request${pending.length === 1 ? "" : "s"} waiting.</p>
      <ul>${htmlItems.join("")}</ul>
      <p>Paste into the Supabase SQL editor to approve:</p>
      <pre style="background:#f4f4f4; padding:12px; border-radius:6px; white-space:pre-wrap;">${sqlBlockHtml}</pre>
      <p>To turn someone down without allowlisting them, so they stop reappearing here:</p>
      <pre style="background:#f4f4f4; padding:12px; border-radius:6px; white-space:pre-wrap;">${declineBlockHtml}</pre>
    </div>
  `;

  return { subject, html, text };
}

async function sendEmail(subject: string, html: string, text: string): Promise<boolean> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "authorization": `Bearer ${RESEND_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: "FLIM <invites@flim-app.com>",
      to: [OWNER_EMAIL],
      subject,
      html,
      text,
    }),
  });
  const reason = res.ok ? undefined : await res.text();
  console.log(JSON.stringify({ at: "resend_send", ok: res.ok, status: res.status, reason }));
  return res.ok;
}

// ---- Run --------------------------------------------------------------

Deno.serve(async () => {
  const { data, error } = await supabase
    .from("invite_requests")
    .select("email, note, created_at")
    .eq("handled", false)
    .order("created_at", { ascending: true });

  if (error) {
    console.log(JSON.stringify({ at: "invite_digest_query_failed", message: error.message }));
    return new Response("query failed", { status: 200 });
  }

  const pending = (data ?? []) as PendingRequest[];
  if (pending.length === 0) {
    console.log(JSON.stringify({ at: "invite_digest_run", pending: 0, sent: false }));
    return new Response("no pending invite requests");
  }

  // The function is deployed ahead of the secret being set on purpose, since
  // deploy and secret configuration are separate manual steps for the owner.
  // A missing key here is an expected, not exceptional, state: log it plainly
  // and return 200 so a scheduled run that fires before the secret exists
  // doesn't show up as a failure anywhere.
  if (!RESEND_API_KEY) {
    console.log(JSON.stringify({
      at: "invite_digest_skipped",
      reason: "RESEND_API_KEY not set",
      pending: pending.length,
    }));
    return new Response(
      `${pending.length} invite request(s) pending, but RESEND_API_KEY is not set, no email sent`,
    );
  }

  const { subject, html, text } = buildEmail(pending);
  const sent = await sendEmail(subject, html, text);

  console.log(JSON.stringify({ at: "invite_digest_run", pending: pending.length, sent }));
  return new Response(`invite digest: ${pending.length} pending, email ${sent ? "sent" : "failed"}`);
});
