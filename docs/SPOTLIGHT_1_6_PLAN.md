# Spotlight in 1.6: the plan (second pass)

Rewritten 2026-09-25. The first pass (a header switch and a Spotlight view beside the Feed) was
set aside by the owner because it made Spotlight look as heavy as the Feed. This pass starts
over. The boards are the Claude Design canvas "FLIM 1.6 Spotlight, second pass".

## The idea

Spotlight is a Monday, not a place. All week it is invisible. People put one frame a week
forward from their own post's menu, and only the owner sees what was put up. On Monday the
owner chooses three to six and publishes. The chosen frames arrive in everyone's feed as one
short strip, roughly a third of the height of a single post, at Monday's place in the feed. It
scrolls past and ages out after seven days like everything else. The record lives with the
people chosen: a gold badge, earned once, and a shelf on their page.

Nothing about Spotlight competes with the feed, because it is only ever one strip inside it.

## What the person sees

- **Putting one up.** One item in the own-post menu, on the feed card and on the post opened:
  "Put it up for Spotlight", subtitle "Only the owner sees it". The first time only, a sheet:
  "Only the owner sees what you put up. On Monday a few frames are chosen, and those are shown to
  everyone on FLIM. One frame a week. You can take it down until Sunday night." Then the undo
  capsule: "Up for Spotlight / Only the owner sees it until Monday". Once up, the menu item
  reads "Take it down from Spotlight", subtitle "Up for this week". Putting up a second frame the
  same week swaps it, and the menu item says "Swap it into Spotlight", subtitle "Takes down your
  frame from Tuesday". Nothing else anywhere shows that a frame is up.
- **Monday.** The strip in the feed: a band with a small light glyph in the avatar slot,
  "Spotlight", "week of Sep 14", a "new" pill until seen, and a chevron; under it a horizontal
  row of the chosen frames at 118pt, 3:4, the handle under each. Tapping a frame opens the post
  exactly as the feed does, with its own reactions and comments. Tapping the band opens a sheet
  of past weeks, one row of thumbnails per week.
- **The rest of the week.** The strip sits at Monday's place, between Monday's and Sunday's
  units, without the pill, and ages out with the seven-day window.
- **A week with nothing chosen.** Nothing appears. No empty state, no placeholder.
- **The chosen.** One push, "Your frame is in this week's Spotlight" / "Everyone on FLIM can see
  it in their feed.", opening the feed at the strip. An Activity row with the same words. The
  gold Spotlight badge on the first time, announced the way every badge is (the avatar dot, no
  push). A SPOTLIGHT shelf on their page above Chapters, the weeks they were chosen.
- **The owner.** A fifth queue in the web admin panel: the week's frames put up, newest first,
  each with handle, day and Choose / Chosen; "3 chosen"; "Publish to everyone" behind a
  confirm(). Publish sends the strip to every feed and the pushes to the chosen, once. No
  deadline: the week publishes whenever the owner presses it. An ops push to the owner Monday
  09:00 Eastern with the count waiting.

## Decisions

| Decision | Answer | Why |
|---|---|---|
| Where Spotlight lives | One strip in the feed, once a week | The owner's rule: never as heavy as the feed |
| Who sees submissions | Only the owner | Nothing public until chosen, so nothing to browse, rank or compare |
| How many chosen | Three to six a week | Enough to be an event, few enough to stay one strip |
| Entry point | The own-post menu only | One place to learn; the compose toggle, the pill and the Sunday push are cut |
| Reactions and comments on a chosen frame | As the post allows today | The server already lets any signed-in person read and comment on a visible post; the follower gate is client-side |
| First-time sheet | Once | The audience change happens only if chosen, and the push says so then |
| The mark on frames | None | The strip, the badge and the shelf carry it; photographs stay clean |
| Badge | Gold, earned once, never changes | The existing ratchet; rarest-first leads with it while it is rare |
| Deadline for the owner | None | A missed Monday must not erase the week's submissions |

Cut from the first pass, deliberately: the header switch, the Spotlight view, the public grid of
submissions, the compose toggle, the "Up for Spotlight" pill, the Sunday reminder push, the
light on frames, the week's public meta line, the one-frame-per-week public swap race.

## The contract (what v2 inherits)

**Tables.** `spotlight_weeks` (week_key date PK, the Monday; published_at). `spotlight_entries`
(id, post_id unique, user_id, week_key, put_up_at, withdrawn_at, chosen_at). A partial unique
index keeps one live entry per user per week.

**Visibility.** Clients may read their own entries, and chosen entries of published weeks
whose post they can see (the existing hidden, block and covered rules). Nothing else. Every
write goes through a SECURITY DEFINER RPC pinned to auth.uid(), search_path set.

**The week key.** `spotlight_week_key(ts)`: to America/New_York, minus four hours, the Monday of
that date. A post belongs to the week its `created_at` maps to; only the current week accepts
put-ups.

**RPCs.** `put_up_for_spotlight(p_post_id)` (own post, current week, not covered; swaps),
`withdraw_from_spotlight(p_post_id)` (until the week ends), `own_spotlight_entry()`,
`spotlight_published(p_since)` (published weeks with chosen entries, post paths and handles),
`spotlight_frames(p_user_id)` (the shelf). Owner-only, `is_owner()` inside each body, EXECUTE
revoked from anon: `list_spotlight_queue(p_week_key)`, `choose_spotlight_entry`,
`unchoose_spotlight_entry` (until published), `publish_spotlight_week(p_week_key)`.

**Pushes.** `spotlight_chosen` through `send-social-push` and its ledger, keyed (kind,
week_key, user_id), route `spotlight` with week key (1.5.x clients get route `feed`). The owner's
Monday ops push.

**The feed.** The feed loads `spotlight_published` for the seven-day window and inserts one unit
per published week at `published_at`. The "new" pill uses a per-account seen key per week, like
the Activity watermark.

**Badge, Activity, counters.** `spotlight` in the badge CHECK and `_ratchet_badges` ("has a
chosen entry in a published week"); Activity row kind `spotlight`; day-bucket counters
`spotlight_put_up`, `spotlight_withdraw`, `spotlight_strip_open`, `spotlight_weeks_open`.

## Build order

1. **Server** (supabase-guardian): migration, schema ledger, bootstrap proof; the push kind;
   the admin queue in `web/admin.html`. Apply, redeploy `send-social-push`, deploy the site.
2. **Client** (swift-builder): the strip unit and the past-weeks sheet (`FeedView`,
   `FeedService`, one new view file, so `xcodegen generate`); the menu items, the first-time
   sheet and the undo; the badge, the shelf, the Activity row, `PushDestination.spotlight`.
3. **Release** (release-captain): 1.6.0 on TestFlight through one Monday with the owner
   publishing a real week; then the App Store; then `latest_version` 1.6.0.

## What proves it

- The week key at 03:59 and 04:00 Monday Eastern and across the November DST change; a post at
  Sunday 23:50 Eastern belongs to the closing week.
- On the bootstrap database: put up, swap, withdraw, refuse after the week, choose, unchoose,
  publish, refuse unchoose after publish, badge ratchet, covered refusal, block filter, cascade on
  post and account delete, and a non-owner reading another person's unchosen entry is refused.
- sim-verifier RELEASE on the client, with the stale-write audit on the new `FeedService` paths.
- On the TestFlight Monday: the strip arrives for everyone on publish, the push reaches only the
  chosen, the badge dot lights on the next reload, the strip drops to Monday's place after it is
  seen, and nothing appears in a week the owner does not publish.
- After release: people putting a frame up per week, strip opens per active day, reactions on
  chosen frames in the 48 hours after publish, and captures per active day not falling.
