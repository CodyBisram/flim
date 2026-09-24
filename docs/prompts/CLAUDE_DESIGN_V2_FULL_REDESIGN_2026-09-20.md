> SUPERSEDED 2026-09-24 by `CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-24.md`, which adds the
> numbers, iOS 27, the nine resilience states, the owner's review queue and the open decisions.
> Kept for the record.

# FLIM v2, the full redesign. Prompt for Claude Design

Paste everything below the line into a new Claude Design project. Attach, in this order:

1. A screenshot of every screen of the live 1.5.4 build (build 392): splash, sign in, code,
   OTP, username, onboarding, camera (personal and inside a roll), Darkroom (unsorted and a
   sorted month), the sort deck, compose, the feed (two-frame day and a strip day), comments,
   a frame opened, Activity, your own page, a friend's page, a page you do not follow, a
   Chapter, Rolls, a roll waiting, a roll ready, the reveal, a roll opened, create roll, join
   roll, members, invite sheet, Settings, blocked people, delete account, the notification
   ask, the version nudge. Thirty-odd images. Do not skip the ugly ones; those are the point.
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` (what exists; a
   starting point, not a cage).
3. Eight calibration photographs from `pairs/` with the shipped look applied, objects and
   places only, no faces.
4. The Italy and Bali promo cards (the feel the app itself should have).
5. `docs/prompts/V2_GAME_PLAN_2026-09-19.md` (the record of the first attempt).

The first attempt's package (`Stage 1 design directions.zip`) is deliberately not attached.

---

## 0. What this is

You are the design lead on a complete redesign of FLIM, every screen, from the splash to
delete account. Not a refresh of the feed card. Not a token pass. The owner has looked at the
app next to Apple Photos, Journal, and Instagram on the same phone and wants FLIM to belong
in that company: user-friendly, beautiful, ten out of ten, the thing a large company with a
hundred designers would ship, made by two people with the tools that now exist. The first
attempt at v2 was set aside because it did not look like that (section 2). This is the
second attempt, and it is a full one.

This document is long because you are being given the whole picture once, so you can make
decisions instead of asking for them. Read all of it before you draw. Sections 3, 5 and 7
are what you will be judged against.

Work in five stages, one turn each, and do not skip ahead:

1. **Directions.** Three complete visual directions on the same three screens (feed, camera,
   your page), each with a one-paragraph thesis and a named risk.
2. **Composite.** The chosen direction carried across the eight anchor screens, corrected
   from stage 1's critique, at real geometry with the tab bar and safe areas drawn.
3. **Application.** Every remaining screen in the inventory (section 6), every state, every
   width, AX3.
4. **Journeys.** The nine journeys in section 8, clickable, driven end to end.
5. **Handoff.** Section 9.

Each stage ends with a numbered list of decisions you need from the owner, each written as a
question with its two answers and what each answer changes. The owner answers in one line
each. You do not proceed on a guess.

## 1. What FLIM is

FLIM is an invite-only iPhone app that is a disposable camera for your friends. You shoot; the
photograph gets one film look baked in at capture, at 3:4, and lands in your Darkroom, where
you decide one shot at a time whether to keep it private, post it to your page, or delete it.
Posting shows it to the people who follow you and to anyone you tagged. Following is one way
and immediate; nobody approves a follow. The feed groups a person's shots into one unit per
day and you swipe the frames to read the day; reactions (one tap on an emoji chip) and
comments belong to the frame. A roll is a shared camera for one occasion: everyone invited
shoots into it, nobody sees anything until it develops for everyone at once, and the reveal
plays once. A Chapter is a finished month on your page. Activity is where responses to you
collect. There is one film look, no picker, no filters, no scores, no streaks, no ranks, no
public counts, no ads.

Tabs today, left to right: Camera, Darkroom, Rolls, Feed. The app opens on Camera.

The audience, from the nightly numbers on 2026-09-18: 74 accounts; about 27 people open it on
a given day; about 30 shoot in a week and 29 post; reactions run about ten to one over
comments; 45 to 55 pairs of people answered each other in the last seven days; everyone who
posted this month was answered, median 37 minutes. Fifteen rolls have ever been made, none
since September 6. Ten of the last 22 accounts came through a campaign code with nobody to
follow. Thirteen of 49 active people never answered the notification ask. The goal for the
next six months is 100 people who open it on an ordinary Tuesday, and the way there is the
everyday loop: see a friend's day, answer it, shoot one of your own, get answered, come back.

## 2. Why the first attempt was set aside, and what it got right

The owner's words: "I didn't like how it looked." The specifics, so you do not repeat them:

- It brought a design tool's default dark theme (blue-grey ground, violet accent, Inter,
  outlined buttons) and poured FLIM into it. It looked like a template.
- It shrank the photograph to make room for chrome. The photograph is the product.
- It put a tap in front of reactions. Reactions are one tap.
- It read as a document about an app: reviewer panels, device bezels, dense handoff prose,
  boards taller than a phone. The owner judges on his phone next to the real thing.
- It was cautious where it should have been ambitious (it kept the shipped look and moved
  labels around) and ambitious where it should have been cautious (it changed the launch
  surface and tab order, which the owner was about to measure).

What it got right, and what you keep: response as prominent as authorship; the audience
stated in words at the moment of sharing; honest capture states; one sorting vocabulary; the
discipline of measuring a claim before writing it; the route inventory, change map, rollout
batches and five-person study as the handoff shape; the list of decisions it could not make
alone, put to the owner as questions; and its honesty about what it got wrong.

## 3. The standard

- **The company test.** Put any board beside Apple Photos, Apple Journal, and Instagram on
  the same phone at the same width. It must belong to that company at that level of finish
  and still be unmistakably FLIM. If it reads as a prototype beside them, it is not done.
- **The stranger test.** A person who has never seen the app, handed a phone on any screen,
  can say what the screen is for and what to tap in under five seconds. Every screen has
  one job, above the fold at 375pt with the tab bar drawn; everything else steps back.
- **The photograph is the product.** The only saturated colour on any screen is inside the
  photographs. Chrome yields to them, never the reverse. The photograph is 3:4, always, and
  in the feed it is the full width minus the margin, never inset to fit a control.
- **Film is a material, not a costume.** Character comes from the photographs, the rebate
  and perforation of a strip, a grease pencil, a contact sheet, a seven-segment date. Never
  grain over controls, never a drawn camera body, never a skeuomorphic dial.
- **Motion says what happened.** A reaction lands, a shot slides into the Darkroom, a roll
  develops, a sheet closes. Every animation names its purpose; nothing is decorative;
  everything is under 350ms and honours Reduce Motion. The reveal is the one exception, and
  it has its own board.
- **Copy is the design.** Plain, warm, specific, in FLIM's words: roll, develop, Darkroom,
  keep private, post to page, chapter, sheet, circled. No exclamation marks. No em dashes
  anywhere, in copy or in your notes. Never "friends" where the truth is "people who follow
  you". Never "submit", "entry", "winner", "featured", "content", "engage".
- **Measure, then write.** "Above the fold" means you measured the fold on your rendered
  board at 375pt with the tab bar drawn. Every number in your handoff was measured, not
  estimated. The first attempt got five geometry claims wrong this way and said so; do not
  give the owner a sixth.
- **Accessible by construction.** 44pt targets, AA contrast on the surface a colour sits on
  (measure it, on a composited photograph too), every text scales with Dynamic Type up to
  AX3, VoiceOver labels written for every control, Reduce Motion honoured, nothing meaningful
  by colour alone, nothing essential by gesture alone.

## 4. What you may change, and what you may not

**Yours to redesign, fully:** the visual identity (palette, surfaces, the role of the accent,
elevation, the shape language, iconography), the information architecture within each tab,
every screen's layout, every component, every string, every transition, every empty state,
every error, onboarding end to end, the reveal, the Chapter, Settings, and the two new
features in section 7. If you keep something, keep it because it is right, and say so.

**Yours to propose, with the study caveat:** the launch surface and the tab order. The owner
is running a five-person study on the released build to decide these. Propose what you
believe, draw it, mark it "proposed, decided by the study", and also show the current order
so both can be tested. Do not draw anything that only works under one answer.

**Not yours:**

- The photograph: 3:4, feed width minus margin, never smaller to fit chrome, never cropped.
- Reactions: one tap on a visible emoji chip. Resize, reorder, relabel, move; never add a
  tap, a tray, or a long-press between the person and the chip.
- The look of the photographs themselves. One fitted look, pinned by regression tests; a
  separate lab handles it. No filters, no picker, no "looks".
- Behaviour the owner has ratified: the reveal plays once per roll and re-presents until
  watched to completion; Activity marks everything before your last visit as read; the
  inviter is followed for you at sign-up; a new account's first sort lands in the Darkroom;
  rolls cannot be renamed; a roll's invites end when it develops; the Darkroom's day and
  month structure.
- No scores, streaks, ranks, leaderboards, public counts, "top", "trending", "most". A
  reaction chip shows its count because it is the reaction; nothing aggregates above it.
- No monetization on any board. No light mode. No second typeface: SF Pro, because it is
  what the phone and every app on it that meets the standard uses; you may use every
  weight, width and optical size it has. No design-system export; the handoff gives token
  values in the app's own vocabulary (section 9).
- Privacy shapes: posts are readable by followers and tagged people; roll photographs are
  invisible to everyone, including the photographer, until the reveal; blocked people see
  nothing of each other; nothing leaves the app without the person choosing to save it.

## 5. The questions every screen must answer out loud

Write the answer under the board it belongs to, one line each. A board that does not answer
its question is not finished.

1. Where do I see my friends' day, and how do I know what is new since I last looked?
2. How do I answer a specific photograph in one gesture, and how do I know it landed?
3. How do I take a photograph quickly, and where is it going?
4. Where do my private photographs live, and which are still unsorted?
5. How do I know someone answered me, and how do I get to exactly that frame?
6. Where do my shared photographs live over time?
7. Where does a roll belong, how do I know one is waiting on me, and what happens when it
   develops?
8. Where does the best of this week go, who sees it there, and what happens on Monday?
9. How does someone I invited get in, and what do they see in their first minute with one
   friend and no photographs?
10. What does the app look like with no connection, and what did I lose? (Nothing. Say so.)
11. How do I leave: block someone, report something, delete my account, and what happens to
    my photographs?

## 6. The screen inventory

Every screen ships on a board. Grouped by tab as it stands today; regroup if your
architecture does.

**Getting in.** Splash. Sign in (email, one-time code). Invite code, with the four refusals
(wrong, used up, expired, a roll code entered here). Username. The one-screen onboarding
(a known inviter's photographs and the follow that was made for you; the campaign-code
path with nobody to follow, landing on Find people you know). The notification ask, at the
moment it earns itself, with its reason. The camera permission ask, at first camera open,
never before. The version nudge and the version block. Returning sign-in on a new phone.

**Camera.** Viewfinder with the destination stated (personal, or the roll's name) under it,
never over it. Flash, timer, the shot count that remains for a roll. The shutter and the
moment after (the film advancing, in your language). Capture states: on this phone,
uploading, waiting for connection, uploaded, failed with retry owned by that shot. Shooting
into a roll from the roll itself.

**Darkroom.** Unsorted shots waiting. The sort deck: Keep private, Post to page, Delete, with
undo and the audience sentence at Post. Compose (caption, tags, the sheet). A sorted month:
days, the month's closing row, zoom levels. A shot opened: the pager, reactions and comments
on a private shot from a roll, export with the seven-segment date. Empty Darkroom, first
ever and after sorting everything. The first-frame state for a new account.

**Rolls.** The list with the four card states (waiting, ready to open, opened, full). Create
(the default name from the date, the develop time, the invite). Join (link, code, the
refusals: full, expired, already in, already developed). Members with leave. A waiting roll
(what you can and cannot see: your own count only). The reveal: the once-only playback,
per-frame develop beat, skip always available, completion. A developed roll: the carousel,
reactions, comments, save, "Start another with this group". Empty Rolls.

**Feed.** The day units with two frames and with a strip. The live count of what is new and
the tap that jumps to the first unseen. The caught-up seam. Comment as a real control beside
the chips. Comments (thread, mentions, likes, the composer). A frame opened. People you know
(for accounts following fewer than a handful). The notification nudge. Activity: every row
kind (reaction, comment, thread reply, mention, tag, follow with Follow back, roll
developed, circled), the unavailable case. Empty feed, first ever and caught up.

**Pages.** Your own page: identity, the invite code one tap away, the newest posts before a
Chapter exists, the Chapter shelf, empty. Someone else's page: followed; not followed
(profile visible, photographs not, one Follow, the reason you might know them); follow in
flight; blocked. A Chapter: the finished month, its recap, playback, the closing card,
export. Find people you know (search, suggestions, the rows).

**Settings and trust.** Settings (accent, notifications, badges, stats visibility, feedback,
blocked people, sign out, delete). Block and its undo. Report a photograph and a person.
Delete account, with what happens to your photographs said plainly. The invite sheet
(personal code, campaign codes, share). The share preview for an exported photograph.

**System.** Offline banner. Undo capsule. Consequence sheets. Toasts. The share sheet's
image. Widgets (the Darkroom count, the roll countdown) if you keep them.

## 7. The two new features

### 7a. The Contact Sheet

The owner wants a weekly place for people's best photographs, where a person puts one
forward and, once a week, a few are chosen and shown. It must not be called Spotlight,
Featured, Highlights, Best of, or Picks. It is called **the Contact Sheet**, and the verb is
**circled**.

A contact sheet is the page of small positives a photographer prints from a roll to choose
from; the chosen frames are circled on it in red grease pencil. That is the whole feature,
in an object every film photographer knows and no app has used:

- One sheet a week, shared by everyone on FLIM. Opens Monday at 04:00 Eastern (the app's day
  boundary), closes Sunday night.
- Each person may put **one frame** on the sheet per week, from anything they posted that
  week. One, like 36 exposures: the scarcity is why nobody has to be told to post their best.
- Monday morning the owner circles a handful with the grease pencil. Circled stays circled
  forever. The uncircled frames stay on the sheet, in their place, not demoted, not counted.
- Nobody votes. No counts on the sheet, no ordering by response, no "most". Frames sit in
  the order they went up. The circle is an editor's mark, not a score.
- Past sheets stay, one per week, like a box of sheets: "Week of September 14".

Copy uses the object: "Put it on the sheet." "On this week's sheet." "The sheet closes
tonight." "Your frame was circled." "Circled, week of September 14."

Decide and show: where it lives (not a fifth tab; the top of the Feed or the top of Rolls,
and what your choice costs the everyday loop at 375pt); putting a frame up from the frame
and from the sort deck at Post, with the audience said in words before the tap (everyone on
FLIM, not only followers; tagged people told), the confirmation, the undo, withdraw until
close, swap when a frame is already up; the sheet at 0, 3 and 40 frames, 3:4 positives on
the ground with the rebate as a hairline, your own frame marked as yours without a badge,
tapping a frame opens the frame as the feed does; Monday morning, the circle (hand-drawn,
red-orange, slightly off-round, over the frame's corner, drawn once), the one push to the
circled person landing on their frame, the circle on the frame page and in the person's
grid at 120pt thumbnails; the one Sunday reminder, only to people who posted that week and
put nothing up; a new person's first week without a tour; deletion (takes the frame and its
circle off every sheet), blocking (hides both ways), and the privacy line the owner will
paste into the policy. It must never become a leaderboard, a popularity contest, a reason to
post for an audience you did not choose, or a second feed that competes with the first for
the fold.

What exists: posts, tags, reactions, comments, blocks, the day boundary, pushes, campaigns,
the admin panel. What is new: one table (post, week key, put up at, circled at, withdrawn
at), one owner-only circle action, two push kinds, a week-key rule. No new rendition. The
owner's session builds it; you say what the person sees and when.

### 7b. The roll prompt

Rolls work when they happen (the last four had eight or nine members and five to seven
reveal views each) and they do not happen (none since September 6). Design an invitation to
start a roll from an occasion the app can see: three people you follow shooting the same
evening, a burst of your own shots in one place, a date that had a roll last year. It is an
invitation, never an automatic roll; declinable in one tap with no consequence and no
repeat for that occasion; it names the occasion in words the person would use. Show where
it appears (the camera, after a burst; the feed, on a shared evening; a push, at most one a
week), what it looks like declined, and what "Start another with this group" looks like the
morning after a reveal.

## 8. The journeys

Clickable in stage 4, each driven end to end and the screen reached read back from the
running prototype, not asserted:

1. A personal invite link, on a phone with no app: install, code, OTP, username, the
   inviter's photographs, the follow made for you, first shot, first sort, first post, the
   inviter's reaction arriving.
2. A campaign code with nobody to follow: the honest landing, Find people you know, first
   follow, first feed.
3. An ordinary Tuesday: open, see two friends' days, react to one frame, comment on another,
   shoot two, keep one private, post one to the page, get answered, find the answer in
   Activity, open the exact frame.
4. A roll: create with the default name, invite three people, one joins by link and one by
   code, everyone shoots, waiting, the reveal for the creator and for a member, save one,
   start another.
5. The sheet: post a frame, put it on the sheet from the deck, withdraw, put a different one
   up, Sunday's reminder, Monday's circle, the push, the frame page, the grid mark, the
   archive a month later.
6. A Chapter: the month closes, the recap, playback, export with the date, the closing card.
7. Offline: shoot three, sort them, post one, react to a friend's frame, lose connection
   halfway; everything queued, nothing lost, the truth stated on each item; reconnect.
8. Trust: block someone from a comment, undo it, report a photograph, unfollow, and delete
   the account, with what happened to the photographs stated at each step.
9. Accessibility: journey 3 again at AX3 with VoiceOver labels shown and Reduce Motion on.

## 9. The handoff

- **Token values**, in the app's vocabulary (ground, elevated, row, stroke, sheet surface,
  text primary/secondary/tertiary, accent and its five alternatives, success, destructive,
  disabled; spacing; radii; the nine type roles with their Dynamic Type text styles), with
  contrast measured on the surface each colour sits on, photographs included. If the palette
  changed, say what changed and why, in one line per token.
- **Component inventory**: every component, its states, its long-content variant, its AX3
  variant, its VoiceOver label.
- **Route inventory**: every route, entered from, leaves to, and the state it must preserve.
- **Change map**: A presentation only; B client behaviour; C needs the server (the sheet's
  table and action, the roll prompt's occasion detection, the push kinds); D unresolved, as
  questions.
- **Rollout in batches** scoped by what can be reverted independently, each with the check
  that must pass before the next: look regression pins unchanged; contrast and targets
  audited on a device; captures per active day not falling; response within 24 hours of
  posting not falling; sessions that reach a friend's photograph; the sheet's distinct
  people per week and reactions on circled frames in the 48 hours after (never shown to
  anyone as a number).
- **The five-person study**, on the released build: the seven existing tasks plus two for the
  sheet and one for the roll prompt; record the participant's own word for every object
  before you supply it; what would count as a failure.
- **Explicitly incomplete**: drawn but not wired; not drawn; not validated on a device.
- **Where you were wrong during the work**, with the measurement that corrected it.
- No monetization appendix. One paragraph at the very end if you must, marked outside the
  brief.

## 10. Rules of conduct

- The repo is read only. No production code is touched.
- No simulated people. The calibration photographs are objects and places; where a board
  needs a face, leave a 3:4 placeholder that says so.
- No reviewer panel, no device bezel, no annotations inside the frame. Notes go beside the
  board: the three lines (which loop step it serves, what the owner will see change on his
  phone, what you deliberately left alone) and the answers to section 5.
- Boards at 402pt on the ground, with the tab bar and both safe areas drawn, and beside
  each the 375 and 430 variants and AX3.
- Every string you write goes in one copy inventory, old beside new, with the board it is
  on. The owner vetoes line by line.
- Ask at the end of each stage, in the A/B form. Do not proceed on a guess where the owner
  has a preference you cannot know.

The owner judges everything on his phone, next to the real app, and next to the best apps on
it. Draw for that comparison.
