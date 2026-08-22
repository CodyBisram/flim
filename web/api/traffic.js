/* GET /api/traffic
 *
 * The Traffic panel's data source. Vercel Web Analytics keeps the numbers, and
 * its REST API needs an account token, which cannot live in admin.html: that
 * page is a static asset served to anyone who types the URL. So the token stays
 * here, in a server-side env var, and this function is the only thing that holds
 * it.
 *
 * THE GATE. This function is world-reachable, so it does its own authorization
 * rather than assuming an unlisted path is a private one. The caller sends the
 * admin page's Supabase access token, and we spend it on public.is_owner()
 * against Supabase. That reuses the exact gate every admin_* RPC already
 * applies, so there is one definition of "the owner" and not two that can drift.
 * A non-owner gets 403 and never reaches the Vercel token.
 *
 * WHY allSettled. Same reason load() in admin.html uses it: these are ten
 * independent queries, and Promise.all would let one unavailable dimension
 * blank the whole panel. Each query fails on its own and is named in `failed`,
 * so the page can render nine answers and say which one is missing. This is
 * load-bearing rather than defensive: the UTM dimension names below are the one
 * part of this file not confirmed against a live project (Web Analytics was not
 * yet enabled when it was written, so every query 404s until it is), and a wrong
 * name there must cost one row, not the panel.
 *
 * CommonJS on purpose. There is no package.json in web/, so Vercel's Node
 * runtime reads a bare .js as CommonJS; `export default` here would fail at
 * runtime with a syntax error rather than at deploy time.
 */

"use strict";

/* The publishable Supabase key, already shipped inside index.html, admin.html
   and the iOS app. It is public by design and every table behind it is closed
   by RLS. Here it only ever accompanies a caller-supplied user token. */
const SUPABASE_URL = "https://wxvwamwrjlrvqmuaafjv.supabase.co";
const SUPABASE_KEY = "sb_publishable_ze8KEytcVzvKOijlUQ8Kfw_nb3kJ-V4";

/* Identifiers, not secrets: they name which project to read, and holding one
   without the token buys nothing. Hardcoded with an env override so the owner's
   setup is a single variable (VERCEL_ANALYTICS_TOKEN) rather than three. */
const PROJECT_ID = process.env.FLIM_VERCEL_PROJECT_ID || "prj_jYMTSLv695pBJXqaTStcARztLQeR";
const TEAM_ID = process.env.FLIM_VERCEL_TEAM_ID || "team_MZMd4b7hR3GoTz3RZv4QwwsT";

const ANALYTICS_BASE = "https://api.vercel.com/v1/query/web-analytics/visits";

/* 30 days is the window the panel reads, and the 7 day figures are derived from
   the daily series rather than fetched again, so the two can never disagree. */
const WINDOW_DAYS = 30;

function isoDay(date) {
  return date.toISOString().slice(0, 10);
}

async function isOwner(userToken) {
  const res = await fetch(SUPABASE_URL + "/rest/v1/rpc/is_owner", {
    method: "POST",
    headers: {
      apikey: SUPABASE_KEY,
      Authorization: "Bearer " + userToken,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!res.ok) return false;
  return (await res.json()) === true;
}

async function query(path, params, token) {
  const url = new URL(ANALYTICS_BASE + path);
  url.searchParams.set("projectId", PROJECT_ID);
  url.searchParams.set("teamId", TEAM_ID);
  for (const [key, value] of Object.entries(params)) {
    if (Array.isArray(value)) value.forEach((v) => url.searchParams.append(key, v));
    else if (value !== undefined) url.searchParams.set(key, String(value));
  }

  const res = await fetch(url, { headers: { Authorization: "Bearer " + token } });
  if (!res.ok) {
    throw new Error(path + " " + res.status + " " + (await res.text()).slice(0, 200));
  }
  return (await res.json()).data;
}

module.exports = async (req, res) => {
  const token = process.env.VERCEL_ANALYTICS_TOKEN;

  const auth = req.headers.authorization || "";
  const userToken = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!userToken) {
    res.status(401).json({ error: "Sign in first." });
    return;
  }

  let owner = false;
  try {
    owner = await isOwner(userToken);
  } catch (e) {
    res.status(502).json({ error: "Could not check who you are." });
    return;
  }
  if (!owner) {
    res.status(403).json({ error: "That account is not the owner." });
    return;
  }

  /* Checked AFTER the gate on purpose. Before it, the error message would tell
     an anonymous caller whether this deployment has an analytics token
     configured, which is a small thing to give away for nothing. */
  if (!token) {
    res.status(503).json({
      error: "No VERCEL_ANALYTICS_TOKEN is set on this deployment.",
    });
    return;
  }

  const until = new Date();
  const since = new Date(until.getTime() - WINDOW_DAYS * 86400000);
  const range = { since: isoDay(since), until: isoDay(until) };

  /* One entry per number the panel draws. `by` is a repeated query parameter,
     which is why the values are arrays even when there is only one dimension. */
  const QUERIES = {
    total: ["/count", {}],
    daily: ["/aggregate", { ...range, by: ["day"], limit: 100 }],
    referrers: ["/aggregate", { ...range, by: ["referrerHostname"], limit: 15 }],
    pages: ["/aggregate", { ...range, by: ["requestPath"], limit: 15 }],
    countries: ["/aggregate", { ...range, by: ["country"], limit: 20 }],
    devices: ["/aggregate", { ...range, by: ["deviceType"], limit: 10 }],
    systems: ["/aggregate", { ...range, by: ["osName"], limit: 10 }],
    browsers: ["/aggregate", { ...range, by: ["browserName"], limit: 10 }],
    /* These two are expected to fail on this project and are kept deliberately.
       The names are right (`utmCampaign` is a documented dimension), but UTM
       breakdowns are gated behind Vercel's paid Web Analytics Plus, confirmed
       2026-08-22 by the lock on the dashboard's UTM Parameters tab. They stay in
       the list so the panel reports the paywall as a fact rather than silently
       omitting campaign data, and so they start working the day the plan changes
       with no code edit. `allSettled` keeps their failure to two rows. */
    utmSource: ["/aggregate", { ...range, by: ["utmSource"], limit: 10 }],
    utmCampaign: ["/aggregate", { ...range, by: ["utmCampaign"], limit: 10 }],
  };

  const names = Object.keys(QUERIES);
  const settled = await Promise.allSettled(
    names.map((n) => query(QUERIES[n][0], QUERIES[n][1], token))
  );

  const out = { since: range.since, until: range.until, failed: [] };
  settled.forEach((result, i) => {
    if (result.status === "fulfilled") {
      out[names[i]] = result.value;
    } else {
      out[names[i]] = null;
      out.failed.push(names[i]);
    }
  });

  /* Never cached at the edge. This response is owner-only, and a shared cache
     entry keyed on the path alone would be servable to the next caller. */
  res.setHeader("Cache-Control", "no-store, private");
  res.status(200).json(out);
};
