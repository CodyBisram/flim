# FLIM 1.6: Spotlight. Prompt for Claude Design (2026-09-25)

Supersedes `CLAUDE_DESIGN_1_6_SPOTLIGHT_2026-09-24.md`. One change, carried everywhere: the owner
rejected the grease-pencil circle and the word circled. A chosen frame is now **in the Spotlight**,
and the mark is **the light**: the frame reads as lit. Section 4 defines the light and section 9
puts its form to the owner as a drawn choice.

Amended the same night: Spotlight is not a separate page. It lives inside the Feed tab as a second
view the person switches to, behind a quiet switch in the Feed header. The feed stays the default
and the dominant one; Spotlight shows the same frames all week and must never compete with the
feed for attention. Sections 2 and 4 carry the change.

This is not the v2 redesign. It adds one feature, Spotlight, to the app as it ships today
(1.5.4, build 398), in the app's current look, as release 1.6. Nothing that exists is redesigned.
What is designed is built so that v2 (`CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-24.md`, section 10)
inherits the data model, the rules, the pushes, the badge and the vocabulary unchanged: v2 restyles
the surfaces, it does not rebuild the feature.

Paste everything below the line into a new Claude Design project. Attach, in this order:

1. Screenshots of the live build, at 402pt: the Feed with its header (the "Feed" title, the
   ledger, the bell, find friends, your avatar), a feed unit with its band and menu open, a post
   opened (PostDetailView) with its toolbar menu open, the sort deck with the three circles and
   the "Add a caption or tag people" pill, the compose sheet ("New Post"), the "Posted to your
   page" banner, your own page (cover, avatar with badge pills, stats, Edit profile, the Chapters
   shelf, the month grid), a friend's page, Activity (the sheet, with a "New" section), the
   Badges sheet, the Settings sheet, the offline pill, the undo capsule, and the web admin panel
   (any queue, desktop and phone width).
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift`: the tokens and the type
   roles. These are a cage this time, not a starting point.
3. Two or three calibration photographs from `pairs/` with the shipped look applied, objects and
   places only, no faces, to stand in for frames.
4. `docs/prompts/CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-24.md`, for context only: section 10 is
   the feature's definition and this brief repeats what matters; everything else in it describes a
   future you are not designing now.

---

## 0. What this is

You are designing Spotlight for FLIM 1.6: a weekly place where each person can put one of the
frames they posted that week, and where the owner, on Monday morning, spotlights a handful. It ships into the app as it is today, using only the app's existing tokens, type
roles and components, so that a person updating from 1.5.4 sees the same app with one new thing
in it. The owner will build it from your boards; the server side is specified in section 3 as a
contract, and you design what the person sees and when.

Two rules shape everything:

- **Additive, not a redesign.** You may not move, restyle or rename anything that exists. The
  Feed header keeps its order, the feed unit keeps its band and menu, the page keeps its sections,
  the tab bar keeps its four tabs. Spotlight arrives as: one quiet switch in the Feed header and
  the view it switches to, one menu item, one toggle in the compose sheet, one pill on your own posted frames, one row kind
  in Activity, one badge, one shelf on the page, two pushes, one admin queue.
- **Built for v2.** The model in section 3 is the one v2 will restyle. Do not design anything
  that only works because of how 1.6 looks. Every rule about weeks, eligibility, withdrawal,
  choosing, visibility, deletion and blocking is fixed here and carried forward.

Work in four stages, one turn each:

1. **Placement.** Grey wireframes of every touched surface with the Spotlight element in place,
   at real geometry, at 402pt with the tab bar drawn: the header switch in both positions, the
   Spotlight view, the menu item, the compose toggle, the own-post pill, the Activity row, the shelf, the badge, the admin queue.
   Copy in place. Ends with the decisions in section 9.
2. **Boards.** The same surfaces in the app's look, at 402pt, plus 375 and AX3 for the header
   switch, the Spotlight view and the shelf.
3. **States.** Every state and edge case in section 5, each on its own board or explicitly marked
   not applicable with the reason.
4. **Handoff.** Section 8.

## 1. FLIM today: the surfaces you touch, as they are

Read this as fact. It was taken from the code on September 24.

- **The app.** Invite-only iPhone app; a disposable camera for your friends. One film look at
  capture, 3:4 always. Shots land in the Darkroom; the sort deck decides Keep private, Post to
  page, or Delete. Posting shows the frame to the people who follow you and to anyone you tagged.
  Following is one way and immediate. The feed groups a person's posts into one unit per day (day
  boundary 04:00, keyed on the post's time). Reactions are one tap on an emoji chip. A roll is a
  shared camera for an occasion. A Chapter is a finished month on your page. Activity is where
  responses collect. No scores, streaks, ranks, public counts, ads, DMs, light mode.
- **Tabs,** left to right: Camera, Darkroom, Rolls, Feed. The app opens on Camera. There is no
  profile tab; your page is reached from the avatar in the Feed header. Tab dots are "•", never
  numbers; the Feed dot lights for unseen shots or unread Activity.
- **The Feed header** (the nav bar is hidden; the page draws its own): "Feed" (17 light,
  secondary), then, when anything is unseen, "·" and a tappable accent ledger "N shots from M
  friends" that jumps to the first unseen unit; then the bell (Activity, a glass capsule with a
  red count bubble), find friends, and your 34pt avatar, which carries a red dot when a new badge
  is waiting. Inside the list, above the first unit: the notification nudge, a first-visit line,
  "People you know" (only when you follow fewer than three), and the caught-up block ("You're
  caught up", then "Nothing new until someone shoots something.", then "Shoot something"). A "New
  posts" accent pill overlays the top of the list; the same slot shows "Couldn't refresh".
- **The feed unit:** band (avatar 32, handle, "3 shots · 9:05 to 11:58 PM", an accent-outlined
  "N new" pill, an ellipsis menu labelled "Post options"), a film strip when there is more than
  one frame, the pager (width minus 32, 3:4, radius 12; double-tap likes; long-press opens the
  menu), the reaction bar, then the thread (caption, two preview comments, "View all N comments"
  or "Add a comment"). The own-post menu: "Edit caption", "Tag people" / "Edit tags", "Save to
  Camera Roll", "Delete post". Others': "Remove me from this photo" (if tagged), "Report", "Block
  @handle". Delete goes through the undo capsule: "Post removed" / "The photo is still in your
  Darkroom". There is no audience line on the card.
- **A post opened (PostDetailView):** author row (avatar 34, handle, date), the photo (radius
  14), caption, reaction bar, divider, comments ("No comments yet" / "N comments"), the comment
  composer pinned at the bottom. Actions in a toolbar ellipsis menu with the same items as the
  card.
- **The sort deck:** three circles under the card: "Keep private", "Post to page" (the green
  paperplane; it publishes instantly, no sheet), "Delete". A pill above, "Add a caption or tag
  people", or a tap on the card, opens the compose sheet: title "New Post", Cancel, the photo,
  a tag row ("Tag people" / "N tagged"), a caption field ("Add a caption…"), then the white
  PrimaryButton "Post". After posting, a banner: "Posted to your page. Your followers can see it."
  with "View". The one-time hint: "Keeping a photo puts it in your Darkroom, where only you can
  see it. Posting shows it to the people who follow you."
- **Your page (UserPageView):** cover (150pt, scrim), avatar 88pt with badge pills flanking it
  (two shown, one per side, the rarest first unless the person chose), name (22 light), the handle
  line with the frame-edge sign-up number on the right (tapping a badge swaps this line for the
  badge's explanation), "Follows you" on strangers, bio, an accent "New badge to see" pill on your
  own page that opens the Badges sheet, stats (shared / followers / following), a first-visit
  line, "Edit profile" and the invite button. Then the Chapters shelf: an uppercase "CHAPTERS"
  rule header, a horizontal row of 118pt-wide 3:4 cards (radius 14) with the month name and a
  stats line, the newest tagged "Recap"; nothing renders when there are no chapters. Then month
  sections: uppercase month label, a rule, a 3-column grid of 3:4 frames with 3pt gaps; cells open
  the post.
- **Badges:** 29 kinds in a catalogue, each with an emoji glyph, a label, a one-line explanation
  and a how-to-earn; tiers founding / gold / silver / bronze / accent with their own colours.
  Earned once, never lost, never pushed. A newly earned badge is announced only by the red dot on
  the Feed-header avatar and the "New badge to see" pill on your page; opening the Badges sheet
  marks them seen. The sheet ("Badges") has Automatic and Custom modes: "Your profile leads with
  your 2 rarest badges automatically". Rules: no badge names a person or a roll; no count-based
  badges; only earned badges are shown, no locked or greyed state.
- **Activity (a sheet from the bell):** rows read "{handle} " plus: "reacted 🙂 to your photo",
  "reacted 🙂 to a photo you're in", "commented: “…”", "liked your comment: “…”", "started following
  you", "tagged you in a photo", "mentioned you: “…”", "also commented: “…”", plus the roll-photo
  variants. Items newer than your last visit sit under an accent "New" header; the rest group as
  Today, Yesterday, This Week, This Month, Earlier. A post row pushes the post; a follow row opens
  the profile; a gone post toasts "That photo isn't there anymore." Empty: "No activity yet" /
  "Reactions, comments, tags, and new followers will show up here."
- **Pushes** (social): a title and a short body, and a route: post (optionally opening comments),
  profile, reveal, feed, join. Examples: "{name} commented" + preview; "{name} reacted" + "❤️ to
  your photo"; "{name} tagged you" + "in a photo"; "{name} started following you". An unknown route
  opens nothing. Badges send no push, deliberately. Every push is deduplicated in a ledger.
- **The version nudge:** the server's `latest_version` shows "A new version is here" / "Update
  FLIM" / "Later" once per version on older builds.
- **The web admin panel:** a left nav of queues (Invites, Reported photos, Reported people,
  Feedback, each with a count) and analytics. A queue renders as cards: a title line, "ago", a
  note, and action buttons; an action disables the buttons, calls the server, and refetches.
  Owner-gated server side.
- **Tokens (use these and nothing else):** ground `bg` near-black; `bgElevated`, `surface`, `row`,
  `stroke` / `divider`; `textPrimary` white, `textSecondary` 62%, `textTertiary` 55%; `accent`
  (amber by default; the person can pick rose, violet, teal, lime or sky, so every accent use must
  work as any hue) and `accentSoft` at 16%; `success`, `destructive`, `error`, `disabled`,
  `placeholder`, `loading`; the badge golds, silvers, bronzes; `sheetSurface`. Spacing 2 / 4 / 6
  / 9 / 12 / 16 / 22 / 28 / 36. Radii: photo 6, control 12, panel 14, sheet 16. Type roles:
  pageTitle 26 light, sheetTitle 17 medium, name 16 medium, body 14.5, control 14 semibold, label
  13 medium, code 13 mono, meta 12.5, micro 11 medium, stamp 11 mono fixed, sectionRule 11 mono
  tracked 1.8 (the uppercase rule headers). Dynamic Type scales every role up to AX3.
- **Components:** `glassCapsule` and `glassCard` (iOS 26 glass, material fallback below),
  `PrimaryButton` (white, radius 14, black text), the undo capsule (five-second window with a
  countdown ring; a failed commit shows its failure line in place), consequence sheets, the toast
  capsule (checkmark or triangle, 1.6s, 3s for errors), the offline pill "No connection",
  `CachedImage` for every photograph, `FilmStripGrid` (3 columns, 3:4), `ChapterShelfView`.
- **Renditions:** thumb 500px, feed 1400px, master 2048px. Grids and shelves use thumb; a full
  card uses feed; nothing but a full-screen view or an export touches the master.

## 2. Spotlight: the mechanic, fixed

The owner decided these; design inside them.

- **One Spotlight a week, shared by everyone on FLIM.** The week opens Monday 04:00 and closes the
  following Monday 04:00, **in one app-wide zone, America/New_York**, named on the page. Personal
  days and nights keep the phone's zone; the shared week does not, because it must open and close
  at one moment for everyone. In copy the close is "Sunday night".
- **One frame per person per week,** from anything they posted that week (a post whose feed day,
  in the app zone, falls inside the week). One, like 36 exposures.
- **Put it up** from the frame's own menu (feed card or post opened), or from the compose sheet
  at the moment of posting. Withdraw any time before the week closes. Putting up a second frame
  swaps: the first comes down, and the app says so before it happens.
- **Monday morning the owner spotlights a handful.** Choosing is immediate per frame and can be
  undone until the owner taps Done for the week; Done sends the pushes. Once in the Spotlight,
  always in the Spotlight. If the owner has not tapped Done by Monday noon, nothing happens: no frames lit, no
  pushes, the week stays as it is, and the new week has opened on schedule.
- **Nobody votes. No counts, no ordering by response, no "most".** Frames sit in the order they
  went up. The light is an editor's mark, not a score. The number of frames up is never shown.
- **Frames not chosen stay** where they were put, in their place, not demoted, not removed.
- **Past weeks stay,** one per week.
- **Spotlight lives inside the Feed tab, as a second view.** The feed is what the tab opens on,
  every time, and it is the prominent one. Spotlight is reached by a quiet switch in the Feed
  header and shows the same frames all week; it must never compete with the feed for the fold,
  never interleave with feed units, never be a tab, a row inside the feed, or a bottom accessory.
  Leaving the tab and coming back lands on the feed, not on Spotlight.
- **A frame in the Spotlight is public.** Everyone on FLIM sees it in Spotlight and on its photographer's
  page. The person is told this before they put a frame up.
- **The trophy** is a badge, `spotlight`, earned the first time one of your frames is put in the Spotlight,
  never changing after (no count, no tiers), plus the frame itself carrying the light wherever
  it appears, plus a **shelf** on your page collecting your Spotlight frames with their weeks.
- **The words:** Spotlight (the place), in the Spotlight (the state), the light (the mark). Never
  "featured", "picked", "winner", "top", "selected", "circled", "submit", "entry", "contest".

## 3. The model that survives v2 (the contract)

Design against this; the owner builds it. v2 changes none of it.

**One table, `spotlight_entries`:** id; post_id (one post can only ever be in one week); user_id;
week_key (the date of the week's Monday, e.g. 2026-09-14); put_up_at; withdrawn_at (null while
up); chosen_at (null unless it was put in the Spotlight); chosen_push_sent. Invariants: at most one row per user per
week with withdrawn_at null; a row for a post whose feed day is outside week_key is refused;
withdrawal after the week closed is refused; choosing before the week closed is refused;
removing after Done is refused. Deleting the post deletes the row (cascade), which takes the
frame and its light out of every week. Deleting the account cascades likewise. Blocking hides
both ways at read time, as posts already do. A hidden post (reported and hidden) is invisible in
Spotlight while hidden. A covered account's post cannot be put up while covered.

**One week table, `spotlight_weeks`:** week_key; closed_at (set by Done); the count chosen is never
stored or exposed.

**Reads:** `spotlight_week(p_week_key)` returns the entries of a week in put_up order with the
post's paths and handle, minus blocked and hidden; `spotlight_weeks()` lists week keys with a
cover (the first frame in the Spotlight, else the first frame). `own_spotlight_entry(p_week_key)` returns
the caller's row for the week. `spotlight_frames(p_user_id)` returns a person's entries that were put in the Spotlight, for
the shelf.

**Writes:** `put_up_for_spotlight(p_post_id)` (swaps if one is up; refuses outside the week);
`withdraw_from_spotlight(p_post_id)`; owner-only `choose_spotlight_entry(p_entry_id)`,
`unchoose_spotlight_entry(p_entry_id)`, `close_spotlight_week(p_week_key)` (Done).

**Pushes, two kinds,** through the existing social push and its ledger: `spotlight_chosen` ("You're in
the Spotlight", route: spotlight, week, post), sent on Done to each person whose frame was chosen, once; and
`spotlight_closes_tonight` ("Spotlight closes tonight", route: spotlight), sent Sunday evening
only to people who posted that week and have nothing up. Nobody is pushed about anyone else's
frame. A route the client does not know opens nothing, so the Spotlight push goes as a spotlight
route to 1.6 clients and as a post route to older ones (the server knows each account's version).

**The badge:** `spotlight`, predicate "has at least one entry with chosen_at set", ratcheted like every
other badge, announced like every other badge (the avatar dot and the "New badge to see" pill), no
push. Tier: gold. Glyph, label, explanation and how-to-earn are yours to write in the catalogue's
voice ("Spotlight", "One of your frames was in the Spotlight.", "Put a frame up for Spotlight.
Monday morning, a few are lit.").

**Activity:** one new row kind, "spotlight", reading "Your frame is in the Spotlight" with the week;
it opens the Feed tab switched to Spotlight, scrolled to the frame. No row for putting up, withdrawing, or the Sunday
reminder.

**Instrumentation,** day-bucketed counters like the rest of the app, never per-tap streams:
spotlight page opened, frame put up, frame withdrawn, Spotlight push opened. Everything else is
derivable from the table.

**The version gate:** when 1.6 is live on the App Store, `latest_version` moves to 1.6.0 so
1.5.x installs see the nudge. A 1.5.x client never sees Spotlight and never sees the switch;
its posts can still be put up from a 1.6 device. State this on the handoff.

## 4. What you draw, surface by surface, in the current look

**The switch (Feed header).** The "Feed" word in the header (17 light, `textSecondary`) becomes
two words: "Feed" and "Spotlight", side by side with the header's own spacing, the active one in
`textSecondary` exactly as "Feed" reads today, the inactive one in `textTertiary`. Tapping the
inactive word switches the view; nothing else in the header changes (the bell, find friends and
the avatar stay). No segmented control, no underline, no capsule, no accent: the header must look,
at a glance, exactly as it does today with one quiet word added. The ledger ("N shots from M
friends") belongs to the feed view and is hidden on Spotlight. The tab bar's Feed dot never lights
for Spotlight. Returning to the tab, or launching the app, always shows the feed. Whether the
"Spotlight" word carries a tiny signal on the Monday after Done, until the person has looked once
that week, is decision 9; by default it does not.

The word's states, said only by one optional meta word after it in the micro role: midweek
nothing ("Spotlight"); Sunday, for a person who posted this week and has nothing up, "Spotlight ·
closes tonight"; Monday before Done nothing; Monday after Done, the optional signal of decision 9.
Never a count of frames, never a count of people.

**The Spotlight view (inside the Feed tab).** Same header, the feed list replaced. First, one meta
line: "Week of September 14 · closes Sunday night · Eastern time" (or "· lit Monday" once Done).
Then the frames: 3:4, two columns with the grid's 3pt gap (two, not three, because these are the
week's chosen frames and the Chapters cards are 118pt wide; say if you disagree and why), thumb
rendition, the handle in micro under each, in put-up order, the same frames for the whole week.
Your own frame carries a hairline accent rule under its handle, no badge, no "you". A frame in
the Spotlight carries **the light**: it reads as lit, the way one print on a dark wall reads under
a lamp. Draw it three ways in stage 1 and the owner picks (section 9, D5): (a) a warm glow
bleeding a few points past the frame's edges onto the ground, strongest at the top; (b) a
one-point warm hairline around the frame with a soft outer glow; (c) a small beam glyph at the
frame's upper-left corner, light falling in from above. Whichever wins: one fixed warm
white-amber, never the phone's accent (which the person can change), propose the exact colour,
and it must read on a dark frame, on a bright one, and with Reduce Transparency. It is never a
ring, a circle, a star or a badge on the photograph. It appears once; the only animation is the
light coming up over 350ms on the first view after the push, honouring Reduce Motion. Tapping a
frame opens the post exactly as the feed does (PostDetailView), with its reactions and comments.
Under this week: "Past weeks", a horizontal row in the Chapter shelf's geometry (118pt 3:4 cards,
radius 14) showing each week's cover and "Week of September 7"; tapping one shows that week in
the same layout with "lit Monday" in the meta. Draw the view at 0 frames (Monday's first hour, and
the first week ever), 3, 12 and 30. With about 48 people posting in a month, 12 to 30 frames is
the realistic range. Draw the feed view beside it in every case so the two are seen as one tab.

**Putting a frame up, from the frame.** In the own-post menu (feed card and post opened), a new
item after "Tag people": "Put it up for Spotlight", or "Take it down from Spotlight" when it is
up, or "Swap it into Spotlight" when another of your frames is up this week. Tapping "Put it up"
shows a consequence sheet in the existing pattern, once per week the first time and never again
after the person has done it twice: title "Put it up for Spotlight", body "Everyone on FLIM can see
it there, not only the people who follow you. Anyone you tagged is told. You can take it down until
Sunday night.", button "Put it up", and Cancel. Swap says instead: "Your frame from Tuesday comes
down. Everyone on FLIM can see this one there." with "Swap". Success is an undo capsule: "Up for
Spotlight" / "Everyone on FLIM can see it there", undo within five seconds takes it down silently.
Failure lands in the capsule's place: "Couldn't put it up. Check your connection and try again."

**Putting a frame up, from the compose sheet.** A toggle row under the tag row, before the caption:
"Put it up for Spotlight" with the meta line "Everyone on FLIM can see it there" (or "Swaps out
your frame from Tuesday" when one is up). Off by default. The button stays "Post". The success
banner after posting becomes "Posted to your page and put up for Spotlight." with "View". The
instant "Post to page" circle on the deck is unchanged and never puts a frame up. Draw the toggle
on, off, and disabled with its reason when the person already put up a frame from a post made
today and the swap would be the same frame (not applicable, say so) or when the account is covered
("Not available this week").

**Your own posted frame, while it is up.** On the feed unit's band, on your own units only, next to
the "N new" pill's position: a hairline accent-outlined pill "Up for Spotlight" (label role). On
the post opened, the same pill under the author row. Never on other people's frames. Nothing on the
Darkroom.

**The Spotlight push and where it lands.** "You're in the Spotlight" (title), body "One of your
frames, week of September 14". Opening it lands on the Feed tab switched to Spotlight, scrolled to the frame, with
the light coming up once. If the app was already open, a toast in the top slot: checkmark, "You're in the
Spotlight". The badge dot lights on the avatar the next time the feed reloads; do not add a second
push or a modal.

**The frame afterwards.** In the feed unit and on the post opened, a frame in the Spotlight carries
the light, quietly, forever, in a form that still reads at the card's size. In the person's page
grid, the same at 120pt thumbnails (the light must survive a 3pt gap between lit and unlit
cells; show it). In Activity, the spotlight row with the week, opening the Spotlight view at the frame.

**The shelf.** On the page, between the header and the Chapters shelf: an uppercase "SPOTLIGHT" rule
header in the sectionRule role, then a horizontal row of 118pt 3:4 cards (radius 14) in the
Chapter shelf's geometry, newest first, each carrying the light and "Week of Sep 14" in meta. It
renders only when the person has at least one frame in the Spotlight. It shows on every page,
own or another person's, because those frames are public. Draw it at one card, three and eight, and on
a page whose grid you cannot see (a person you do not follow): the shelf shows, the grid does
not, and the shelf says nothing about the grid.

**The badge.** In the catalogue's shape: an emoji glyph in a pill, gold tier. Draw it flanking the
avatar as one of the two, in the Badges sheet, and the "New badge to see" pill on your own page
the morning after. Write its label, explanation and how-to-earn.

**Activity.** The "spotlight" row: your own avatar is wrong here (nobody did it to you); use the
badge's glyph in the avatar slot, "Your frame is in the Spotlight", meta "Spotlight, week of
September 14". Under "New" like any row.

**The Sunday push.** "Spotlight closes tonight" (title), body "You posted this week. Put one up?"
Route: Spotlight. Only to people who posted that week and have nothing up. Never to anyone else,
never twice.

**The owner's queue (web admin).** A fifth queue, "Spotlight", in the nav with a count of frames
awaiting review (the owner's count, never a person's). Header: "Week of September 14 · closes
Monday noon" and a "Done for the week" button, disabled until at least one frame is chosen or the
owner confirms an empty week. Cards, newest first: the frame at 3:4 (thumb), the handle, "put up
Tuesday", a "Spotlight" button; chosen cards show the light over the frame and a "Remove"
button; the header shows "3 in the Spotlight" (the owner's own count, fine here). Done confirms: "Send 3
pushes and close the week?" Draw it at desktop width and at phone width (the owner does this on
his phone). Also draw, as a proposal only, an in-app owner mode: the same queue as a sheet behind
the owner's own page, visible to the owner account only; 1.6 ships the web queue and the in-app
mode is decision 4 in section 9.

## 5. States and edge cases

Every one of these gets a board, or a line under the nearest board saying it does not apply and
why. "Applies" is decided by what the code can produce, not by what seems likely.

**The nine states, for the header switch, the Spotlight view, the shelf and the queue:**

1. Loading, first time (switching to Spotlight): a shimmer in the shape of the frames (the existing 3:4 shimmer), never a
   spinner; after three seconds of nothing, "Still loading".
2. Loading again: the loaded week stays; a pull to refresh; nothing flashes empty.
3. Empty, first ever: the first week, no frames yet: "Nothing up yet. Put one of this week's
   frames up from its menu." One route forward.
4. Empty, later: Monday's first hour of a new week: "A new week. Frames go up from their menu."
   and last week reachable under it. These two empties are different sentences.
5. Partial or dead data: a frame whose post was deleted mid-week (it is gone, the others close
   the gap, no hole); a lit frame whose author deleted their account (gone, same); a frame
   from someone you blocked or who blocked you (invisible to you, the others unchanged); a hidden
   post (invisible while hidden); a frame whose thumb rendition is missing (falls back to the
   master, like the grid); a week whose cover frame was deleted (next frame becomes the cover).
6. Error with the way back: the view fails to load ("Couldn't load Spotlight. Try again." in
   place, with the retry); put up fails; withdraw fails; the compose toggle was on and the post
   succeeded but the put-up failed ("Posted to your page. Couldn't put it up for Spotlight; try
   from the post's menu."); the owner's Spotlight fails ("Couldn't put it in the Spotlight. Try again."); Done fails
   halfway (the week is closed, some pushes went; the ledger prevents doubles; the owner sees
   "Closed. 2 of 3 pushes sent; retrying." and a retry).
7. Offline: the loaded week stays readable and the switch still works; put up and
   withdraw queue like every other write and the frame's menu item says "Queued"; the queued
   put-up sends when the connection returns. If the week closed while it was queued, it fails
   honestly: "This week closed before it sent." and nothing goes into the new week.
8. Stale, after a switch: signing out and in as another account on the same phone: no "Yours is
   up", no "Up for Spotlight" pill, no badge dot, no shelf from the other account is ever
   visible, and the tab lands on the feed. Draw the moment of the account switch on the view.
9. Racing: two phones on the same account put up different frames within seconds (last write
   wins; the earlier phone learns on its next refresh, its pill goes away, no error); a frame is
   put up at 03:59 Monday (it belongs to the closing week); the week rolls over while the view is
   on screen (the meta changes, the frames stay, a "New week" pill in the top slot like "New
   posts"); the owner chooses while a person is looking at the view (the light appears on their
   next refresh, not live); a person withdraws a frame at 03:58 Monday and it is already in the
   owner's queue (the queue refetches; if it was chosen before the withdrawal landed, the
   withdrawal is refused: "The week closed."); the Spotlight push arrives on a phone still on
   1.5.4 (it opens the post, not Spotlight); the person deletes the post after it was put in the Spotlight
   (the frame, its light, the shelf card and the Activity row all go; the badge stays, because
   badges are never lost); a reaction is tapped on a Spotlight frame by someone who does not
   follow the photographer (allowed; it is public); a comment likewise (decision 3).

**Spotlight-specific:**

- A person who follows nobody and is followed by nobody switches to Spotlight: the full view,
  same as everyone. This is the one place a newcomer with no friends sees the whole app.
- A person in the Spotlight a second time: the same push, the second frame lit, the shelf at two,
  the badge unchanged, no second badge announcement.
- The owner's own frame: the owner may put a frame up; the queue shows it; the owner may put it
  in the Spotlight (nothing in the model forbids it); the in-app rule is his own and the design says nothing.
- A person puts up a frame, then edits its caption or tags: nothing changes in Spotlight; the
  frame there reflects the edit on the next load.
- A person puts up a frame that tags someone: the tagged person is told in Activity as today
  ("tagged you in a photo") and nothing more; no extra push.
- Reporting from Spotlight: the same "Report" as the feed; a hidden post disappears from the
  week while hidden and returns if unhidden.
- Blocking from Spotlight: the same "Block @handle"; both ways, immediate on the next refresh.
- The camera-only person who has never opened the Feed: the switch is in the Feed header, so
  they never meet Spotlight until they do. Say so under the board; it is accepted.
- An account created mid-week: may put up any frame it posts that week.
- A roll photo posted to the page (8.7% of posts are roll frames): eligible like any post; the
  roll's own privacy ended when it developed.
- A covered account (the owner has hidden three accounts' posts from everyone for a week): its
  frames cannot be put up while covered; the menu item is absent, the compose toggle says "Not
  available this week", and nothing explains why. Covered lifts, and it works again.
- The empty Monday: nobody put anything up. The owner's queue says "Nothing was put up this
  week." with "Close the week" (no pushes). The view shows the week with no frames and "Nobody
  put a frame up this week." Past weeks are unaffected.
- Reduce Motion: the light appears without coming up. VoiceOver: every frame reads "{handle}, in
  the Spotlight" or "{handle}"; the switch reads its state; the light has no label of its own
  beyond the frame's.
- Dynamic Type AX3: the two header words wrap onto a second header line before they truncate,
  each keeping a 44pt target; the view's meta wraps; the handle under a frame truncates with an ellipsis before it wraps.
- The accent as any of the six hues: the "Up for Spotlight"
  pill and your own frame's rule must read in all six; the light is never the accent, it is
  always the one warm white-amber, so it stays the same colour on every phone.

## 6. Copy inventory

Every string, with where it lives. Propose replacements only where a line here is wrong for the
screen; the vocabulary in section 2 is fixed.

| Where | String |
|---|---|
| Header switch | Feed · Spotlight (the inactive word in textTertiary) |
| Switch meta | closes tonight |
| View meta | Week of September 14 · closes Sunday night · Eastern time / Week of September 14 · lit Monday |
| Past weeks header | Past weeks |
| Own-post menu | Put it up for Spotlight / Take it down from Spotlight / Swap it into Spotlight / Queued |
| Consequence sheet, put up | Put it up for Spotlight / Everyone on FLIM can see it there, not only the people who follow you. Anyone you tagged is told. You can take it down until Sunday night. / Put it up / Cancel |
| Consequence sheet, swap | Your frame from Tuesday comes down. Everyone on FLIM can see this one there. / Swap / Cancel |
| Undo capsule | Up for Spotlight / Everyone on FLIM can see it there |
| Failure lines | Couldn't put it up. Check your connection and try again. / Couldn't take it down. Check your connection and try again. / Couldn't load Spotlight. Try again. / This week closed before it sent. / The week closed. |
| Compose toggle | Put it up for Spotlight / Everyone on FLIM can see it there / Swaps out your frame from Tuesday / Not available this week |
| Post banner | Posted to your page and put up for Spotlight. / View |
| Own-frame pill | Up for Spotlight |
| Empty, first ever | Nothing up yet. Put one of this week's frames up from its menu. |
| Empty, new week | A new week. Frames go up from their menu. |
| Empty, closed week | Nobody put a frame up this week. |
| New week pill | New week |
| Spotlight push | You're in the Spotlight / One of your frames, week of September 14 |
| In-app toast | You're in the Spotlight |
| Sunday push | Spotlight closes tonight / You posted this week. Put one up? |
| Activity row | Your frame is in the Spotlight / Spotlight, week of September 14 |
| Shelf header | SPOTLIGHT |
| Shelf card meta | Week of Sep 14 |
| Badge | Spotlight / One of your frames was in the Spotlight. / Put a frame up for Spotlight. Monday morning, a few are lit. |
| Admin queue | Spotlight / Week of September 14 · closes Monday noon / Spotlight / Remove / 3 in the Spotlight / Done for the week / Send 3 pushes and close the week? / Nothing was put up this week. / Close the week / Closed. 2 of 3 pushes sent; retrying. |

No exclamation marks. No em dashes anywhere, in copy or in your notes. FLIM's name appears only
where the sentence needs it and is written as the app's configured name.

## 7. Rules

- The photograph is 3:4, never cropped, never inset for a control. The light sits at the frame's edge and never covers
  the photograph.
- Reactions stay one tap on the visible chip. Nothing is added between a person and the chip on a
  Spotlight frame.
- No counts on anyone: not frames up, not people, not lights on a person. The owner's queue may
  count for the owner.
- Only existing tokens, roles and components. The one new visual element is the light. If you believe a second is needed, name the gap and ask.
- Nothing that exists moves. The header gains one word and nothing else; if the second word forces
  anything in the header to shrink or wrap at 375pt, show it and say what changed.
- The accent is a variable that must work as any of six hues and is used for one action at a
  time. The light is never the accent.
- Nothing fails silently. Every failure has its line, in place, with the way back.
- Everything scales to AX3, every control is 44pt, every colour passes AA on the surface it sits
  on, measured on a photograph too.
- No coach marks, tours or explainer cards. The consequence sheet the first two times is the only
  teaching, and the view explains itself by being there.

## 8. The handoff

- **Boards:** every surface in section 4 at 402pt in the app's look; the header switch, the
  Spotlight view and the shelf also at 375 and at AX3; every state in section 5 on a board or explicitly not
  applicable; the admin queue at desktop and phone width.
- **The copy inventory** (section 6), final, with the board each line is on.
- **The change map:** A presentation only (nothing here is); B client behaviour (the header switch,
  the Spotlight view, the menu items, the compose toggle, the pill, the shelf, the Activity row, the badge
  glyph, the push routes, the version nudge); C server (section 3 verbatim: the two tables, the
  RPCs, the two pushes, the badge predicate, the version-aware push route, the counters); D
  unresolved, as questions.
- **The build order the owner will follow,** each step shippable alone: (1) server tables, RPCs,
  badge predicate, admin queue; (2) client read-only: the switch, the view, shelf, the light on frames, the
  Activity row; (3) client writes: put up, withdraw, swap, compose toggle, the pill; (4) pushes
  and the Sunday reminder; (5) `latest_version` to 1.6.0. State what a person on step 2 sees
  before step 3 exists (the view, no way to put anything up: the empty copy must not promise the
  menu item until it exists; give the step-2 empty line).
- **What v2 changes and what it does not:** a two-column list. Does not: anything in sections 2
  and 3, the copy vocabulary, the push kinds, the badge, the shelf's existence. Changes: the
  switch's look (v2 draws it in the redesigned Feed header), the view's frame layout (rebate
  hairlines, one row per line), the light's rendering, the admin queue's chrome, the possible
  in-app owner mode.
- **The rollout check,** measured for two weeks after 1.6 is live, never shown to anyone as a
  number: distinct people who put a frame up per week; reactions on Spotlight frames in the 48
  hours after Done, against the same frames' reactions before; captures per active day and
  response within 24 hours of posting, not falling; Sunday push opens. What would count as a
  failure, in one line each.
- **Explicitly incomplete:** drawn but not wired; not drawn; not validated on a device.
- **Where you were wrong during the work,** with the measurement that corrected it.

## 9. Decisions for the owner, asked at the end of stage 1

Ask in this form, two or three answers each, one line back from the owner.

1. **The first week.** A: Spotlight opens to everyone with 1.6 on the first Monday after release.
   B: one week on TestFlight only, gated the way Film Lab is, so the owner lights a small week
   first.
2. **The consequence sheet.** A: shown the first two times, then never. B: shown every time, since
   it names a real audience change. C: shown the first time only.
3. **Comments from strangers on a Spotlight frame.** A: anyone can react and comment, as the frame
   is public there. B: anyone can react; comments stay with followers and tagged people. C: react
   only, no comments from Spotlight at all.
4. **The in-app owner mode.** A: web queue only in 1.6, in-app in v2. B: both in 1.6.
5. **The Monday noon cut-off.** A: as written; nothing happens if the owner misses noon. B: the
   queue stays open until the owner taps Done, whenever that is; the pushes go then.
6. **The shelf on a page you do not follow.** A: shown, because Spotlight frames are public (as
   written). B: hidden with the grid.
7. **Two columns or three in the Spotlight view.** A: two. B: three, matching the grid.
8. **The light's form (D5).** A: the glow past the edges. B: the hairline with a soft glow. C: the
   beam glyph at the corner. Drawn all three on the same frame, at card size and at 120pt, on a
   dark frame and a bright one, before the owner picks.
9. **A signal on the switch.** A: none, ever; the \"Spotlight\" word is the same every day (as
   written). B: on the Monday after Done, a 4pt dot after the word until the person has looked once
   that week, for everyone. C: the dot only for a person whose own frame was lit.

## 10. Rules of conduct

- The repo is read only. No production code is touched.
- No simulated people. Frames are the calibration photographs; where a board needs a face, leave a
  3:4 placeholder that says so.
- No reviewer panel, no device bezel, no annotations inside the frame. Notes go beside the board.
- Boards at 402pt on the ground, with the tab bar and both safe areas drawn.
- Every string you write goes in the copy inventory. No em dashes, no exclamation marks.
- Ask at the end of each stage, in the A/B form. Do not proceed on a guess where the owner has a
  preference you cannot know.

The owner judges everything on his phone, next to the real app. This has to look like it was
always there.
