# FLIM 1.6: the Contact Sheet. Prompt for the builder session (2026-09-25)

Paste everything below the line into a Claude Code session opened on `main` at or after
`fe340e6`. The session builds, verifies and commits; it does not design. The design is settled
in the plan this prompt is built on (the Contact Sheet plan of September 22,
claude.ai/code/artifact/8f6b17bb-94d1-4370-bf06-31f3141c678d, written for a 1.5.5 that never
shipped) and in `docs/prompts/CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-24.md` §10. Three things in
that plan are stale against today's code and are corrected here (section 3).

---

## 0. What you are building, in one breath

One sheet a week, shared by everyone on FLIM. It opens Monday at 04:00 Eastern (the app's day
boundary) and closes Sunday night. Each person may put one frame on it, from anything they posted
that week. Monday morning the owner, from the admin page, circles a handful with a red-orange
grease pencil. Circled stays circled. Nobody votes, nothing is counted, nothing is ranked; frames
sit in the order they went up. Past sheets stay, one per week, like a box of sheets. Tapping a
frame opens it exactly as the feed does. This is 1.6's headline and its only feature.

**On the name.** The owner described this feature as "Spotlight". His own briefs of September 19
and 20 ban that word (Instagram and TikTok own it, and it is not film) and name the feature
**the Contact Sheet**, verb **circled**, in copy usually just "the sheet". This prompt uses those
names. Every user-facing string is in section 9, in one place, so a rename is one pass. Do not
rename anything until the owner says so in his own words; if he does, rename the strings and
nothing else (table, RPC and type names stay).

## 1. Read these first, in this order

1. `docs/COPY.md` (Post versus Share; page not feed; no em dashes; no exclamation marks).
2. `.claude/rules/agent-completion.md` (the handoff format you end every stage with).
3. `docs/prompts/CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-24.md` §10 and `docs/UX_AUDIT_2026-09-24.md`
   (what the sheet is for and what it must never become).
4. `supabase/schema.sql` around lines 1260 to 1280 (posts), 1921 to 1962 and 2516 to 2527
   (`owner_user_id`, `is_owner`), 2034 (`is_blocked_either_way`), 7439 to 7470
   (`can_see_posts_of`, `post_visible_to`, the posts policy), 7146 (`push_deliveries`), 7199
   (`ops_alerts`), 9353 to 9416 (the cron block), 10269 to 10300 (`chapter_timezone` and the
   `p_timezone` pattern), and the storage policy for the `photos` bucket that calls
   `post_visible_to` (grep it).
5. `supabase/migrations/2026-09-16_post_seen.sql` and `2026-09-23_record_posts_seen.sql` (the
   table and function shapes), `2026-09-15_post_release_ops.sql` (a migration that ships a cron).
6. `scripts/schema_bootstrap.sh` (the schema must build twice; `--keep` leaves a database on
   54329 for your checks).
7. `supabase/functions/send-social-push/index.ts`: `FlimRoute` (138 to 144), `postVisibleTo`
   (273), `notify()` (305), the lease (687, 1364), the `post_tags` block (881) which is the shape
   you copy, the `ops_alerts` drain (1316).
8. `Flim/Services/PushDestination.swift`, `Flim/Views/Main/MainTabView.swift` 197 to 207 and 447
   to 553 (routing), `Flim/Models/Social.swift` 51 to 61 and 152 to 212 (`Post` paths, `ProfileRoute`,
   `FeedItem`, `ActivityItem.Kind`).
9. `Flim/Views/Rolls/RollsView.swift` (the scroll order the card goes into), `Flim/Views/Components/
   ConsequenceSheet.swift` (`RollConsequence`, `ConsequenceSheet`), `Flim/Services/UndoCenter.swift`
   (`stage(title:subtitle:failureText:revert:commit:)`, the five-second window, commit false runs
   revert), `Flim/Services/AccountChange.swift` (`AccountEpoch`), `Flim/Services/TabSignals.swift`,
   `Flim/Services/NewAccountIntro.swift` (`Surface`), `Flim/Views/Components/FirstVisitLine.swift`.
10. `Flim/Views/Feed/PostDetailView.swift` 208 to 226 and `Flim/Views/Feed/FeedUnitCard.swift` 609
    to 627 (the two identical own-post overflow menus), `Flim/Views/Feed/UserPageView.swift` (the
    grid cell), `Flim/Views/Feed/DayContactSheet.swift` (three columns, 2pt gutters: the grid you
    reuse), `Flim/Views/Profile/ChapterShelfView.swift` (the horizontal strip pattern),
    `Flim/Views/Darkroom/PhotoGridCell.swift` 340 and 444 (`CachedImage`, `DiskImageCache` keys),
    `Flim/Services/FeedService.swift` 1448 (`createPost`), 1554 (`dropPosts(forDeletedPhotoIds:)`),
    1799 and 1812 (`signedURL(s)`), 2074 (`fetchActivity`).
11. `Flim/Models/FeedUnit.swift` 29 to 40 (`dayBoundaryHour`, `dayKey`), and `FlimTests/FeedUnitTests.swift`
    for how a fixed calendar is pinned in a test.
12. `Flim/Services/BrandedExport.swift` (the two red-orange inks; `flatInk` #E0530A becomes
    `FlimTheme.pencil`), `Flim/Views/Theme.swift`.
13. `Flim/Views/Feed/FeedPreviewDemoHost.swift` and `Flim/ContentView.swift` 32 to 52 (the demo-host
    pattern), `FlimUITests/FeedCommentsReturnUITests.swift` (the UI test pattern).
14. `web/admin.html` 386 to 389, 442, 480 to 595, 626 to 637, 1133 to 1205 (nav, titles, `rpc`,
    `card`, the reported-photos card, `act`, `counts`, `load`), `web/vercel.json` (the CSP).
15. `project.yml` 74 and 147 (`MARKETING_VERSION` in both targets), `docs/APP_STORE.md` 139 and
    321 to 327 (What's New; arming the nudge), `.github/workflows/ios-testflight.yml`.
16. `docs/PENDING.md` lines 1 to 30 (how a done entry and APPLIED are written) and 2117 to 2129
    (parked items, so you do not re-propose one).

## 2. Decisions already made

These are the September 22 plan's recommendations, adopted as defaults. The owner vetoes any of
them in one line; you list them back to him at the end of stage A, before anything a person can
see is built.

1. Name: the Contact Sheet, the sheet, circled.
2. Where it lives: the top of Rolls, above the follow-up invite cards, below the first-visit
   line. Not the feed. The Rolls header ledger gains one Sunday-only state.
3. Taking a frame off: allowed at any time, on any week, circle included (the circle goes with
   it). A person's control over who sees their photograph outranks the mark.
4. Reactions and comments on a sheet frame's page from non-followers: yes. It is a post the
   person chose to widen; nothing about them reaches the sheet.
5. The sort deck's Post confirmation: unchanged in 1.6. The two entry points are the card's
   "Put one up" picker and the own-post overflow menu.
6. The Darkroom grid: no circle mark in 1.6 (its corner slot already carries two states).
7. The owner is a person on FLIM too: he may put a frame up; the circle RPC refuses his own.
8. How many circles: his eye, some weeks one, never a quota anywhere.
9. Not in 1.6: an Activity row for "circled" (the push and the Rolls dot carry it; an Activity
   kind touches six exhaustive switches and is its own change), any circle on exports, any count
   anywhere, any sort control on the sheet.

## 3. Corrections to the September 22 plan

Read the plan for its intent and its strings; build from this document where they differ.

- **The version is 1.6, not 1.5.5.** `MARKETING_VERSION` becomes `"1.6"` in both targets.
- **The admin page cannot show a photograph today.** There is no `<img>` and no signed URL in it,
  and `web/vercel.json`'s Content-Security-Policy is `img-src 'self' data:`. The Sheet panel needs
  thumbnails to circle by. Do it by fetching the signed URL to a blob under `connect-src` (which
  already allows the Supabase host) and setting the image from an object URL; do not widen
  `img-src` to the storage host unless the fetch-to-blob path proves impossible. Revoke object
  URLs on refetch.
- **The push lock takes and returns a token.** `acquire_push_lock(p_name, p_seconds)` returns a
  UUID lease and `release_push_lock(p_token)` runs in `finally` (index.ts 687, 1364). Your blocks
  live inside that bracket and the 200s run budget; you add no lock.
- **The sort deck does not open `ShareToFeedSheet`.** It uses `SortDeckComposeSheet`. Irrelevant
  for 1.6 since nothing is added at Post, but do not go looking for it there.
- **`FeedUnitCard` does not open `PostDetailView`.** It is an inline pager. The own-post overflow
  menu exists twice, `PostDetailView.swift` 208 to 226 and `FeedUnitCard.postActions` 609 to 627;
  the two new items go in both, before the destructive Delete.
- **Name collision.** `DayContactSheet` and `ChapterContactSheet` already exist and mean other
  things. Your types are `SheetWeek`, `SheetEntry`, `Sheet`, `SheetCardState`, `SheetService`,
  `SheetCard`, `SheetView`, `SheetFrame`, `SheetPickerSheet`, `GreasePencilCircle`. Never
  `ContactSheet*` in code.
- **Reports are plain inserts, not an RPC**, and two distinct reporters auto-hide a photo and its
  posts by trigger. A hidden post leaves the sheet because the read RPC filters `hidden`.

## 4. Rules that must hold, in every stage

- No em dashes anywhere: copy, comments, commit messages, docs. No exclamation marks in copy.
- The read RPC never returns a count. The sheet has no sort control. A review that finds either
  rejects the change.
- Every client write after an `await` is guarded by the `AccountEpoch` captured before the first
  await, one guard per write, the way `RollService` and `FeedService` do it. `SheetService`
  resets on account change with the other services in `ContentView`.
- Every per-account key in `UserDefaults` carries the userId, the way `NewAccountIntro` does.
- Undo-first: the server write runs only when the capsule's window closes; commit false runs
  revert and shows the failure line. No modal confirmations except the consequence sheet, whose
  confirm label is never a bare verb.
- Migrations are rerunnable (`IF NOT EXISTS`, `DROP POLICY IF EXISTS`, `CREATE OR REPLACE`, `DROP
  FUNCTION` when a return shape changes), folded to the end of `schema.sql` under the standard
  header, and proven by `schema_bootstrap.sh` building twice.
- Owner-only writes: `IF NOT public.is_owner() THEN RAISE EXCEPTION 'owner only'; END IF;`.
  Owner-only reads return empty. Every function: `REVOKE ALL ... FROM PUBLIC, anon; GRANT EXECUTE
  ... TO authenticated`.
- The week key is computed once, in SQL, and mirrored in Swift with a fixed Eastern calendar.
  Never `Calendar.current` for the week. The copy says "Sunday night" and "Monday morning", never
  a clock.
- Photographs are 3:4, never cropped, never with anything drawn over them except the circle on
  the sheet and the post page.
- Nothing fails silently. Offline, a put-up or take-off is not queued: the capsule's commit
  returns false, the optimistic state reverts, the failure line shows.
- One commit per stage, in the repository's voice (a sentence about what changed for the person,
  never a version number or a model name). The suite is green before each commit. Push when the
  owner says, or as the repository's practice has been for this session.
- Agents: `supabase-guardian` for stage A's schema; `code-reviewer` before the visibility
  widening is committed (it changes who can read a post and its bytes); `swift-builder` for B to
  D; `flow-critic` on every string before stage C is committed; `sim-verifier` at FEATURE depth
  after B and after D; `docs-scribe` for the docs; `release-captain` for stage E's TestFlight.
  Never use `production-analyst` to write.

## 5. Stage A: the backend

Migration `supabase/migrations/2026-09-2N_contact_sheet.sql` (today's date), folded into
`schema.sql`, PENDING entry with APPLIED once the owner has run it.

**A1. The week key.**

```sql
create or replace function public.sheet_week_key(p_at timestamptz default now()) returns date
language sql immutable as $$
  select date_trunc('week', (p_at at time zone 'America/New_York') - interval '4 hours')::date
$$;
```

ISO weeks start Monday; the four-hour shift makes a 01:00 Monday post belong to Sunday's week.
Eastern for everyone, documented in the migration comment the way `usage_events.day` is. Test on
the kept database at Sunday 23:59, Monday 03:59, Monday 04:00 and the November DST Sunday.

**A2. The table.**

```sql
create table if not exists public.sheet_entries (
  week_key         date        not null,
  user_id          uuid        not null references public.users(id) on delete cascade,
  post_id          uuid        not null references public.posts(id) on delete cascade,
  put_up_at        timestamptz not null default now(),
  circled_at       timestamptz,
  circle_push_sent boolean     not null default false,
  tag_push_sent    boolean     not null default false,
  primary key (week_key, user_id),
  unique (post_id)
);
create index if not exists sheet_entries_week_idx on public.sheet_entries (week_key, put_up_at);
alter table public.sheet_entries enable row level security;
```

SELECT to authenticated, filtered by the read RPC in practice; no direct INSERT, UPDATE or DELETE
grants. Every write goes through the RPCs, which is where the one-per-week and this-week rules
live. Withdraw deletes the row. Swap is delete-and-insert in one transaction keeping `put_up_at`.
Circle is an update. No `withdrawn_at`: the delivery ledger already prevents a second circled push
if a frame is taken off and put back.

**A3. Visibility, the one hard part.** The posts policy is `NOT hidden AND NOT blocked AND
covered_post_visible AND post_visible_to(viewer, id, author)`, and the `photos` bucket's storage
policy calls the same `post_visible_to`, so one change widens both the row and the bytes:

```sql
-- inside post_visible_to, one more disjunct:
or exists (select 1 from public.sheet_entries e where e.post_id = p_post_id)
```

Two consequences, handled in the same migration. The `users` SELECT policy admits your own row
and co-members only, so a non-follower opening a sheet frame could not read the author's handle
or avatar: the read RPC (SECURITY DEFINER) returns handle and avatar path itself, and the users
policy gains "or the author has a frame on any sheet" so the post page and the person's page
work. Reactions and comments from non-followers on a sheet frame's page are then possible
because their insert policies check post visibility; that is decision 4. Email and invite code
are in no client grant and stay that way. Cost: one indexed EXISTS per policy check, the same
shape as the tag clause. Run `code-reviewer` on this before committing, and probe on the kept
database: a non-follower can read a sheet post and its feed rendition, cannot read a non-sheet
post by the same author, and cannot read the author's email.

**A4. The RPCs.** All SECURITY DEFINER with `SET search_path = public`, all granted to
authenticated only.

| Function | Who | Does |
|---|---|---|
| `put_on_sheet(p_post_id uuid)` | caller | Checks the post is the caller's, not hidden, and `sheet_week_key(post.created_at) = sheet_week_key(now())`; deletes the caller's existing entry for the week keeping its `put_up_at` for the new row; inserts. Raises `sheet_closed` when the post's week is not the open week, `not_this_week` when the post is older. Both become toasts. |
| `take_off_sheet(p_post_id uuid)` | caller | Deletes the caller's row for that post, any week. |
| `sheet(p_week date default sheet_week_key())` | anyone signed in | Entries for the week with `post_id`, `feed_path`, `thumb_path`, `storage_path`, `taken_at`, author `user_id`, `username`, `avatar_path`, `put_up_at`, `circled_at`, `mine`; filters hidden, blocked either way, covered; ordered by `put_up_at`. No count column, ever. |
| `sheet_weeks()` | anyone signed in | Week keys with at least one visible entry, newest first, with `has_circles boolean`, for the pager and the card's last-week states. |
| `circle_sheet_entry(p_post_id uuid, p_on boolean)` | owner | Owner guard; refuses the owner's own post; sets or clears `circled_at`; clearing also resets `circle_push_sent`. |
| `admin_sheet(p_week date)` | owner | The week's entries with thumbnail paths for the admin panel; empty for anyone else. |

**A5. Events.** Add `sheet_entry` to `activation_events`' CHECK list the way the last event was
added, recorded on a person's first ever put-up. Add `sheet_put_up` and `sheet_viewed` to usage
events.

**A6. Checks on the kept database, all must pass before the commit:** put up twice replaces and
keeps the spot; a last-week post refuses with `not_this_week`; a post from 03:30 Monday belongs
to the previous week; take off any week works; circle as a non-owner raises; circle the owner's
own post raises; delete the post and the row is gone; block the author and the row is gone from
`sheet()` for the blocker and the blocked; the bootstrap builds twice.

**A7. Docs.** The privacy page's Sharing list gains the line in section 9. PENDING gets the done
entry. End the stage with the completion contract and the nine defaults from section 2 listed
for the owner's veto.

## 6. Stage B: the read side

- `Flim/Models/SheetWeek.swift`: pure. `key(for: Date)`, `closesAt(key)`, `title(key)` ("Week of
  September 14", always the Monday), `isOpen(now:)`, `isSunday(now:)`, `isMondayBeforeCircles(now:)`,
  with a fixed `America/New_York` Gregorian calendar. Tested at the four boundaries.
- `Flim/Models/Sheet.swift`: `SheetEntry`, `Sheet`, decodable from the RPC; `displayPath` and
  `cardPath` like `Post`'s.
- `Flim/Models/SheetCardState.swift`: the pure rule for the six card states (section 9), tested
  as a truth table.
- `Flim/Services/SheetService.swift`: `@MainActor @Observable`. `current`, `weeks`, `myEntry`,
  `error`; `load()`, `load(week:)`, `putUp(postId:)`, `takeOff(postId:)`; `AccountEpoch` before every
  write; `resetForAccountChange()` wired in `ContentView` beside the others; signed URLs through
  `feed.signedURLs(for:)` batched per week.
- `Flim/Views/Rolls/SheetCard.swift`: the card, at the position in decision 2. A strip of the
  sheet's first frames as tiny positives when there are any (the feed's strip geometry, 30pt
  frames, 2pt gap), never a number. `NavigationLink` into `SheetView`.
- `Flim/Views/Rolls/SheetView.swift`: full screen. Header "Week of September 14" and one state
  line. Three columns at 375pt with 2pt gutters like `DayContactSheet`, oldest first. Under each
  frame in the rebate the handle in the stamp face; under yours, "you". Horizontal paging between
  weeks with fixed geometry, newest first, older to the right. `FirstVisitLine(surface: .sheet)`
  once. Tapping a frame appends `FeedItem(post:author:)` to the stack the way `MainTabView.route`
  does for a post; the sheet has no viewer of its own. Loading is a skeleton of the grid, not a
  spinner. Failure is `ErrorState` with retry.
- `Flim/Views/Components/SheetFrame.swift`: the 3:4 positive with the rebate hairline, the handle,
  the `GreasePencilCircle` overlay when circled.
- `Flim/Views/Components/GreasePencilCircle.swift`: a `Canvas` path seeded from the post id, so the
  same frame wobbles the same way everywhere; slightly off-round, stroke starting and ending just
  past each other; `FlimTheme.pencil` (#E0530A); one draw-on animation on first appearance per
  launch, static after, none under Reduce Motion; sizes to its container so it serves 120pt and
  full width.
- `TabSignals`: the Rolls dot is also on when your frame was circled and you have not opened that
  week's sheet since (a per-week, per-user key, seeded from `circled_at`).
- `NewAccountIntro.Surface.sheet` with its one line.
- Demo host: `-sheetPreviewDemo` in `ContentView` under `#if DEBUG`, fixtures with deterministic
  UUIDs, images planted in `DiskImageCache` by path, every card state and a circled sheet
  reachable by launch argument. A UI test in `FlimUITests` that screenshots each card state and
  the circled sheet, run on demand like `ShareSheetUITests`.
- `sim-verifier` at FEATURE depth on the demo host: every state, 375 and 430pt, AX3, VoiceOver
  labels on the card, the frames and the circle ("Circled" is read; the circle is never the only
  signal, the meta line is there too).

## 7. Stage C: the write side

- `Flim/Views/Rolls/SheetPickerSheet.swift`: this week's posts, three columns, newest first, title
  and subtitle from section 9; the empty state when nothing was posted this week. Taps into the
  consequence sheet.
- `RollConsequence` gains `.putOnSheet(tagged: [String])` and `.replaceOnSheet`, rendered by the
  existing `ConsequenceSheet`.
- The two own-post overflow menus gain "Put it on the sheet" (post from the open week, not yet up
  or a different frame is up) or "Take it off the sheet" (this post is up, any week), before
  Delete.
- After confirm, the undo capsule through `UndoCenter.stage` with the strings in section 9;
  optimistic state in `SheetService.myEntry`; commit calls the RPC and returns whether it landed;
  revert restores the previous `myEntry`. The two refusals arrive as toasts from the RPC's error
  codes.
- Swap: the consequence copy names it; the old frame comes down in the same commit.
- The Rolls header ledger's Sunday state.
- `flow-critic` reads every string against `docs/COPY.md` before the commit.

## 8. Stage D: pushes, marks, the owner's Monday

- `send-social-push`: three blocks in the shape of the `post_tags` block, each reading rows with
  a `*_push_sent = false` flag, calling `notify()` per recipient with a source key, marking only
  settled rows. `sheet_circled` reads `circled_at not null and not circle_push_sent`, source
  `sheet_circled:<post_id>`. `sheet_tagged` reads `not tag_push_sent` joined to `post_tags`, source
  `sheet_tagged:<post_id>:<user_id>`. `sheet_closing` runs inside a Sunday 18:00 to 18:04 Eastern
  window (the scanner runs every two minutes) to people with a post this week and no entry,
  source `sheet_close:<week>` so it can never go twice. `FlimRoute` gains `t: "sheet"` with `week`
  and optional `id`. The daily digest is untouched.
- The Monday 08:00 Eastern owner line through `ops_alerts`, inserted by a cron in the migration
  from stage A (add it there now, guarded like the others): "12 frames on last week's sheet, none
  circled yet." Only when there are frames and no circles.
- `PushDestination.sheet(week: Date, postId: UUID?)`: `parse`, `wireValue`, and `MainTabView.route`
  (tab 2, `rollsPath = []`, push `SheetView` for the week, scroll to the post). Cold launch through
  `PendingPushDestination` works without changes if `wireValue` round-trips; test it.
- The post page: the circle in the frame's corner and the meta line "Circled, week of September
  14." under the handle when circled. The person's page grid: a smaller circle in the corner at
  120pt, no line.
- The admin panel: a "Sheet" nav item and count, TITLES entry, `counts()`, both arrays in `load()`.
  The panel shows the most recent closed week: title "Week of September 14", the frames as 3:4
  thumbnails via fetch-to-blob (section 3), each with `@handle`, the day it went up, and one
  button, Circle or Uncircle, through `act(c, "circle_sheet_entry", {p_post_id, p_on})`, then the
  refetch. A week selector for older weeks. Empty: "Nobody put a frame on this one." All strings
  through `textContent`. Deploy with `cd web && vercel --prod --yes` and verify the served bytes.
- Optional, if the day allows: a `circled` badge through the ratchet (`earned_badges` CHECK list,
  `_ratchet_badges` predicate over `sheet_entries.circled_at`, `ProfileBadgeKind.circled` with its
  copy). Badges are discovered, never pushed, so nothing else changes.
- `sim-verifier` at FEATURE depth on a device or simulator with a real account: put up, swap,
  take off, the push landing on the sheet from cold and from live, the dot clearing on open.

## 9. Every string, in one place

Sentence case; periods where the siblings have them; "Week of September 14" always names the
Monday; never "submit", "entry", "winner", "selected", "featured", "spotlight".

| Where | String |
|---|---|
| Card title | This week's sheet |
| Card, Sunday title | The sheet closes tonight. |
| Card lines, by state | Open, empty: Nothing on it yet. One frame each, from this week's posts. · Open, others up: Open until Sunday night. · Open, yours up: Your frame is on it. Open until Sunday night. · Sunday: One frame each, from this week's posts. · Monday before circles: Nothing on it yet. Last week's sheet is closed; the circles come this morning. · Monday and Tuesday after: Nothing on it yet. Last week's circles are in. |
| Card buttons | Put one up · See the sheet · See last week |
| Rolls header ledger, Sunday | sheet closes tonight |
| Sheet title | Week of September 14 |
| Sheet state lines | Open until Sunday night. · Closes tonight. · Closed Sunday night. The circles come Monday morning. · Circled Monday morning. · Closed Sunday night. |
| Sheet empty | Nothing on the sheet yet. One frame each, from this week's posts. Yours could be first. · Nobody put a frame on this one. |
| Rebate under a frame | @handle · you |
| First visit line | One sheet a week. Everyone puts up one frame. A few get circled. |
| Picker | Put one on the sheet · From what you posted this week. · Nothing posted this week yet. Post a photo first. |
| Post menu | Put it on the sheet · Take it off the sheet |
| Consequence, first | Put it on the sheet? · Everyone on FLIM can see it there, not only your followers, for as long as it's on the sheet. People tagged in it are told. · Put it on the sheet · Not this one |
| Consequence, swap | Replace your frame? · One frame a week. This one takes the other's place, and keeps your spot on the sheet. · Replace it · Keep the other |
| Undo capsules | On the sheet. / Everyone on FLIM can see it there. · Off the sheet. / Back to your followers only. |
| Failures | Couldn't put it on the sheet. Check your connection and try again. · Couldn't take it off. Check your connection and try again. · The sheet is closed for this week. · That photo isn't from this week. |
| Post page meta | Circled, week of September 14. |
| Pushes | Your frame was circled. / On the sheet for the week of September 14. · The sheet closes tonight. / One of this week's frames, if you want it there. · @handle put a photo you're in on the sheet. / Everyone on FLIM can see it there. |
| Owner alert | 12 frames on last week's sheet, none circled yet. |
| Admin panel | Sheet · Week of September 14 · Circle · Uncircle · Nobody put a frame on this one. |
| VoiceOver | Sheet card: "This week's sheet, open until Sunday night" and so on per state. Frame: "@handle's frame" or "Your frame", plus "circled" when it is. Circle button: "Circle @handle's frame". |
| Privacy page, Sharing | Photos you put on the sheet are visible to everyone signed in to FLIM, not only your followers, for as long as they are on a sheet. Take one off and it goes back to followers only. A circle is an editor's mark on the sheet, never a count. |
| What's New, 1.6 | The Contact Sheet. One sheet a week, shared by everyone. Put one frame on it from what you posted. Monday morning a few get circled. |

## 10. The cases that must work, and how

Each is a test, a probe on the kept database, or a demo-host screenshot. Name which under each
when you report.

- **The week rolls over while the sheet is on screen.** `SheetView` recomputes its state from
  `now` on foreground and on a one-minute tick while visible; the header line changes, nothing
  jumps, the open week becomes the first page.
- **A put-up races Sunday midnight.** The RPC's check is the truth; the client shows "The sheet is
  closed for this week." and reverts.
- **Two phones put up two frames.** Last write wins by the RPC's delete-and-insert; each client
  reloads `myEntry` after its commit, so the loser sees the other frame up, not both.
- **A frame's post is deleted mid-week.** FK cascade removes the row; the client purge follows
  `dropPosts(forDeletedPhotoIds:)`; the sheet's next load omits it; an open `SheetView` drops it
  without flashing empty.
- **A circled frame's author is blocked by the viewer, or blocks the viewer.** The read RPC filters
  both ways; the frame is gone for both; the circle goes with it for them, not for others.
- **A frame is hidden by reports.** Gone from the sheet by the read's `hidden` filter.
- **Offline.** The sheet you loaded stays; putting up or taking off fails through the capsule
  with the failure line; nothing is queued; nothing is lost.
- **Account switch.** `SheetService` resets; the dot key is per user; no frame, `myEntry` or week
  from the other account is visible for a frame. Test through the demo host with two seeded
  accounts if the host allows, else by code review of every read of `myEntry` and the key.
- **Circle, then uncircle, before the push goes.** Clearing resets `circle_push_sent`; the scanner
  only reads `circled_at not null`, so nothing sends; a later re-circle sends once.
- **The push arrives for a post since deleted.** Route resolves nothing; the app shows the
  sheet for the week without scrolling, and no error.
- **The owner skips a week.** The sheet reads "Closed Sunday night." and nothing else; the Monday
  alert nags once; the next week opens on schedule.
- **A 03:30 Monday post.** Belongs to the previous week; "Put it on the sheet" is not offered for
  it once the new week is open, and the RPC refuses with `not_this_week`.
- **The DST Sunday in November.** The week key test pins it; the reminder window is checked in
  Eastern, not UTC.
- **A non-follower opens a sheet frame.** The post loads, its bytes load, the author's handle and
  avatar load, reactions and comments are possible; a non-sheet post by the same author does not
  load. Probe on the kept database and on device with two accounts.
- **Reduce Motion, AX3, VoiceOver.** No draw-on animation; the grid reflows to two columns at
  AX3 if three cannot hold the handle; every frame and button is labelled.
- **The empty first week after release.** The owner puts his own frame up on day one so the
  first person who looks never sees an empty sheet; the copy still says "yours could be first"
  until it is not.

## 11. Stage E: measurement, copy, release

- Nightly numbers: two keys, `sheet_frames_week` and `sheet_circled_week`, added to the JSON the
  way the last column was, with `NUMBERS.md`'s header rewritten by the job as it does for a new
  column.
- The Monday memo's question, as one query the owner can paste: do people who put a frame up post
  more the following week than the week before, and do circled people come back.
- `MARKETING_VERSION` to `"1.6"` in both targets. What's New in `docs/APP_STORE.md` as drafted,
  with the section 9 line. The privacy page line live (manual deploy).
- `release-captain`: TestFlight build from main, the What's New pasted, the standing device
  checklist run (fresh install, put up, swap, take off, the push cold and live, the dot, AX3,
  VoiceOver), then submit. Arm the nudge only after READY_FOR_SALE with
  `update app_release_gate set latest_version = '1.6';`.
- Ship order: A, B and C together as the release, with the first sheet opening the Monday after it
  is live; D within the same week (the first Monday's circles can go out from the admin panel by
  hand even before the push kind is deployed, because the sheet itself shows them); E with D.

## 12. How each stage ends

The completion contract from `.claude/rules/agent-completion.md`, exactly:

```text
STATUS: COMPLETE | BLOCKED | NEEDS OWNER ACTION

CHANGED:
- path: concise reason

VERIFIED:
- exact command or check: PASS | FAIL | NOT RUN

NOT VERIFIED:
- item: reason

RISKS:
- concrete remaining risk, or NONE

HANDOFF:
- next agent and exact task, or NONE
```

Stage A ends NEEDS OWNER ACTION until the migration is applied and the nine defaults are
confirmed or vetoed. Do not start stage C on a guess about decision 2 or 3. If a rule in section 4
makes something in the plan impossible, say so and stop rather than bend the rule.
