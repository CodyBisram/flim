# Spotlight in 1.6: the plan

Written 2026-09-25 with the owner's full delegation on design. The brief it settles is
`docs/prompts/CLAUDE_DESIGN_1_6_SPOTLIGHT_2026-09-25.md`; the boards are the Claude Design canvas
"FLIM 1.6 Spotlight". This page is the build plan: what is decided, what gets built, in what
order, and what proves it.

## The position

Spotlight ships as the smallest thing that creates a Monday. One quiet word beside "Feed", one
grid of the week's frames, one way to put a frame up, one push, one badge, one shelf. A weekly
feature in a daily app fails one of two ways: nobody finds it, or it becomes a second feed. The
header switch stops it becoming a second feed; the Sunday reminder and the Monday push stop it
disappearing. Everything else in the brief (the nine states, the edge cases, the owner's queue)
is the discipline of doing that small thing properly, and it is built so v2 restyles it without
rebuilding it.

## Decisions, all settled

| # | Decision | Answer | Why |
|---|---|---|---|
| 1 | The first week | One full week on TestFlight before App Store submission | The push route, the badge ratchet and Done cannot be proven on a simulator; the testers are the first Monday |
| 2 | The consequence sheet | First two times, then never | It names a real audience change; twice is learning, every time is nagging |
| 3 | Strangers on a Spotlight frame | Anyone can react and comment | The server already lets any signed-in person read and comment on any visible post; the follower gate is client-side. Hiding the composer on Spotlight would be theatre. Block and Report cover abuse |
| 4 | The owner's queue | Web admin only in 1.6 | The in-app owner mode is v2 work; the web queue is one panel in an existing pattern |
| 5 | Monday noon | The queue stays open until Done, whenever that is | A missed noon under the strict rule punishes the people who put frames up. The owner gets an ops push at 09:00 Eastern with the count |
| 6 | The shelf on a page you do not follow | Shown | The frames were public in Spotlight; hiding them on the page would be a second rule for the same photograph |
| 7 | Columns | Two | The week's chosen frames deserve size; three columns reads as the profile grid |
| 8 | The light | A, the glow | It reads at card size, at 120pt and in a 3pt grid gap without a glyph; the hairline reads as an iOS selection ring; the beam is an icon on a photograph |
| 9 | A signal on the switch | None | The push already reaches the one person who needs it; the word is in the header on every feed open. Revisit only if the rollout check shows the view is not being opened |
| D1 | Consequence confirm | White PrimaryButton | Red means destructive here and putting a frame up is not |
| D2 | The "Up for Spotlight" pill on a multi-frame day | Only while the pager shows the frame that is up | The pill's job is to say which frame |
| D3 | Sunday push hour | 18:00 Eastern | The week closes at one moment; the app stores no time zone yet. Move to local 18:00 once the per-open time zone from the v2 decisions exists |
| D4 | Web confirm for Done | Browser confirm() | The owner's own tool |
| Badge | Glyph, tier | 🔦, gold | The catalogue is emoji; gold because it is rare at first and rarest-first will lead with it on its own |

The light's colour: `#FFD9A0`, a fixed warm white-amber, never the phone's accent. The glow is a
box shadow past the frame's edges, strongest at the top, 22pt spread at card size, 14pt at
120pt, drawn once, coming up over 350ms on the first view after the push, still under Reduce
Motion and Reduce Transparency.

## What the person sees

- **The header.** "Feed" and "Spotlight" side by side in the same 17pt light weight; the active
  word in `textSecondary` as "Feed" reads today, the other in `textTertiary`. The ledger, the
  bell, find friends and the avatar do not move. The tab and the app always open on the feed.
- **The Spotlight view.** One meta line ("Week of September 14 · closes Sunday night · Eastern
  time", or "· lit Monday" after Done), then two columns of 3:4 frames at the thumb rendition
  with the handle under each, in put-up order, the same frames all week; your own frame carries
  a hairline accent rule under its handle. Lit frames carry the glow. "Past weeks" below, in the
  Chapter shelf's geometry. Tapping a frame opens the post as the feed does.
- **Putting a frame up.** From the own-post menu ("Put it up for Spotlight" / "Take it down from
  Spotlight" / "Swap it into Spotlight") and from the compose sheet's toggle. The consequence
  sheet the first two times. Success is the undo capsule ("Up for Spotlight" / "Everyone on FLIM
  can see it there"); failure lands in its place with the way back.
- **Afterwards.** The push "You're in the Spotlight" landing on the view at the frame; the glow
  on the frame in the feed, on the post and in the page grid; the SPOTLIGHT shelf on the page
  above Chapters; the gold badge beside the avatar; the Activity row "Your frame is in the
  Spotlight".
- **Sunday.** "Spotlight closes tonight" to people who posted this week and have nothing up, and
  "· closes tonight" after the header word for the same people.
- **The owner's Monday.** A fifth queue in the web admin panel: this week's frames at 3:4 with
  handle and day, Spotlight and Remove, "3 in the Spotlight", Done for the week behind a
  confirm(). Done closes the week and sends the pushes once.

## The contract (what v2 inherits unchanged)

**Tables.** `spotlight_weeks` (week_key date PK, the Monday; closed_at). `spotlight_entries` (id,
post_id unique, user_id, week_key, put_up_at, withdrawn_at, chosen_at, chosen_push_sent). One
row per user per week with withdrawn_at null (a partial unique index). RLS: authenticated may
select rows whose post is visible to them (the existing post visibility, blocks and covered
gate) and whose author is not blocked either way; no direct insert, update or delete for
clients, every write goes through a SECURITY DEFINER RPC pinned to auth.uid() with
search_path set.

**The week key.** `spotlight_week_key(ts timestamptz) returns date`: shift to
America/New_York, subtract four hours, take the Monday of that date. A post is eligible for the
week its `created_at` maps to. The current week is `spotlight_week_key(now())`.

**RPCs.** `spotlight_week(p_week_key)` (entries with post paths and handle, in put-up order),
`spotlight_weeks()` (week keys with a cover: the first lit frame, else the first),
`own_spotlight_entry(p_week_key)`, `spotlight_frames(p_user_id)` (the shelf, chosen entries
newest first), `put_up_for_spotlight(p_post_id)` (refuses outside the current week, refuses a
covered account, swaps if one is up), `withdraw_from_spotlight(p_post_id)` (refuses after the
week closed). Owner-only, with `is_owner()` repeated inside each body and EXECUTE revoked from
anon: `list_spotlight_queue(p_week_key)`, `choose_spotlight_entry(p_entry_id)`,
`unchoose_spotlight_entry(p_entry_id)` (refused after Done), `close_spotlight_week(p_week_key)`
(sets closed_at; the push worker picks up chosen rows with chosen_push_sent false).

**Pushes.** Through `send-social-push` and its `push_deliveries` ledger: `spotlight_chosen`
("You're in the Spotlight" / "One of your frames, week of September 14", route `spotlight` with
week and post; to clients below 1.6, per `client_versions`, route `post`), and
`spotlight_closes_tonight` ("Spotlight closes tonight" / "You posted this week. Put one up?",
route `spotlight`), keyed (kind, week_key, user_id) so neither ever sends twice. Two cron jobs:
Sunday 22:00 and 23:00 UTC calling a function that runs only when the Eastern hour is 18 (the
DST-safe way), and Monday 13:00 and 14:00 UTC likewise for the owner's 09:00 Eastern ops push
with the count awaiting review.

**The badge.** `spotlight` added to the `earned_badges` CHECK and to `_ratchet_badges` as
"exists a chosen entry"; gold tier; announced by the existing avatar dot and "New badge to see"
pill, no push. No seen_at backfill is needed because nobody holds it on migration day.

**Activity.** Row kind `spotlight`, built from chosen entries like the other client-side
merges; opens the Feed tab switched to Spotlight at the frame.

**Instrumentation.** Day-bucketed counters in `usage_events`: `spotlight_open`,
`spotlight_put_up`, `spotlight_withdraw`, `spotlight_push_open`.

**The version gate.** `latest_version` moves to 1.6.0 when 1.6 is live on the App Store.

**Facts worth knowing before building.** The follower gate on posts is client-side; the server
lets any signed-in person read any post that is not hidden, blocked or covered. Spotlight adds
no server exposure. The sort deck's "Post to page" circle publishes instantly with no sheet;
the compose sheet is the separate "Add a caption or tag people" pill, which is where the toggle
lives. Neither the card nor the compose sheet carries an audience sentence today; the
consequence sheet is where the audience change is taught.

## Build order, each step shippable alone

1. **Server** (supabase-guardian): the migration with tables, RLS, RPCs, the badge, the week-key
   function, the cron functions; folded into `schema.sql`; proven on
   `scripts/schema_bootstrap.sh --keep`. The edge function's two push kinds and the
   version-aware route. The admin panel's fifth queue (`web/admin.html`, deployed by hand to
   Vercel). Apply the migration, redeploy `send-social-push`, deploy the site.
2. **Client, read-only** (swift-builder): `FeedView` header switch and view swap; a new
   `SpotlightView` (new file, so `xcodegen generate` and confirm the test count moved); the
   Spotlight fetches in `FeedService`; the glow on frames in `FeedUnitCard`, `PostDetailView`
   and the page grid; the shelf in `UserPageView`; the badge in `ProfileIdentity`; the Activity
   row in `Social.swift` and `ActivityFeedView`; `PushDestination.spotlight(weekKey, postId?)`
   and its routing in `MainTabView`. Before step 3 the empty view reads "A new week." without
   promising the menu item.
3. **Client, writes** (swift-builder): the menu items in `FeedUnitCard` and `PostDetailView`,
   the consequence sheet, the undo capsule, the toggle in `SortDeckComposeSheet` carried
   through `performSwipe(.publish, caption:, tags:)`, the "Up for Spotlight" pill synced to the
   pager, withdraw and swap, the queued state offline, the counters.
4. **Pushes** (supabase-guardian): the two cron schedules and the Sunday and Monday functions,
   the ops push to the owner.
5. **Release** (release-captain): MARKETING_VERSION 1.6.0; one full TestFlight week through a
   Monday with the owner circling from his phone; then App Store; then `latest_version` 1.6.0.

Steps 1 and 2 can run in parallel once the contract above is fixed; 3 needs 2; 4 needs 1; 5 needs
all.

## What proves it

- Unit: the week-key function at 03:59 and 04:00 Monday Eastern, across the DST change, on both
  sides of midnight UTC; eligibility for a post created Sunday 23:50 Eastern; the swap rule;
  the client's `weekKey(for:)` mirror pinned to the same cases.
- Schema bootstrap twice on Supabase's image, then the migration on top, then: put up, swap,
  withdraw, refuse after close, choose, unchoose, Done, badge ratchet, the covered refusal, the
  block filter, the cascade on post delete and account delete.
- sim-verifier RELEASE on the last client step, with the static audit of stale writes on
  `FeedService`'s new paths (one guard per write after each await).
- Device, on the TestFlight week: the switch at AX3 wraps and stays tappable; the push lands on
  the frame with the glow coming up; the badge dot lights on the next feed reload; a put-up while
  offline queues and sends; a put-up at 03:59 Monday belongs to the closing week; the Sunday
  push arrives at 18:00 Eastern only for people with nothing up.
- The rollout check for two weeks after App Store release: distinct people putting a frame up
  per week; reactions on lit frames in the 48 hours after Done; captures per active day and
  response within 24 hours of posting not falling; Spotlight view opens per active day, which is
  the number that decides whether the switch ever needs a signal.

## Risks I am carrying knowingly

- A quiet word may be too quiet. The counter above measures it; a 4pt dot on the Monday after
  Done is the one-line fix if it is.
- The glow on a bright frame is the weakest case; the canvas draws it on the neon-sign frame
  for exactly that reason. If it disappears on device, the fallback is a one-point warm hairline
  under the glow, not a glyph.
- The Sunday cron's Eastern-hour check is the one piece of time-zone logic outside the
  week-key function; both are tested across DST before the first Sunday.
- 1.5.x clients see nothing of Spotlight and their posts can still be put up from a 1.6 phone.
  Acceptable for one release; the version nudge closes it.
