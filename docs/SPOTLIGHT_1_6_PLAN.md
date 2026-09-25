# Spotlight in 1.6: the plan (second pass, hardened)

Rewritten 2026-09-25. The first pass (a header switch and a Spotlight view beside the Feed) was
set aside by the owner because it made Spotlight look as heavy as the Feed. This pass starts
over; the boards are the Claude Design canvas "FLIM 1.6 Spotlight, second pass". The same day,
before any code, two adversarial reviews (the SQL and push server; the client and the flows
across the app) went through it against the real code. Every finding is resolved below. One of
them corrected a false premise in the first draft of this plan: the follower gate on posts has
been on the server since 2026-09-13 (`2026-09-13_followers_only_reads.sql`), so "shown to
everyone" needs a deliberate, narrow server exception, not nothing.

## The idea

Copy rule, from the owner (2026-09-25): the people choosing are "the team at FLIM" in every
user-facing string, and a Spotlight is always named by its week ("the week of September 28"),
never by a weekday.

Spotlight is the week's frames, not a place. All week it is invisible. People put one frame a week
forward from their own post's menu, and only the team at FLIM (the owner, in practice) sees what
was put up. After the week closes, the team chooses three to six and publishes. The chosen frames arrive in
everyone's feed as one short strip, roughly a third of the height of a single post, at the
moment of publishing. It scrolls past and ages out after seven days like everything else. The
record lives with the people chosen: a gold badge, earned once, and a shelf on their page.

Nothing about Spotlight competes with the feed, because it is only ever one strip inside it.

## What the person sees

- **Putting one up.** One item in the own-post menu, on the feed card and on the post opened,
  shown only when the post can go up this week (the server says so; see Week). "Put it up for
  Spotlight", subtitle "Only the team at [app name] sees it". The first time only, a sheet: "Only
  the team at [app name] sees what you put up. After the week closes a few frames are
  chosen, and those are shown to everyone on [app name]. One frame a week. You can take it down
  until this week closes." (The close is the week's real end, shown in the phone's own time
  wherever a time is shown.) The undo capsule appears after the sheet closes,
  never under it: "Up for Spotlight / Only the team at [app name] sees it". Once up, the item reads "Take it
  down from Spotlight". Putting up a different frame the same week swaps it: "Swap it into
  Spotlight", subtitle "Takes down your frame from Tuesday" (the day comes from the server's
  answer, never from a loaded post). Nothing else anywhere shows that a frame is up.
- **Frames that cannot go up** show the item disabled with its reason: a frame with people
  tagged ("Frames with people tagged can't go up"), a frame shot by someone else and shared to
  your page, a post from an earlier week. Covered accounts see no item at all.
- **Publish.** The strip in the feed: a band with a small light glyph in the avatar slot,
  "Spotlight", "the week of September 14", a "new" pill until seen, and a chevron; under it a horizontal
  row of the chosen frames at 118pt, 3:4, the handle under each. Tapping a frame fetches the post
  and opens it as the push route does (a frame deleted or hidden since reads "That photo isn't
  there anymore."). Tapping the band opens a sheet of past weeks, paged, one row per week.
- **Who can do what with a chosen frame.** Everyone signed in sees the photograph and its
  reactions and can react. Comments stay with the photographer's followers and tagged people, as
  today: a stranger opening a chosen frame sees the photo and the reaction bar, not the thread or
  the composer. Blocks apply both ways, always. The page grid and Chapters still follow the
  follower rule; a stranger visiting the page sees the shelf, not the grid.
- **The rest of the week.** The strip stays at the place it arrived, without the pill, and ages
  out with the seven-day window. It never moves while someone is reading: its place is decided at
  a reload, the boundary reload or "New posts", never live.
- **A week the team does not publish.** Nothing appears. It stays in the queue and can
  be published late; the strip is labelled with its own week.
- **Empty feeds.** A person who follows nobody still sees the strip above the first-run
  screen. It is the one place a newcomer meets other people's photographs.
- **The chosen.** One push, "Your frame is in Spotlight" / "Everyone on [app name] can see it
  now.", opening the week's sheet over the Feed tab (reliable on a cold launch, and after the
  strip has aged out). An Activity row with no actor, the light glyph in the avatar slot, "Your
  frame is in Spotlight", counted in the bell and the tab dot like every row. The gold Spotlight
  badge the first time, earned inside publish so it can never be missed, announced the way every
  badge is (the avatar dot, no push). A SPOTLIGHT shelf on their page above Chapters.
- **Taking it back after publish.** The photographer can take a published frame out ("Take it
  out of Spotlight", with a consequence line: it leaves the strip and your shelf, and the badge
  stays). The team can remove any frame. Deleting the post removes it everywhere.
- **The team at FLIM (the owner's admin panel).** A fifth queue in the web admin panel. It lists every closed, unpublished week
  with its count, newest first; the frames at 3:4 with handle and day; Choose / Chosen (six at
  most); flags on frames from the App Review account or from anyone in a block with the owner;
  "Publish to everyone" behind a confirm(), refused with zero chosen, a no-op on a second press.
  An ops push to the owner at 09:00 Eastern on the first morning after the week closes, with the
  count waiting.

## Decisions

| Decision | Answer | Why |
|---|---|---|
| Where Spotlight lives | One strip in the feed, placed at publish | The owner's rule: never as heavy as the feed |
| Who sees submissions | Only the team at FLIM | Nothing public until chosen |
| How many chosen | Three to six (enforced: at most six) | An event, and still one strip |
| When the team can choose | Only after the week closes | Stops a published frame being swapped or withdrawn underneath it |
| Late weeks | Any closed week can be published, labelled with its own week | A late choice never erases the week |
| Public reach of a chosen frame | The photograph, its reactions, and reacting | "Shown to everyone" is the feature |
| Comments on a chosen frame | Followers and tagged people only, as today | Comments were written for followers; strangers writing to people is the one new contact the feature would otherwise open |
| Tagged frames | Cannot be put up; tags cannot be added while a frame is up in the current week or chosen (a closed week's unchosen frame can be tagged again, and choose refuses tagged frames under a row lock) | A tagged friend never agreed to be shown to everyone |
| Frames shot by someone else | Cannot be put up | Credit and consent belong to the photographer |
| Page grid and Chapters for strangers | Unchanged, follower rule | The shelf is the public record, the rest of the page stays private |
| After publish | The photographer can take a frame out; the team can remove one; the badge stays | Publication is long-lived through the shelf, so there must be a way back |
| The mark on frames | None | The strip, the badge and the shelf carry it |
| Badge | Gold, earned once, never changes, not shown in any locked catalogue | The existing ratchet and the "discovered, never pushed" rule |
| Push route | `{t:"feed", week}` to every device | 1.5.x reads "feed" and ignores the rest; no per-device version lookup exists |
| Deadline for choosing | None | A late choice must not erase the week |

Cut from the first pass, deliberately: the header switch, the Spotlight view, the public grid of
submissions, the compose toggle, the "Up for Spotlight" pill, the Sunday reminder push, the
light on frames, the public week meta line.

## Edge cases and races, and what handles each

Server (from the SQL review):

1. **Strangers could not load a chosen frame** (the follower gate is server-side). A definer
   helper `spotlight_post_public(post, viewer)` is true for a chosen, unremoved entry in a
   published week, or for the owner on any live entry. It widens exactly three things: the post
   row read, the storage read of its bytes, and reactions. Comments, tags, page reads and the
   chapter functions keep the follower rule. The helper keeps EXECUTE for `authenticated`
   (revoking it on `is_blocked_either_way` once took production down).
2. **The owner could not see put-up frames** unless following their authors. Covered by the
   owner clause in the same helper; blocks still apply and are flagged in the queue.
3. **RLS recursion and early leaks** if the entries table had client policies. Both tables: RLS
   on, no policies, `REVOKE ALL FROM PUBLIC, anon, authenticated` (TRUNCATE is not governed by
   RLS). Every read and write goes through a definer RPC. `own_spotlight_entry` never returns
   `chosen_at`.
4. **Put back, swap back, and two phones racing** broke on `post_id unique` plus a soft
   withdraw, and a two-statement swap handed the loser a raw 23505. One row per (user, week):
   put-up is a single `INSERT ... ON CONFLICT (user_id, week_key) DO UPDATE ... WHERE chosen_at
   IS NULL`, so concurrent calls queue and the last wins with no error. Taking down deletes the
   row.
5. **Choose or publish on an open week.** Put-up and take-down accept only the current week;
   choose, unchoose and publish accept only closed weeks. At the boundary instant the row lock
   decides and the loser reports a named refusal.
6. **Publish pressed twice; choose racing publish.** Every owner write upserts the week row,
   locks it `FOR UPDATE`, then checks. Publish is `UPDATE ... WHERE published_at IS NULL`; a
   second press returns `already_published`. The seventh choose returns `limit`.
7. **Someone else's shot shared to your page.** Put-up requires the caller's own photo, not only
   the caller's own post.
8. **The admin panel calls every queue with no arguments.** `list_spotlight_queue(p_week_key
   date DEFAULT NULL)`.
9. **Missed weeks.** Listed in the queue; publishable late; the push copy has no "this week".
10. **The anon key reading results.** EXECUTE revoked from PUBLIC and anon on every function;
    each read returns nothing when `auth.uid()` is NULL; each read ANDs not-hidden, blocks both
    ways, and `covered_post_visible`.
11. **Inferring who put a frame up.** A post that is not yours returns the same `not_found` as
    one that does not exist, checked first; conflicts only ever hit the caller's own row.
12. **The week key.** `(date_trunc('week', (p_ts AT TIME ZONE 'America/New_York') - interval
    '4 hours'))::date` with `p_ts timestamptz`, STABLE. DST changes fall on Sunday 02:00 and never
    meet the Monday 04:00 boundary. The client never does this math: the server returns the
    week's bounds.
13. **A forged or null `posts.created_at`.** `pin_post_paths` pins it to `now()` on insert;
    put-up refuses a null.
14. **The Sunday-night edge.** A post from Sunday 23:50 can go up until Monday 04:00 Eastern; an
    undo after that returns `week_closed`, which the capsule says in words.
15. **CHECK constraints never change in production** when written inline. The migration and
    `schema.sql` both drop and re-add the badge and usage-event CHECKs as full supersets built
    from the live definitions, and update the inline lists for fresh bootstraps. Without this the
    four counters would silently read zero.
16. **A badge that depends on when the ratchet runs.** Publish ratchets each chosen person inside
    its transaction; `earned_at` is the publish time; only the new row is unseen.
17. **Push gaps.** A `push_sent` flag bounds the poll; hidden or removed frames are skipped and
    marked; a person with no device gets the Activity row; delivery is at-least-once through the
    existing ledger and lease.
18. **Version-aware routing** was impossible per device. Route `{t:"feed", week}` for everyone.
19. **The owner's morning push across DST.** Cron `0 13,14 * * 1` calling a function that runs
    only at 09:00 Eastern and only once per week, through `ops_alerts`.
20. **Copied paths would go stale and confuse the storage sweeps.** No path columns; paths come
    through the posts join at read time.
21. **Row caps.** History reads return one row per week with the frames as a jsonb array, paged
    by `p_before` and `p_limit` (12).
22. **No way out after publish.** `removed_at`, an owner remove, and a photographer take-out.
23. **Captions and tags going public.** Tagged frames are refused; the caption stays the
    photographer's and editable, and shows to everyone on a chosen frame (stated in the
    first-time sheet's audience line).
24. **A covered window laid over a chosen frame later.** It drops from the strip for others; the
    badge stays; the queue flags and refuses covered frames.
25. **Deletion mid-week or after choosing.** Cascades; publish reports the real count; a
    published week with no visible frames shows nothing.
26. **The App Review account.** Flagged in the queue.
27. **Cost of the wider rule on every post read.** The follow check runs first; the helper is
    two index lookups; a partial index on chosen entries.

Client (from the client review):

28. **The strip in the feed's arrays would corrupt the feed.** It never enters `feed.feed` or
    `units` (dedupe, ledger, straddle completion, seeding and index-based pagination all depend
    on them). A separate `spotlightWeeks` model; a pure placement function over `(units,
    publishedAt, hasMoreFeed)`; rendered inside the neighbouring row; not rendered while its
    place is below an unloaded page.
29. **A row moving under the reader.** Placement is snapshotted at the same moments as the
    ledger; seen is marked by scroll visibility, never `onAppear`; an unseen strip sits above a
    caught-up block at the top.
30. **Account switches.** Every new write after an await is guarded by `AccountEpoch` plus its
    own generation; all four new caches are added to `resetForAccountChange`.
31. **An undo revert landing in the next account (a live bug today).** On an expired session
    the flush runs after the session is gone, the commit fails, and the revert restores the old
    account's posts into the new feed. Fixed once in `UndoCenter`: `Staged` captures the epoch and
    `perform` skips the revert and the failure notice if it moved. This ships first, as its own
    commit, independent of Spotlight.
32. **Put-up, swap and take-down racing on a slow connection.** A per-account write queue and a
    revision token, the same pattern as reactions, so a late failure never reverts a newer state.
33. **The menu showing the wrong item.** Three states from the server, with the week's bounds;
    the item is hidden while unknown (showing "Put it up" then would silently swap); refetched on
    reload, on becoming active and after any own-post delete; put-up returns what it swapped out.
34. **Image cache poisoning.** The strip's cache key is exactly the path it signed (the thumb),
    never the card key; never `storagePath` at card size.
35. **Tapping a frame that is gone.** Fetch first, then open; deletes and blocks prune the strip,
    the shelf and the sheet too; a week whose frames are all filtered hides.
36. **The Activity row has no actor.** A new actor-less row kind, counted in the unread count so
    the bell and the dot agree.
37. **The badge dot.** Earned inside publish; the client also refreshes the unseen count when
    the push is opened.
38. **Empty-feed screens render nothing.** The strip renders above the first-run and
    never-posted screens.
39. **Week labels in other zones.** `week_key` is an opaque string; the label comes from the
    string, not a midnight-UTC date; the close is shown in the phone's own time.
40. **The first-time sheet hiding the undo.** Stage the undo after the sheet dismisses; in-flight
    guard on its button; the first-time flag per account in an injectable store.
41. **Pop-in above an already drawn feed.** Spotlight loads alongside the feed in `reload` and is
    in hand before the ledger snapshot; background refreshes never change the strip.
42. **History paging.** Keyset on `week_key` with a limit; one batch of signed URLs per page.
43. **Accessibility.** Frames fixed at 118pt (chrome); handles scale and truncate; the band is
    one button ("Spotlight, week of September 14, new"); each frame reads "Photo by @handle".
44. **Copy that was untrue, and copy the owner asked to change.** The people choosing are "the
    team at [app name]", never "the owner" or "the editor". Spotlight is framed as the week's, never
    as Monday's: "the week of September 28" wherever a week is named; "until this week closes" and
    any shown time are the week's real close in the person's own time;
    "this week's" leaves the push.

## The contract (what v2 inherits)

**Tables.** `spotlight_weeks` (week_key date PK, the Monday; published_at timestamptz NULL;
note text NULL). `spotlight_entries` (id uuid PK; post_id uuid UNIQUE REFERENCES posts ON DELETE
CASCADE; user_id uuid REFERENCES users ON DELETE CASCADE; week_key date; put_up_at timestamptz;
chosen_at timestamptz NULL; removed_at timestamptz NULL; push_sent boolean NOT NULL DEFAULT
false; UNIQUE (user_id, week_key)). Taking a frame down deletes the row. Partial index on
(week_key) WHERE chosen_at IS NOT NULL. No path columns. Strip order: chosen_at, then post_id.

**Visibility.** Both tables: RLS on, no policies, REVOKE ALL FROM PUBLIC, anon, authenticated.
Every function SECURITY DEFINER, search_path pinned, EXECUTE revoked from PUBLIC and anon, a NULL
auth.uid() refused, and each read ANDs not hidden, blocks both ways and covered_post_visible.
`spotlight_post_public(p_post_id, p_viewer)` widens the posts SELECT policy, the storage read
policy and the reactions policies only; comments, tags, page and chapter reads keep the follower
rule. The helper keeps EXECUTE for authenticated.

**Week.** `spotlight_week_key(p_ts timestamptz)` as in item 12. Put-up and take-down: current
week only. Choose, unchoose, publish: closed weeks only.

**RPCs.** `put_up_for_spotlight(p_post_id)` (own post and own photo, no tags, not hidden, not
covered, created this week; one upsert; returns the entry and what it replaced).
`withdraw_from_spotlight(p_post_id)` (current week, not chosen). `take_out_of_spotlight(p_post_id)`
(the photographer, after publish; sets removed_at). `own_spotlight_entry()` (week_key,
week_starts_at, week_closes_at, the live entry's post_id, photo_id, post_created_at, put_up_at;
never chosen_at). `spotlight_published(p_before date DEFAULT NULL, p_limit int DEFAULT 12)` and
`spotlight_frames(p_user_id, p_before, p_limit)` (one row per week, frames as jsonb). Owner only,
is_owner() inside each body, week row locked FOR UPDATE: `list_spotlight_queue(p_week_key date
DEFAULT NULL)`, `choose_spotlight_entry(p_post_id)` (six at most),
`unchoose_spotlight_entry(p_post_id)`, `publish_spotlight_week(p_week_key)` (idempotent, refuses
zero, ratchets badges), `remove_spotlight_entry(p_post_id)`. Named refusals: not_found,
week_closed, week_open, already_published, hidden, covered, tagged, not_photographer, limit.
Adding a tag to a post that is up or chosen is refused with `in_spotlight`.

**Posts.** `pin_post_paths` pins `created_at := now()` on insert.

**Pushes.** `spotlight_chosen` polls chosen, unpushed entries in published weeks; the
`push_deliveries` ledger keyed (spotlight_chosen, week_key, user_id); skips and marks hidden or
removed frames; route `{t:"feed", week:"<week_key>"}`. The owner's morning ops push through
`ops_alerts`, cron `0 13,14 * * 1` gated to 09:00 Eastern.

**Badge and counters.** `spotlight` added to the badge CHECK and to `_ratchet_badges`; the
badge and usage-event CHECKs replaced as full supersets; counters `spotlight_put_up`,
`spotlight_withdraw`, `spotlight_strip_open`, `spotlight_weeks_open`, logged on tap.

**Client.** `PushDestination` parses `week` as a rider on `feed` and opens that week's sheet.
Activity gains an actor-less `spotlight` kind. `ProfileBadgeKind.spotlight`, gold, not earnable
in any locked list.

## Build order

0. **The UndoCenter epoch fix** (swift-builder), its own commit, with a test that bumps the epoch
   between stage and a failing commit. It fixes a live bug today.
1. **Server** (supabase-guardian): the migration, the schema ledger, the bootstrap proof of every
   item above; the push kind and the cron; the admin queue in `web/admin.html`. Before writing
   the CHECK supersets, read the live constraint definitions (a production SELECT, with the
   owner's go-ahead). Apply, redeploy `send-social-push`, deploy the site.
2. **Client** (swift-builder): the model, placement function and strip; the past-weeks sheet; the
   menu states, the first-time sheet, the write queue and the undo; the Activity row, the badge,
   the shelf, the push route; the gated comments on strangers' chosen frames. New files need
   `xcodegen generate` and a check that the test count moved.
3. **Release** (release-captain): 1.6.0 on TestFlight through one real week with the owner
   publishing; then the App Store; then `latest_version` 1.6.0.

## What proves it

- **Bootstrap database:** a stranger can read the row, sign the bytes and react on a chosen
  frame in a published week, and is refused its comments, an unchosen frame, an unpublished
  week, and anything across a block either way; two concurrent put-ups end with one entry and no
  error; put back and swap back work; choose on an open week, publish twice, a seventh choose,
  a tagged put-up and a shared-shot put-up are refused by name; the week key at Monday 03:59:59
  and 04:00:00 in EDT and EST and on 2026-11-01 at 01:30 in both offsets; the badge is earned at
  publish; cascades on post and account delete; the CHECK supersets accept every existing id.
- **Unit tests:** the placement function (empty, older than every unit with and without more
  pages, caught-up at the top and after a unit, seen and unseen); menu eligibility from server
  bounds; `PushDestination.parse` with and without the rider; week labels pinned to Los Angeles
  and Makassar; the UndoCenter epoch rule; the write queue's revision rule. Stores injected,
  calendars pinned.
- **sim-verifier RELEASE** with the stale-write audit on every new FeedService path, and a
  Release build (every fixture stays behind DEBUG).
- **Device, on the TestFlight week:** two accounts, one following the chosen author and one not
  (thumbnails, detail, reactions for both; comments only for the follower); a deleted frame; a
  block from the detail; the strip never jumps when marked seen; a cold-launch tap on the push;
  a 1.5.x device receiving it; a Sunday-night post on Monday morning; put up then sign out
  within five seconds; put up then swap on Network Link Conditioner; AX3 with VoiceOver.
- **After release:** people putting a frame up per week, strip opens per active day, reactions on
  chosen frames in the 48 hours after publish, captures per active day not falling.
