# FLIM v2 brief, second attempt

Paste everything below the line into a new Claude Design project. Attach, in this order:

1. Six screenshots of the live 1.5.4 build: the feed with a two-frame day, the feed with a
   four-frame day (strip), the sort deck, your own page, a friend's page you follow, Rolls.
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` from the repo (the tokens).
3. Eight calibration photographs from `pairs/` with the shipped look applied, objects and places
   only, no faces.
4. The Italy and Bali promo cards (the feel the owner wants the app itself to have).
5. `docs/prompts/V2_GAME_PLAN_2026-09-19.md` (the record of the first attempt).

The first attempt's package (`Stage 1 design directions.zip`) is deliberately not attached.
Its reasoning survives in the game plan; its look does not come along.

---

## 0. How to read this

You are the design lead on the second attempt at FLIM v2. The first attempt was thorough and
honest and it is not what the owner wants to ship, for reasons in section 2. This document is
long because the owner is giving you the whole picture once, so you can make decisions instead
of asking for them. Read it all before drawing. Sections 4 and 6 are the ones you will be
judged against.

Work in four stages, one turn each, and do not skip ahead: directions, composite, application,
handoff. Each stage ends with a numbered list of decisions you need from the owner, each
written as a question with its two answers and what each answer would change. The owner
answers in one line each; you do not proceed on a guess.

## 1. What FLIM is, as it ships today (1.5.4, build 392)

FLIM is an invite-only iPhone app that is a disposable camera for your friends. You shoot; the
photograph gets one film look baked in at capture, at 3:4, and lands in your Darkroom, where
you decide one shot at a time whether to keep it private, post it to your page, or delete it.
Posting shows it to the people who follow you, and to anyone you tagged. Following is one
way and immediate; nobody approves a follow. The feed groups a person's shots into one unit
per day and you swipe the frames to read the day; reactions (one tap on an emoji chip) and
comments belong to the frame. A roll is a shared camera for one occasion: everyone invited
shoots into it, nobody sees anything until it develops for everyone at once, and the reveal
plays once. A Chapter is a finished month on your page. Activity is where responses to you
collect. There is one film look, no picker, no filters, no scores, no streaks, no ranks, no
public counts.

Tabs, left to right: Camera, Darkroom, Rolls, Feed. The app opens on Camera. Both of those
are under study and are not yours to change (section 4).

The audience, from the nightly numbers on 2026-09-18: 74 accounts; about 27 people open it on
a given day; about 30 shoot in a week and about 29 post; reactions run about ten to one over
comments; 45 to 55 pairs of people answered each other in the last seven days. Everyone who
posted this month was answered, median 37 minutes. Fifteen rolls have ever been made, none
since September 6. The goal for the next six months is 100 people who open it on an ordinary
Tuesday, and it will get there by the everyday loop, not by rolls: see a friend's day, answer
it, shoot one of your own, get answered, come back.

## 2. Why the first attempt was set aside, and what it got right

The owner's words: "I didn't like how it looked." The specifics, so you do not repeat them:

- It brought its own design system (a blue-grey ground, a violet accent, Inter, outlined
  buttons, "rules that fade at the ends"). FLIM has an identity: near-black, one warm amber,
  SF Pro, the photograph as the only colour on the screen. The attempt looked like a design
  tool's default dark theme with FLIM's content poured in.
- It shrank the photograph (336 by 448 inset at 402pt, against the shipped 370 wide) to make
  room for chrome. The photograph is the product. Chrome yields to it, never the reverse.
- It put a tap in front of reactions (a labelled React control opening a tray). Reactions are
  one tap today and stay one tap.
- It redesigned things the owner had already decided or was about to measure (launch surface,
  tab order, the reveal's one-shot rule, Activity's read watermark, the inviter auto-follow).
- Its boards had a reviewer panel, a device frame and a dense handoff voice that read as a
  document about an app rather than an app. The owner judges on his phone, next to the real
  thing. Draw for that comparison.

What it got right, and what you keep: response as prominent as authorship (Comment as a real
control); the audience stated in words at the moment of sharing; honest capture states; one
sorting vocabulary; the discipline of measuring a claim before writing it; the route
inventory, change map, rollout batches and five-person study as the handoff shape; and the
list of decisions it could not make alone, put to the owner as questions.

## 3. The standard

Ten out of ten. Something a large company with a hundred designers would ship, made by two
people with the tools that now exist. Concretely:

- Put any board next to a screenshot of Apple Photos, Apple Journal or the Instagram feed on
  the same phone. It should belong to that company, at that level of finish, and still be
  unmistakably FLIM. If it looks like a prototype beside them, it is not done.
- Every screen has one thing it is for, and that thing is above the fold at 375pt with the tab
  bar drawn. Everything else steps back.
- The photograph is the only saturated colour on the screen; the accent is a mark, never a
  field. Type is SF Pro at the nine roles the app already has. Nothing essential under 13pt.
  Film character lives in the photographs and in a few deliberate details (the strip's
  perforation rail, the seven-segment date on exports, the grease pencil in section 6), never
  as grain over controls or as hardware cosplay.
- Motion says what happened: a reaction lands, a shot slides into the Darkroom, the sheet
  closes. Nothing decorative, everything under 350ms, all of it honouring Reduce Motion.
- Measure in the frame, then write the sentence. Every number in your handoff was measured
  on your own rendered board, not estimated.
- The copy is the design. Plain, warm, specific. FLIM's own words: roll, develop, Darkroom,
  keep private, post to page, chapter, circled. No exclamation marks. No em dashes anywhere,
  in copy or in your notes. Never "friends" where the truth is "people who follow you".

## 4. Non-negotiable. Given, not up for design

Identity and tokens (from the attached `Theme.swift`, use them verbatim):

- Ground #0A0A0A; elevated surface white 8%; row white 6%; stroke white 14%; sheet surface
  #1C1C20 at 96%. Text white, white 62%, white 55% (measured, AA on every surface they sit
  on). Success #7FD29A, destructive #FF453A, disabled white 38%.
- One accent per person, amber #FABD5C by default, five alternatives the person chooses in
  Settings. One accent per screen, always the viewer's. Accent soft is the accent at 16%.
- Spacing 2 4 6 9 12 16 22 28 36. Radii: 6 photograph in grids, 12 control and feed card,
  14 panel, 16 sheet, 28 viewfinder, capsule for pills. Targets 44 by 44 minimum.
- Type: 34 Display (reveal cover only), 26 Hero, 20 Interstitial, 17 Unit title, 15 Action,
  13.5 Body, 12.5 Meta, 11 Micro (the floor). Every text scales with Dynamic Type; glyphs in
  fixed chrome and type burned into exports do not.
- The photograph is 3:4 everywhere. In the feed it is screen width minus 32pt, radius 12. It
  never gets smaller to make room for anything. Grids are 3:4 too; the one square is the
  avatar picker.

Behaviour the owner has decided, or is measuring, and you leave exactly as it is:

- Camera-first launch and the tab order Camera, Darkroom, Rolls, Feed. A five-person study
  on the released build decides both. You may note, once, in the handoff, what you would
  test; you draw nothing that assumes a different answer.
- Reactions are one tap on a visible chip. You may resize, reorder, relabel or move the
  chips; you may not put a tap, a tray or a long-press between the person and the chip.
- The reveal plays once per roll and re-presents until watched to completion. Activity marks
  everything before your last visit as read. The inviter is followed for you at sign-up. A
  new account's first sort lands in the Darkroom. Rolls cannot be renamed; a roll's invites
  end when it develops. None of these are bugs.
- No scores, streaks, ranks, leaderboards, public counts, "top", "trending", "most". Reaction
  chips show a count on the chip because that is the reaction; nothing aggregates above it.
- No monetization on any board. No onboarding redesign in this attempt (it shipped in 1.5.3
  and is being measured). No look change to the photographs themselves (the look is pinned
  by regression tests; a separate lab handles it).
- No new design system, no exported tokens, no new typeface, no second accent, no light mode.

## 5. The questions every board must answer out loud

The first attempt asked six questions of the navigation and answered them in one line each.
Keep that habit, with this list. Write the answer under the board it belongs to.

1. Where do I see my friends' day, and how do I know what is new since I last looked?
2. How do I answer a specific photograph, in one gesture, and how do I know it landed?
3. Where do my private photographs live, and how do I know which are still unsorted?
4. How do I know someone answered me, and how do I get to exactly that frame?
5. Where do my shared photographs live over time?
6. Where does a roll belong, and how do I know one is waiting on me?
7. Where does the best of this week go, who can see it there, and what happens on Monday?
8. What does the app look like the first time, with one friend and one photograph?
9. What does it look like with no connection, and what did I lose? (Nothing. Say so.)

## 6. The new thing: the Contact Sheet

The owner wants a weekly place for people's best photographs, where a person puts one forward
and, once a week, a few are chosen and shown. It must not be called Spotlight, Featured,
Highlights, Best of, or Picks; other apps own those words and none of them are film. This is
the feature that most needs your judgement, so it gets the most words.

### The name and the mechanic

**The Contact Sheet**, and the verb is **circled**.

A contact sheet is the page of small positives a photographer prints from a whole roll to
choose from, and the chosen frames are circled on it with a red grease pencil. That is the
whole feature, in an object every film photographer recognises and nobody else has used:

- Each week there is one sheet, shared by everyone on FLIM. It opens Monday at 04:00 Eastern
  (the app's day boundary) and closes Sunday at 23:59.
- Each person may put **one frame** on the sheet per week, from anything they posted that
  week. One, like the 36 exposures on a roll: scarcity is the point, and it is why nobody
  needs to be told to post their best.
- Monday morning the owner circles a handful, with the grease pencil. Circled frames stay
  circled forever. Nothing else changes: the uncircled frames are still on the sheet, in
  their place, not demoted, not counted.
- Nobody votes. There are no counts on the sheet, no ordering by response, no "most". Frames
  sit in the order they were put up. The circle is an editor's mark, not a score.
- Past sheets stay, one per week, so the archive reads like a box of sheets: "Week of
  September 14", "Week of September 7".

The copy uses the object: "Put it on the sheet." "On this week's sheet." "The sheet closes
tonight." "Your frame was circled." "Circled, week of September 14." Never "submit",
"entry", "winner", "selected", "featured".

### What the owner needs you to decide, and show

- **Where it lives.** Not a fifth tab. Show two placements and pick one: at the top of the
  Feed as a horizontal sheet the person can scroll (the sheet is social, the feed is where
  people look), or as the top of Rolls (the Rolls tab is quiet, and a sheet is a roll everyone
  shares). Say what your choice costs the everyday loop at 375pt.
- **The moment of putting a frame up.** From the frame itself (your own post, in the feed or
  on your page) and from the sort deck at the moment of posting ("Post to page, and put it on
  the sheet"). It must say, in words, before the tap lands: everyone on FLIM will see it
  there, not only the people who follow you, and anyone you tagged is told. Show the
  confirmation, the undo (the app is undo-first), and the withdraw path until the sheet
  closes. Show what happens when the person already has a frame up this week (swap, with the
  old one coming down, stated).
- **The sheet itself.** A grid of 3:4 positives on the dark ground with the film rebate
  drawn as a hairline, one row of frames per scroll line, the viewer's own frame marked as
  theirs without a badge. Tapping a frame opens the frame with its reactions and comments,
  exactly as it opens from the feed; the sheet does not get its own viewer. Show the sheet
  with 3 frames, with 40, and with 0 (the first hour of a Monday, and the very first week).
- **Monday morning.** The circled frames carry a hand-drawn red-orange grease-pencil circle
  over the frame's corner of the sheet, slightly off-round, drawn once and never animated
  after the first reveal. The person whose frame was circled gets one push ("Your frame was
  circled") that lands on the sheet, scrolled to their frame. Nobody else gets a push about
  circling. Show the sheet the morning after, the frame page of a circled frame (the circle is
  visible there too, quietly), and the person's own page (a circled frame in the grid carries
  the mark at grid size; test that it survives at 3:4 thumbnails of 120pt).
- **The one reminder.** At most one push per week, Sunday evening, only to people who posted
  that week and put nothing up: "The sheet closes tonight." Show the notification and where
  it lands. Never a push to people who did not post; the sheet is not a reason to post for
  strangers.
- **A new person's first week.** How someone with one friend and one photograph learns the
  sheet exists without a tour: the empty sheet's line, the first-visit line on the tab that
  hosts it, and the sort deck's mention. One sentence each, in the copy inventory.
- **Deletion and privacy.** Deleting the post takes the frame off the sheet, past weeks
  included, and removes a circle with it. Blocking someone hides their frames from your sheet
  and yours from theirs. A frame on the sheet is readable by every signed-in account and by
  nobody outside the app; say that in the privacy line the owner will paste into the policy.
- **What it must never become.** A leaderboard, a popularity contest, a reason to post for an
  audience you did not choose, a place where the owner's taste reads as a ranking of his
  friends, or a second feed that competes with the first for the fold. If a board makes the
  sheet louder than a friend's day, the board is wrong.

### What exists, and what this needs, so your handoff is honest

Posts, tags, reactions, comments, blocks, the day boundary, the push pipeline, one-shot
push campaigns and the owner's admin panel all exist. New: one table (post, week key, put up
at, circled at, withdrawn at), readable by every signed-in account, writable only by the
post's owner, with one-per-person-per-week enforced at the database; one owner-only action
to circle; two push kinds; a week-key rule for the 04:00 boundary; and a sheet rendition is
not needed (the feed rendition at 1400 long edge already serves grids). The owner's session
will build it; your job is to say what the person sees and when.

## 7. The boards, in order

One board per item, at 402pt, on FLIM's ground, with the tab bar and both safe areas drawn.
Beside each: the 375pt and 430pt variants, and the AX3 Dynamic Type variant (the largest the
app lays out for). Above each board, three lines: which of the five loop steps it serves,
what the owner will see change on his phone, and what you deliberately left alone.

1. **Foundations, restated.** Not a new system. One board showing FLIM's own tokens used at
   their best: the nine type roles in real sentences, the accent as a mark, the photograph on
   the ground with and without a caption, the grease pencil, the strip rail. This is your
   calibration, and the owner's proof that you read section 4.
2. **The feed card.** Comment is a labelled control at 44pt beside the reaction chips, without
   shrinking the photograph or adding a tap to a reaction (3 percent of responses are comments
   today; the entry is a faint line). The two-frame case ("1 of 2" and dots) and the strip
   from three. The "new since you looked" seam. The live count at the top ("5 shots from 2
   friends") that counts down as frames are reached, and the tap that jumps to the first
   unseen.
3. **The Contact Sheet.** Everything in section 6: placement, the sheet at 0, 3 and 40 frames,
   putting a frame up from a post and from the sort deck, swap, withdraw, Monday morning, the
   two pushes, the archive, the first week.
4. **Your own page.** The identity header takes less of the top third; the newest posts have a
   home before a month's Chapter exists; a circled frame carries its mark in the grid; the
   invite code is one tap away; the empty page (no posts yet) has one route to the camera.
5. **Someone else's page**, three states: you follow them; you do not (profile visible,
   photographs not, one Follow button, the reason you might know them); the follow is in
   flight (the grid never flashes empty).
6. **Rolls.** The four card states (waiting, ready to open, opened, full); "Start another with
   this group" after a reveal; a default name from the date; and the roll prompt, an
   invitation to start a roll from an occasion the app can see (three friends shooting the
   same evening), declinable in one tap with no consequence, never automatic.
7. **Camera and the sort deck.** The destination stated under the viewfinder (personal, or a
   named roll) and never over it; capture states in honest words (on this phone, uploading,
   waiting for connection, uploaded); the one sorting vocabulary (Keep private, Post to page,
   Delete) with the audience sentence and the sheet mention at Post.
8. **Activity.** Rows that say what happened and open the exact frame; Follow back as its own
   control; the unavailable case ("a photo that isn't available" without saying what it
   was); the circled row.
9. **The state board.** Every screen above under cold start, slow network, offline, refused
   camera permission, long content (a 240-character caption, a 40-comment thread, a name at
   the field limit) and AX3, at 375 and 430.
10. **The copy inventory.** Every string on every board, old beside new, one table, with the
    board it appears on. The owner vetoes line by line.

## 8. The handoff, at the end

Same discipline as the first attempt, on FLIM's tokens rather than new ones:

- Token values to type into code: none new unless a board needed one, and then the one
  value with the reason and the contrast measured on the surface it sits on.
- Route inventory: every route, entered from, leaves to, and the state it must preserve.
- Change map: A presentation only; B client behaviour; C needs the server (the sheet's table
  and RPC, the two push kinds); D unresolved, as questions.
- Rollout in batches scoped by what can be reverted independently, each with the check that
  must pass before the next: look regression pins unchanged; contrast and targets audited on
  a device; captures per active day not falling; response within 24 hours of posting not
  falling; sheet: distinct people putting a frame up per week, and reactions on circled frames
  in the 48 hours after circling, never shown to anyone as a number.
- The five-person study on the released build, with the sheet added to the seven existing
  tasks as two more: put your best photo from this week where everyone can see it; find
  which frames were circled this week. Record the participant's own word for the sheet and
  for the circle before you supply either.
- Explicitly incomplete: drawn but not wired, not drawn, not validated on a device.
- Where you were wrong during the work, with the measurement that corrected it.
- No monetization appendix. If you have a thought about money, one paragraph, at the very
  end, clearly marked as outside the brief.

## 9. Rules of conduct

- No production code is touched; the repo is read only.
- No simulated people. The calibration photographs are objects and places; if a board needs
  a face, leave a 3:4 placeholder that says so.
- No reviewer panel on the boards, no device bezel, no annotations inside the frame. Notes go
  beside the board, in the three lines and the answers to section 5.
- No claim without a measurement. "Above the fold" means you measured the fold on your board
  at 375pt with the tab bar drawn.
- Every string you write goes in the copy inventory. No exclamation marks, no em dashes, no
  "friends" where the truth is followers, no "submit", "entry", "winner", "featured".
- Ask at the end of each stage, in the A/B form. Do not proceed on a guess where the owner
  has a preference you cannot know.

The owner judges everything on his phone, next to the real app, and next to the best apps on
it. Draw for that comparison.
