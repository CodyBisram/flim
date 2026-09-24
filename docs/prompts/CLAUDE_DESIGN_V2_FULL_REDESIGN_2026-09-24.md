# FLIM v2, the full redesign. Prompt for Claude Design, third attempt (2026-09-24)

Supersedes `CLAUDE_DESIGN_V2_FULL_REDESIGN_2026-09-20.md` and `CLAUDE_DESIGN_V2_BRIEF_2026-09-19.md`.
What changed since September 20: 1.5.4 shipped the engineering fixes of September 24 (the camera
recovers from interruptions, deletion cannot lie, the feed's rules applied everywhere); iOS 27 is
out and Liquid Glass is no longer optional; the numbers moved (reciprocity 33 to 39, rolls still
zero, Founding 100 at 24 seats); and the owner asked for the resilience states, the analytics, the
platform and the weekly feature's review flow to be in the brief rather than assumed.

Paste everything below the line into a new Claude Design project. Attach, in this order:

1. A screenshot of every screen of the live 1.5.4 build (build after 395): splash, sign in, code,
   OTP, username, onboarding, camera (personal, inside a roll, the unavailable overlay, the
   permission refusal), the capture chip in each of its five states, Darkroom (empty, first frame,
   unsorted banner, a sorted month, year, all-time), the sort deck (a card, mid-swipe, the compose
   sheet), the feed (two-frame day, a strip day, the ledger, the caught-up seam, the people-you-know
   row), comments, a frame opened, Activity (every row kind), your own page, a friend's page, a
   page you do not follow, a blocked page, a Chapter (opening card, playback, closing card), Rolls
   (empty, an open roll, a ready roll, an invited card), create roll, join roll, roll detail
   developing and developed, the reveal (cover, pager, summary), members, the invite sheet,
   Settings, blocked people, delete account, the notification primer, the version nudge, the
   offline pill. Forty-odd images. Do not skip the ugly ones; those are the point.
2. `Flim/Views/Theme.swift`, `Flim/Views/Components/FlimFont.swift` (what exists; a starting point,
   not a cage).
3. Eight calibration photographs from `pairs/` with the shipped look applied, objects and places
   only, no faces. And two exports with the seven-segment date stamp burned in.
4. The Italy, Bali and Dubai promo cards (the feel the app itself should have).
5. `docs/UX_AUDIT_2026-09-24.md` (the audit this prompt is built on) and
   `docs/prompts/V2_GAME_PLAN_2026-09-19.md` (the record of the first attempt).

The first attempt's package is deliberately not attached.

---

## 0. What this is

You are the design lead on a complete redesign of FLIM, every screen, from the splash to delete
account. Not a refresh of the feed card, not a token pass. The owner has looked at the app beside
Apple Photos, Journal and Instagram on the same phone and wants FLIM to belong in that company:
ten out of ten, the thing a large company with a hundred designers would ship, made by two people
with the tools that now exist. Two earlier attempts were set aside (section 2). This is the third,
and it is a full one: structure first, then the look, then every state, then the journeys.

This document is long because you are being given the whole picture once, so you can decide
instead of asking. Read all of it before you draw. Sections 3, 5, 8 and 10 are what you will be
judged against.

Work in six stages, one turn each, and do not skip ahead:

1. **Architecture and wireframes.** The information architecture (tabs, routes, what lives
   where), then a grey wireframe of every screen in section 9 in its default state, at real
   geometry, with the tab bar and safe areas drawn. No colour, no photographs yet: boxes, labels,
   the copy in place. This stage settles what each screen is for and what is above the fold.
2. **Directions.** Three complete visual directions on the same four screens (feed, camera, the
   Darkroom, the sheet), each with a one-paragraph thesis, a named risk, and the one thing it
   does that the other two cannot. One of the three must be the quiet one; one must be the one
   you are slightly afraid to show.
3. **Composite.** The chosen direction carried across the ten anchor screens (section 9 marks
   them), corrected from stage 2's critique.
4. **Application.** Every remaining screen, every one of the nine states (section 8), every
   width, AX3.
5. **Journeys.** The eleven journeys in section 12, clickable, driven end to end.
6. **Handoff.** Section 14.

Each stage ends with a numbered list of decisions you need from the owner, each written as a
question with its two answers and what each changes. The owner answers in one line each. You do
not proceed on a guess. Section 15 lists the ones already known to be open.

## 1. What FLIM is

FLIM is an invite-only iPhone app that is a disposable camera for your friends. You shoot; the
photograph gets one film look baked in at capture, at 3:4, and lands in your Darkroom, where you
decide one shot at a time whether to keep it private, post it to your page, or delete it. Posting
shows it to the people who follow you and to anyone you tagged. Following is one way and
immediate; nobody approves a follow. The feed groups a person's shots into one unit per day and you
swipe the frames to read the day; reactions (one tap on an emoji chip) and comments belong to the
frame. A roll is a shared camera for one occasion: everyone invited shoots into it, nobody sees
anything, not even their own shots, until it develops twelve hours after it starts, for everyone at
once, and the reveal plays once. A Chapter is a finished month on your page. Activity is where
responses to you collect. There is one film look, no picker, no filters, no scores, no streaks, no
ranks, no public counts, no ads, no DMs, no light mode.

Tabs today, left to right: Camera, Darkroom, Rolls, Feed. The app opens on Camera.

**The look, precisely, because it is the brand and it is not yours to change.** One stock, "FLIM
Original", tagline "Warm, timeless, a little grainy". A 3D LUT fitted on real same-scene pairs
against Lapse's rendering, applied after a scene-adaptive exposure lift (dark scenes are lifted
before the grade, like Lapse), then warm halation bloom at 0.18 with 0.75 red warmth, a vignette
at 0.75, and monochrome grain at 0.06 peaked in the midtones and applied at full resolution before
the downscale so it averages into texture rather than dirt. Flash frames get a physical falloff
put back (the ISP had flattened it) so the subject holds and the background falls toward black,
15 to 35% of the frame under 0.04 luminance, like a real single-use camera. A shadow-peaked,
faintly chromatic grain was shipped as 1.5.1 and rejected by the owner on device the same day. The
parametric fallback exists only for when the LUT fails to load. Every export carries an orange
fourteen-segment date stamp in the lower right, like a 90s date back, and nothing else.
Photographs are the only saturated colour on any screen, and the look is why.

## 2. Why the earlier attempts were set aside, and what they got right

The owner's words on the first: "I didn't like how it looked." The specifics, so you do not
repeat them:

- It brought a design tool's default dark theme (blue-grey ground, violet accent, Inter, outlined
  buttons) and poured FLIM into it. It looked like a template.
- It shrank the photograph to make room for chrome. The photograph is the product.
- It put a tap in front of reactions. Reactions are one tap.
- It read as a document about an app: reviewer panels, device bezels, dense prose, boards taller
  than a phone. The owner judges on his phone next to the real thing.
- It was cautious where it should have been ambitious (it kept the shipped look and moved labels
  around) and ambitious where it should have been cautious (it changed the launch surface and tab
  order, which the owner was about to measure).

The second attempt's brief (September 20) was right about the standard, the screen inventory, the
journeys and the handoff, and this document keeps them. It was thin in three places this one fills:
it assumed the data instead of stating it, it did not name the platform, and it did not design
what happens when the network, the data or the timing go wrong.

What both got right, and what you keep: response as prominent as authorship; the audience stated
in words at the moment of sharing; honest capture states; one sorting vocabulary; the discipline
of measuring a claim before writing it; the route inventory, change map, rollout batches and
five-person study as the handoff shape; the list of decisions put to the owner as questions; and
honesty about what went wrong.

## 3. The standard

- **The company test.** Put any board beside Apple Photos, Apple Journal and Instagram on the
  same phone at the same width. It must belong to that company at that level of finish and still
  be unmistakably FLIM. If it reads as a prototype beside them, it is not done.
- **The stranger test.** A person who has never seen the app, handed a phone on any screen, can
  say what the screen is for and what to tap in under five seconds. Every screen has one job,
  above the fold at 375pt with the tab bar drawn; everything else steps back.
- **The photograph is the product.** The only saturated colour on any screen is inside the
  photographs. Chrome yields to them, never the reverse. The photograph is 3:4, always, and in the
  feed it is the full width minus the margin, never inset to fit a control.
- **Show the model, never explain it.** A roll shows its clock. A kept frame looks kept. A post
  says who sees it. A developing frame looks like it is developing, not like it failed. If a
  screen needs a card to explain itself, the screen is wrong. Coach marks, tours, arrows and
  tutorial overlays are banned.
- **Film is a material, not a costume.** Character comes from the photographs, the rebate and
  perforation of a strip, a grease pencil, a contact sheet, a seven-segment date. Never grain over
  controls, never a drawn camera body, never a skeuomorphic dial.
- **Motion says what happened.** A reaction lands, a shot slides into the Darkroom, a roll
  develops, a sheet closes. Every animation names its purpose; nothing is decorative; everything
  is under 350ms and honours Reduce Motion. The reveal is the one exception, and it has its own
  board.
- **Copy is the design.** Plain, warm, specific, in FLIM's words: roll, develop, Darkroom, keep
  private, post to page, chapter, sheet, circled. No exclamation marks. No em dashes anywhere, in
  copy or in your notes. Never "friends" where the truth is "people who follow you". Never
  "submit", "entry", "winner", "featured", "content", "engage".
- **Nothing fails silently.** Every action that can fail shows where it failed, in the app's
  words, with the way back, in place, never as a modal. Every wait has a bound or a reason.
- **Measure, then write.** "Above the fold" means you measured the fold on your rendered board at
  375pt with the tab bar drawn. Every number in your handoff was measured, not estimated.
- **Accessible by construction.** 44pt targets, AA contrast on the surface a colour sits on
  (measure it on a composited photograph too), every text scales with Dynamic Type up to AX3,
  VoiceOver labels written for every control, Reduce Motion honoured, nothing meaningful by colour
  alone, nothing essential by gesture alone.

## 4. The people and the numbers

Design for these people, not for a persona. Every number is from the nightly count on September
23 or the recorded runs of the metrics functions; the audit (attached) has the sources.

- **77 accounts.** 23 to 33 open on a given day; the trailing week is 25 to 29, drifting down as
  accounts grow. About a third of the roster on a given day.
- **Two of three opens end with no photograph.** 6 to 18 people shoot on a given day. The camera is
  the landing tab and most people walk past it.
- **Reactions are the living part.** 30 to 180 a day, ten to one over comments; median comments
  per post is zero every week. Everyone who posts is answered, median 40 minutes. A reaction push
  brings 80 to 100% same-day opens.
- **Reciprocal pairs, the proxy for a social layer,** went 53, 33, 39 over twelve days. 22 of 54
  pairs run through the owner; three people are connected only through him.
- **Rolls: zero created on every one of the last eighteen days.** 15 ever, none since September 6,
  no follow-up roll ever, though "Start another with this group" has been live since 1.5.3. The
  last four rolls had eight or nine members and five to seven reveal views each. Rolls work when
  they happen and they do not happen.
- **Newcomers arrive alone.** 10 of the last 22 accounts came through a campaign code with nobody
  to follow. 14 of 50 weekly openers follow fewer than three people, and posts are followers-only,
  so their feed is one or two people's days. The September 7 cohort fell from 58% to 26% by week
  two; the August 10 cohort holds near half.
- **First shot.** Median 130 minutes after account creation; 12 of 38 never took one. The
  one-screen onboarding that replaced three cards has no after measurement yet.
- **Invites.** About four redeemed a week, tracking new accounts exactly. Each person has three; one
  comes back when the invitee takes a first photo. Founding 100 has 24 seats left, about six
  weeks. Campaign codes (FLIMGO, BALI26, SEPT10) produced arrivals who followed nobody and never
  shot; the one campaign that moved a number was a thank-you push, and it lasted one day.
- **Notifications.** 12 active people were never asked; 11 of the 12 are camera-only and have
  never touched a roll.
- **Geography.** The app records no country. What is known: an Eastern-time app with a handful of
  people abroad (one active account keeps UTC+8 hours; the promo cards were Italy, Bali, Dubai;
  the Bali cohort never shot). Chapters now take the phone's time zone. Design the day boundary,
  the develop clock and the weekly rhythm to read correctly in any zone, and never assume the
  viewer and the photographer share one.
- **The goal for the next six months:** 100 people who open it on an ordinary Tuesday. The way
  there is the everyday loop (see a friend's day, answer it, shoot one of your own, get answered,
  come back) with three things added: a feed that has people in it on day one, a weekly rhythm the
  product itself supplies, and rolls that happen because the app noticed an occasion.

## 5. The platform: iOS 27

iOS 27 shipped this month. Liquid Glass was reworked (lower default transparency, a user slider from
clear to tinted, sharper icons) and the compatibility opt-out is ignored once an app builds with
Xcode 27, so FLIM's system chrome is glass whether it chooses or not. Design for that, and for the
Human Interface Guidelines' rule that glass belongs to the navigation layer floating above content
and never to the content layer.

- **Glass on the navigation layer only:** the tab bar, toolbars, the capsule buttons that float
  over the viewfinder and the reveal, the sheet grabber and its chrome. Nowhere else.
- **Opaque ground under every photograph.** Near-black. Never glass over a photograph, never a
  glass card in a list, never a glass panel on a flat ground (it reads as a tinted rectangle).
  1.5.4's `glassCard` on content surfaces goes.
- **The system tab bar,** floating, minimising on scroll down and returning on scroll up. It
  changes the safe area; draw every scrolling screen with the bar in both states. A bottom
  accessory above the bar is available for one persistent element; decide whether FLIM uses it
  (the capture chip, the undo capsule, or nothing) and say why.
- **The clarity slider** means your glass is seen at two extremes. Every glass element must read
  at both; test the tab bar over a bright photograph at the clearest setting.
- **Concentric corners:** radii nest with the device's. Sheets, cards and the photograph's corner
  radius (12 today) are one family.
- **SF Pro only,** every weight, width and optical size it has. Dynamic Type text styles for every
  role. Numbers in tabular figures where they change (a clock, a count).
- **The camera is not Apple's Camera.** iOS 27 moved Camera's mode settings beside the shutter and
  made its controls customisable; FLIM's camera stays simpler than that on purpose (one look, no
  modes), but its control positions should feel native to a person who just left Camera.app.
- **Honour Reduce Motion, Reduce Transparency, Increase Contrast and Bold Text** as first-class
  states, not fallbacks. Draw the tab bar under Reduce Transparency.

## 6. What you may change, and what you may not

**Yours to redesign, fully:** the visual identity (palette within the constraints, surfaces, the
role of the accent, elevation, the shape language, iconography), the information architecture
within and across tabs, every screen's layout, every component, every string, every transition,
every empty state, every error, onboarding end to end, the reveal, the Chapter, Settings, and the
two new features in section 10 and 11. If you keep something, keep it because it is right, and
say so.

**Yours to propose, drawn both ways:**

- The launch surface and the tab order. The owner intended a five-person study to decide these
  and it has not run. Propose what you believe, draw it, mark it "proposed", and draw the current
  order beside it. Do not draw anything that only works under one answer.
- Whether Rolls stays a tab. Zero rolls in eighteen days is the strongest signal in the data.
  Draw the app with Rolls as a tab and with rolls folded into Camera (the roll pill) and Feed (a
  developed roll as a day unit with several authors), keeping the reveal, the Live Activity and
  the widget. Recommend one. Say what each costs at 375pt.

**Not yours:**

- The photograph: 3:4, feed width minus margin, never smaller to fit chrome, never cropped.
- The look of the photographs (section 1). One fitted look, pinned by regression tests. No
  filters, no picker, no "looks", no edits.
- Reactions: one tap on a visible emoji chip. Resize, reorder, relabel, move; never add a tap, a
  tray, or a long-press between the person and the chip.
- Behaviour the owner has ratified: the reveal plays once per roll and re-presents until watched to
  completion; each frame develops in place once, about 0.35s; Activity marks everything before your
  last visit as read; the inviter is followed for you at sign-up; a new account's first sort lands
  in the Darkroom; rolls cannot be renamed (shipped, reverted, do not re-propose); a roll's
  invites end when it develops; the twelve-hour develop (the number comes from
  `Roll.developDelayPhrase`, never typed); the Darkroom's night and month structure; the 04:00 day
  boundary; Feed and Activity stay separate (decided: no merge); tab signals are dots, never
  numbers; badges are discovered, never pushed.
- Sign-in is email plus a six-digit emailed code, invite only. No phone numbers, no social
  sign-in, no guest.
- No scores, streaks, ranks, leaderboards, public counts, "top", "trending", "most", progress
  bars, confetti. A reaction chip shows its count because it is the reaction; nothing aggregates
  above it.
- No monetization on any board. No light mode. No second typeface. No design-system export; the
  handoff gives token values in the app's own vocabulary (section 14).
- Privacy shapes: posts are readable by followers and tagged people; roll photographs are invisible
  to everyone, including the photographer, until the reveal; blocked people see nothing of each
  other; nothing leaves the app without the person choosing to save it; a friend's post or chapter
  never leaves FLIM, your own photographs and every photograph in a roll you are in can be saved.
- Parked, do not re-propose: contact-sheet restyle of the Darkroom grid, inline roll rename, a
  "save all first" offer on delete.

## 7. The questions every screen must answer out loud

Write the answer under the board it belongs to, one line each. A board that does not answer its
question is not finished.

1. Where do I see my friends' day, and how do I know what is new since I last looked?
2. How do I answer a specific photograph in one gesture, and how do I know it landed, or did not?
3. How do I take a photograph quickly, where is it going, and when will I see it?
4. Where do my private photographs live, which are still unsorted, and which did I post?
5. How do I know someone answered me, and how do I get to exactly that frame?
6. Where do my shared photographs live over time, and where is this month?
7. Where does a roll belong, how do I know one is waiting on me, and what happens when it
   develops?
8. Where does the best of this week go, who sees it there, and what happens on Monday?
9. How does someone I invited get in, and what do they see in their first minute with one friend
   and no photographs?
10. What does the app look like with no connection, and what did I lose? (Nothing. Say so.)
11. What does the app look like when the data is half there, wrong, or just changed under me?
12. How do I leave: block someone, report something, delete my account, and what happens to my
    photographs?

## 8. Resilience: the nine states every screen ships in

A senior iOS designer designs the screen that appears when things go wrong before the one that
appears when they go right, because the second is the one the person remembers. Every screen in
section 9 ships on a board in each of these states that applies to it. If a state does not apply,
say so under the board. "Applies" is decided by what the code can produce, not by what seems
likely.

1. **Loading, first time.** Skeleton or shimmer in the shape of the real content, never a spinner
   on a blank ground, never a layout that jumps when the data lands. A bound: after three seconds
   of nothing, a line.
2. **Loading, again.** Pull to refresh, background refresh, the "New posts" pill. The old content
   stays; nothing flashes empty.
3. **Empty, first ever.** The screen the day the account was made. One route forward. Real
   copy, not "No items".
4. **Empty, caught up.** Different from the first-ever state, in words: "You're caught up" is not
   "You don't follow anyone yet" is not "Nobody you follow has posted this week".
5. **Partial or dead data.** A photograph whose rendition is missing (falls back to the master
   today, 5% of photographs once). A post whose author was deleted. A comment from a blocked
   person. A chapter whose cover was deleted. A frame judged Missed (black or blurred). A roll
   whose survivors are all dead frames. A push that opens a post that is no longer visible. A
   profile whose avatar 404s. Each has a look and a line; none looks like a bug.
6. **Error, with the way back.** The request failed. Say what did not happen, in the app's words,
   and offer the retry in place. Never the system's own string. Distinguish "no connection" from
   "the server answered and said no" from "this took too long".
7. **Offline.** The app is fully usable for what it holds: the Darkroom, sorted photographs, the
   loaded feed, the roll you already opened. Every write queues: a shot, a sort, a post, a
   reaction, a comment, a follow, a block. Each queued item says so on itself, once, quietly. Nothing
   is lost; reconnecting drains the queue in order and says nothing unless something failed. Draw
   the offline pill, the queued chip, the queued reaction, the queued comment.
8. **Stale, after a switch.** The person signed out and someone else signed in on the same phone,
   or the same person signed in on a second phone. No frame, count, seen-mark, draft or undo from
   the other account is ever visible. Draw the moment of the switch.
9. **Racing.** Two things happened at once. A reveal starts while a deep link is opening a photo.
   A roll develops while the shutter is pressed (the shot goes to the deck, and says so). A post is
   deleted while its card is on screen. An undo window is open when the app is backgrounded (the
   action commits; say nothing or say it once). A reaction is tapped twice fast. A comment is sent
   as the connection drops. Draw the outcome the person sees, and it must always be the truthful
   one.

Plus the four system states that cut across everything: the camera permission refused, the photo
library permission refused (only when saving), notifications refused or never asked, and the
version block (no way out but Update) and the version nudge (dismissible, once per version).

## 9. The screen inventory

Every screen ships on a board, in every applicable state from section 8, at 375, 402 and 430pt and
at AX3. Grouped by tab as it stands today; regroup if your architecture does. Anchor screens for
stage 3 are marked with a star.

**Getting in.** Splash. Sign in (email, one-time code) ★. Invite code, with the five refusals
(wrong, used up, expired, a roll code entered here, an invite code entered in the roll field),
the two codes told apart by look and label. The OTP screen with its bounded wait. Username, with
what can wait (name, colour) moved to where it earns itself. The one-screen onboarding ★ (a known
inviter's photographs and the follow that was made for you; the campaign-code path with nobody to
follow, landing on Find people you know). The notification ask, at the moment it earns itself,
with its reason, and with the word roll not used before it is met. The camera permission ask, at
first camera open, never before, and the refusal with Back to Feed. The version nudge and block.
Returning sign-in on a new phone. Founding 100 closed, said at the door.

**Camera ★.** Viewfinder with the destination stated under it, never over it: "Personal" or the
roll's name with its clock ("Develops in 11h", always, not only in the last hour). Flash (and
whether it is a screen flash), timer, zoom, flip (taught once, in the app's words, not by
accident). The shutter and the moment after (the film advancing, in your language). The capture
chip's five states, and where it lives with the floating tab bar. Burst detected. Storage full.
The unavailable overlay (another app, a call, too warm, stopped) and the refusal. Shooting into a
roll from the roll itself. The roll pill's picker.

**Darkroom ★.** Unsorted shots waiting, visible in the rack, not only behind a banner. The sort
deck ★: Keep private, Post to page, Delete, with undo, the audience sentence at Post, the durable
Keep/Post label that never retires, and the frame's own verdict on the card (sharp, Missed, one of
a burst of three). Compose (caption, tags, the sheet, "and put it on the sheet"). A sorted month:
nights, the month's closing row, zoom levels, kept and posted told apart at a glance. A shot
opened: the pager, reactions and comments on a private shot from a roll, export with the
seven-segment date, and the reason when export is not offered. Empty Darkroom, first ever and after
sorting everything. The first-frame state. Select mode and multi-delete with undo.

**Rolls.** Both architectures (section 6). The list with the four card states (waiting, ready to
open, opened, full) and the invited card. Create (the default name from the date, the develop time
as a number, who this roll is with, the invite). Join (link, code, the refusals: full, expired,
already in, already developed). Members with leave and remove. A waiting roll (what you can and
cannot see: your own count only; "nobody sees a frame yet, you included" durable, not a one-time
line). The reveal ★: the once-only playback, per-frame develop beat, skip always available, that
leaving is safe said once, completion, the summary, save all, "Start another with this group".
A developed roll: the carousel, reactions, comments, save. Empty Rolls. The roll prompt (section
11). The Live Activity, the Dynamic Island, the lock-screen shutter, the home widget, if kept.

**Feed ★.** The day units with two frames and with a strip. The live count of what is new and the
tap that jumps to the first unseen. The caught-up seam, in its three meanings. Comment as a real
control beside the chips. The audience on the card, quietly. Comments (thread, mentions, likes, the
composer, the failed send with its line). A frame opened. People you know (for accounts following
fewer than a handful), and the thin-feed state with one friend's Tuesday. The notification nudge.
Activity: every row kind (reaction, comment, thread reply, mention, tag, follow with Follow back,
roll developed, circled), the unavailable case. Empty feed, first ever, caught up, and nobody has
posted this week. The double-tap heart and what a second double-tap does. The 04:00 boundary said
once where a person can find it. The sheet at the top (section 10).

**Pages ★ (your own).** Identity in one glance without a 300pt header; the newest posts before a
Chapter exists; the Chapter shelf with this month's slot in it (in progress, not missing); the
invite code one tap away with the earn-back said in the open; the circled frame's mark in the
grid; empty. Someone else's page: followed; not followed (profile visible, photographs not, one
Follow, the reason you might know them); follow in flight (the grid does not flash empty);
blocked. A Chapter ★: the finished month, the recap, playback, the closing card, export, and the
"still computing" card that says it is provisional. Find people you know (search, suggestions, the
rows). Badges: the two that lead, the picker, the locked catalogue that does not read as a
checklist.

**Settings and trust.** Settings (accent, notifications, camera roll autosave with the refusal
inline, badges, stats visibility, feedback, blocked people, sign out, delete). Block and its undo;
unblock and its failure. Report a photograph and a person. Delete account, with what happens to
your photographs said plainly, hold to confirm, and the failure that names which step failed.
The invite sheet (personal code, the quota, the earn-back, share text). The share preview for an
exported photograph, and the decision whether it carries a way in.

**System.** Offline pill. Undo capsule. Consequence sheets. Toasts, and the rule for when a toast
is allowed (a result the person did not watch happen). The queued-write chip. The share sheet's
image. The version block.

**The owner's surface.** See section 10, the review queue.

## 10. The weekly feature: the Contact Sheet, circled

**On the name.** The owner asked for this feature today using the word Spotlight: a person posts a
photograph and can put it forward; the owner, personally, from the admin account, reviews the
submissions; once a week a handful are shown. The owner's own September 19 and 20 briefs specify the
same feature and say it must not be called Spotlight, Featured, Highlights, Best of or Picks,
because other apps own those words and none of them are film; they name it **the Contact Sheet**,
verb **circled**. This prompt uses those names. Decision 1 in section 15 puts the choice to the
owner; one find-and-replace changes it. Design it so either name works.

A contact sheet is the page of small positives a photographer prints from a roll to choose from;
the chosen frames are circled on it in red grease pencil. That is the whole feature, in an object
every film photographer knows and no app has used.

**The mechanic.**

- One sheet a week, shared by everyone on FLIM. Opens Monday at 04:00 in the app's day boundary,
  closes Sunday night. State the week in the viewer's zone and name the zone once.
- Each person may put **one frame** on the sheet per week, from anything they posted that week.
  One, like 36 exposures: the scarcity is why nobody has to be told to post their best.
- Monday morning the owner circles a handful with the grease pencil. Circled stays circled forever.
  The uncircled frames stay on the sheet, in their place, not demoted, not counted.
- Nobody votes. No counts on the sheet, no ordering by response, no "most". Frames sit in the
  order they went up. The circle is an editor's mark, not a score.
- Past sheets stay, one per week, like a box of sheets: "Week of September 14".
- Copy uses the object: "Put it on the sheet." "On this week's sheet." "The sheet closes tonight."
  "Your frame was circled." "Circled, week of September 14."

**What you decide and show.**

- **Where it lives.** Not a fifth tab. The top of the Feed as a horizontal sheet the person can
  scroll (the sheet is social, the feed is where people look), or the top of Rolls (quiet, and a
  sheet is a roll everyone shares), or, if rolls fold into the feed, the sheet takes the place
  Rolls had. Pick one, and say what it costs the everyday loop at 375pt with the tab bar drawn.
- **Putting a frame up.** From the frame itself (your own post, in the feed or on your page) and
  from the sort deck at the moment of posting ("Post to page, and put it on the sheet"). Before
  the tap lands it says, in words: everyone on FLIM will see it there, not only the people who
  follow you, and anyone you tagged is told. The confirmation, the undo, withdraw until the sheet
  closes, swap when a frame is already up this week (the old one comes down, stated).
- **The sheet itself.** 3:4 positives on the dark ground with the rebate drawn as a hairline, one
  row of frames per scroll line, your own frame marked as yours without a badge. Tapping a frame
  opens the frame with its reactions and comments exactly as the feed does; the sheet has no viewer
  of its own. The sheet at 0 (the first hour of a Monday, and the very first week), 3, 12 and 40
  frames.
- **Monday morning.** The circled frames carry a hand-drawn red-orange grease-pencil circle over
  the frame's corner, slightly off-round, drawn once, never animated after the first reveal. The
  person whose frame was circled gets one push ("Your frame was circled") that lands on the sheet,
  scrolled to their frame. Nobody else is pushed about circling. The morning after: the sheet, the
  frame page of a circled frame (the circle visible there too, quietly), the person's own page (a
  circled frame in the grid carries the mark at 120pt thumbnails), and Activity's circled row.
- **Sunday.** One reminder, only to people who posted that week and put nothing up. "The sheet
  closes tonight."
- **A new person's first week,** without a tour: the sheet explains itself by being there.
- **Trust.** Deleting a post takes the frame and its circle off every sheet. Blocking hides both
  ways. Reporting from the sheet works as it does from the feed. The privacy line the owner will
  paste into the policy.
- **The nine states** of section 8 for the sheet: loading, the week rolling over while it is on
  screen, a frame whose post was deleted mid-week, a circled frame whose author was blocked,
  offline (the sheet you loaded stays; putting up queues and says so), the race where two frames
  are put up from two phones.

**The owner's review, which the earlier briefs left as "one owner-only action".** The owner is one
person reviewing on a Monday morning. Design the review as a queue, not a dashboard:

- **Where.** The web admin panel already has queue cards (invite requests, reported photographs,
  reported people, feedback) with action buttons and a refetch after each action. The sheet review
  is a fifth card in the same pattern: this week's frames, newest first, at 3:4 with the
  photographer's handle and the day it went up, a Circle action per frame, an Uncircle within the
  hour, a count of circled so far, and Close the week. Design it at desktop width and at phone
  width (the owner does this from his phone). Also propose an in-app owner mode (the same queue
  behind the owner's own page, visible only to the owner account) and say which you recommend and
  why; the owner decides (decision 7).
- **The rhythm.** Sunday night the queue is complete. Monday morning the owner circles. Circling is
  immediate per frame; the push to each circled person goes when the owner taps Done for the
  week, so nobody is pushed twice and a change of mind costs nothing. If the owner has not closed
  the week by Monday noon in the app's zone, nothing happens: no circles, no pushes, the sheet
  simply stays as it is, and the next week opens on schedule.
- **States.** An empty week (nobody put anything up): what the owner sees and what the app shows
  everyone (a sheet with no frames is still a sheet). One frame. Forty. A frame reported while on
  the sheet. A frame whose author deleted their account between Sunday and Monday.
- **What it must never become:** a leaderboard, a popularity contest, a reason to post for an
  audience you did not choose, a second feed that competes with the first for the fold, or a
  chore for the owner.

**What exists:** posts, tags, reactions, comments, blocks, reports, the day boundary, pushes,
campaigns, the admin panel with its queue cards. **What is new:** one table (post, week key, put
up at, circled at, withdrawn at), one owner-only circle action and one close-the-week action, two
push kinds, a week-key rule, one admin card. No new rendition. The owner's session builds it; you
say what the person sees and when.

## 11. The roll prompt

Rolls work when they happen (the last four had eight or nine members and five to seven reveal
views each) and they do not happen (none since September 6). Two fixes, both yours:

- **Who this roll is with.** Before a roll exists, the create screen shows the people it could be
  with: the people you follow who follow you back, the people you were in a roll with, the people
  who shot the same evening. A roll with nobody in it is not offered as a roll; it is offered as a
  Darkroom shot.
- **The occasion.** An invitation to start a roll from something the app can see: three people you
  follow shooting the same evening, a burst of your own shots in one place, a date that had a roll
  last year, a reveal that finished this morning ("Start another with this group"). It is an
  invitation, never an automatic roll; declinable in one tap with no consequence and no repeat for
  that occasion; it names the occasion in words the person would use. Show where it appears (the
  camera, after a burst; the feed, on a shared evening; a push, at most one a week), what it looks
  like declined, and the morning after a reveal.

## 12. The journeys

Clickable in stage 5, each driven end to end and the screen reached read back from the running
prototype, not asserted:

1. A personal invite link, on a phone with no app: install, code, OTP, username, the inviter's
   photographs, the follow made for you, first shot, first sort, first post, the inviter's reaction
   arriving.
2. A campaign code with nobody to follow: the honest landing, Find people you know, first follow,
   first feed, and the thin feed the next morning.
3. An ordinary Tuesday: open, see two friends' days, react to one frame, comment on another, shoot
   two, keep one private, post one to the page, get answered, find the answer in Activity, open the
   exact frame.
4. A roll: the occasion prompt, create with the default name and the people it is with, invite one
   more by link and one by code, everyone shoots, waiting (the clock on the camera), the reveal for
   the creator and for a member, leave mid-reveal and come back, save one, start another.
5. The sheet: post a frame, put it on the sheet from the deck, withdraw, put a different one up,
   Sunday's reminder, Monday's circle, the push, the frame page, the grid mark, the archive a month
   later.
6. The owner's Monday: open the queue on a phone, circle four of thirty, uncircle one, close the
   week, and what each of the four sees.
7. A Chapter: the month closes, the provisional card, the recap, playback, export with the date,
   the closing card.
8. Offline: shoot three, sort them, post one, put one on the sheet, react to a friend's frame,
   comment, lose connection halfway; everything queued, nothing lost, the truth stated on each
   item; reconnect; one item fails and says so.
9. Dead data: open a push for a deleted post, a feed with a blocked author's comment, a chapter
   with a deleted cover, a roll where every frame is Missed, a profile whose avatar 404s.
10. Trust: block someone from a comment, undo it, report a photograph, unfollow, sign out and sign
    in as someone else on the same phone (nothing of the first account visible), delete the
    account, with what happened to the photographs stated at each step.
11. Accessibility: journey 3 again at AX3 with VoiceOver labels shown, Reduce Motion and Reduce
    Transparency on.

## 13. Visual direction, what the owner already knows he wants

You choose the direction in stage 2, but not from nothing:

- Ground near-black (#0A0A0A today), white text, grey secondary, one warm amber accent (#FABD5C
  today) that the person may swap for five alternatives; the accent is a variable that must work
  as any hue and is used for one action at a time. It is never a brand colour spread across the
  screen.
- The photograph is the only saturated colour. Everything else is value, not hue.
- Film as material: the rebate and perforation of a strip as structure (a day is a strip, a month
  is a rack, a week is a sheet), the grease-pencil circle as the one hand-drawn mark, the
  fourteen-segment date as the one display face. Never a camera body, a dial, a lens flare, a
  light leak, a torn edge, a Polaroid frame.
- Type: SF Pro, one family, many weights and optical sizes. Large light titles, small caps
  eyebrows in tracking, tabular numerals for clocks and counts, monospaced only for codes and edge
  numbers.
- Motion: the film advance after the shutter, the frame developing in place, the reaction landing
  on the chip, the shot sliding into the Darkroom, the sheet closing. Each under 350ms and named.
- Glass: on the navigation layer only (section 5).
- The promo cards attached are the feel: quiet, left-aligned, one line, the photograph doing the
  work. The app should feel like the cards feel.

Show the three directions as real screens, not mood boards. The owner judges on his phone.

## 14. The handoff

- **Token values,** in the app's vocabulary (ground, elevated, row, stroke, sheet surface, text
  primary/secondary/tertiary, accent and its five alternatives, success, destructive, disabled,
  error, placeholder; spacing; radii; the nine type roles with their Dynamic Type text styles),
  with contrast measured on the surface each colour sits on, photographs included, at both ends of
  the glass slider. If the palette changed, say what changed and why, one line per token.
- **Component inventory:** every component, its states, its long-content variant, its AX3 variant,
  its VoiceOver label, its Reduce Motion behaviour.
- **Route inventory:** every route, entered from, leaves to, the state it must preserve, and the
  deep links (push, widget, universal link) that land on it.
- **State matrix:** every screen against the nine states of section 8, with the board that shows
  each or the line that says it does not apply.
- **Copy inventory:** every string, old beside new, with the board it is on. The owner vetoes line
  by line.
- **Change map:** A presentation only; B client behaviour; C needs the server (the sheet's table
  and actions, the roll prompt's occasion detection, the push kinds, the admin card); D unresolved,
  as questions.
- **Rollout in batches** scoped by what can be reverted independently, each with the check that
  must pass before the next: look regression pins unchanged; contrast and targets audited on a
  device; captures per active day not falling; response within 24 hours of posting not falling;
  sessions that reach a friend's photograph; rolls created not zero; the sheet's distinct people
  per week and reactions on circled frames in the 48 hours after (never shown to anyone as a
  number).
- **The five-person study,** on the released build: the seven existing tasks plus two for the
  sheet and one for the roll prompt; record the participant's own word for every object before you
  supply it; what would count as a failure.
- **Explicitly incomplete:** drawn but not wired; not drawn; not validated on a device.
- **Where you were wrong during the work,** with the measurement that corrected it.
- No monetization appendix.

## 15. Decisions the owner has not yet made

Ask these at the end of stage 1, in this form, and carry any unanswered one as a drawn pair:

1. **The weekly feature's name.** A: the Contact Sheet, circled (your September 19 decision; film
   object, no other app has it). B: Spotlight (your word today; Instagram and TikTok have it). A is
   recommended. One find-and-replace either way.
2. **Rolls as a tab.** A: keep the tab, redesign the cards and add the prompt. B: fold rolls into
   Camera and Feed, keep the reveal and the off-app surfaces, give the tab's place to the sheet.
3. **Launch surface and tab order.** A: the study decides (say when it runs). B: the design
   decides now, and the study, if it runs, checks it.
4. **Comments.** A: a real labelled control beside the chips, at the cost of card height. B: leave
   comments where they are and accept 3%.
5. **Founding 100.** A: it ends and nothing replaces it. B: a next hundred with a different mark.
   C: invites earn back on more than the first photo.
6. **The export.** A: the date stamp only, as today. B: the date stamp and the handle. C: a way in
   (a code or a link) on the story crop only.
7. **The owner's review.** A: a queue card in the web admin panel. B: an in-app owner mode. C: both,
   web first.
8. **The undo window.** A: five seconds everywhere (the design). B: four in the Darkroom (what
   shipped). One number.
9. **The word for a shot.** Shot, frame, or something else. The grouped card that needs "12 of
   these" is the moment to decide.

## 16. Rules of conduct

- The repo is read only. No production code is touched.
- No simulated people. The calibration photographs are objects and places; where a board needs a
  face, leave a 3:4 placeholder that says so.
- No reviewer panel, no device bezel, no annotations inside the frame. Notes go beside the board:
  the three lines (which loop step it serves, what the owner will see change on his phone, what
  you deliberately left alone) and the answers to section 7.
- Boards at 402pt on the ground, with the tab bar and both safe areas drawn, and beside each the
  375 and 430 variants and AX3.
- Every string you write goes in the copy inventory. No em dashes, no exclamation marks.
- Ask at the end of each stage, in the A/B form. Do not proceed on a guess where the owner has a
  preference you cannot know.

The owner judges everything on his phone, next to the real app, and next to the best apps on it.
Draw for that comparison.
