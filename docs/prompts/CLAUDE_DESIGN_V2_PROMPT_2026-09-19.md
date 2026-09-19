# Prompt for Claude Design: FLIM v2, second attempt

Paste everything below the line into a new Claude Design project. Attach: three screenshots
of the live app (feed with a multi-shot day, the sort deck, your own page), the Italy and Bali
promo cards, and docs/prompts/V2_GAME_PLAN_2026-09-19.md from the repo.

---

You are designing the next version of FLIM, an invite-only iPhone app that is a disposable
camera for your friends. You shoot, the photo gets one film look baked in at capture, it lands
in your Darkroom, and you decide whether to keep it private or post it to your page, where
only the people who follow you see it. A roll is a shared camera for an occasion; nobody sees a
roll's shots until it develops for everyone at once. A Chapter is the month you shared, on
your page. 75 people use it; the goal is 100 who open it on an ordinary Tuesday.

This is the second attempt at v2. The first one is attached as a game plan; read its section
"What the first attempt got wrong" before you draw anything. The short version: it made the
photograph smaller to fit chrome, it made a one-tap reaction a two-tap one, it brought its own
design system instead of FLIM's, and it redesigned things the owner had decided or was about
to measure. Do none of that.

## The one job

Tighten the everyday loop: see a friend's day, answer it, shoot one of your own, get answered,
come back. Every screen you touch must make one of those five steps easier, and you must say
which one, in one line, on the board.

## What you are given and must keep

- FLIM's identity: near-black ground (#0A0A0A), one amber accent (#FABD5C; the person can pick
  five others, all warm or cool but never a second accent on one screen), SF Pro, film grain in
  the photographs only, an orange seven-segment date stamp on exports. The app's own tokens are
  attached (FlimTheme roles, spacing 2/4/6/9/12/16/22/28/36, radii 6/12/14/16/28, the type roles).
  Use them. Do not bring another palette or typeface.
- The photograph is 3:4, always, at its current width in the feed (screen width minus 32pt,
  radius 12). It does not get smaller to make room for anything.
- Reactions: the emoji chips stay one tap. You may relabel, resize or reorder around them; you
  may not put a tap in front of them.
- Camera-first launch and the current tab order (Camera, Darkroom, Rolls, Feed). A usability
  study decides those; you do not.
- The inviter is followed for you at sign-up. Activity marks everything before your last visit
  as read. The first sort of a new account lands in the Darkroom. Posts are readable by
  followers plus anyone tagged, never "friends" in copy.
- Copy rules: plain, warm, specific, no exclamation marks, no em dashes, the app's own words
  (roll, develop, Darkroom, keep private, post to page, chapter). Every string you write goes in
  a copy inventory table for the owner to veto.
- No scores, streaks, ranks, public counts, or anything that turns a friend into a number.

## What to design, in order, one board each

1. **The feed card.** The comment action is invisible today (3 percent of responses are
   comments; the entry is a faint "Add a comment" line). Make Comment a labelled, 44pt control
   that sits beside the reaction chips without shrinking the photograph or adding a tap to a
   reaction. Show the two-frame case ("1 of 2" with dots) and the strip from three. Show it at
   375, 402 and 430pt and at the largest accessibility text size the app supports (AX3).
2. **Your own page.** The identity header takes less of the top third; the newest posts have a
   home before a month's Chapter exists; the invite code is one tap from a push. Show the empty
   page (no posts yet) with one route to the Darkroom.
3. **Someone else's page** in the three states: you follow them; you do not (the profile is
   visible, the photos are not, one Follow button, the reason you might know them); the follow is
   in flight (the grid does not flash empty).
4. **The roll cards and the roll prompt.** Waiting, ready to open, opened, full. Then the one
   new thing: a prompt to start a roll from an occasion the app can see (three friends shooting
   the same evening, a burst of shots in one place). It is an invitation, never an automatic
   roll, and it must be declinable in one tap with no consequence.
5. **Activity.** Rows that say what happened and open the exact frame; the unavailable case
   ("a photo that isn't available" without saying what it was); Follow back as its own control.
6. **The copy inventory.** Every string on every board, old and new side by side.

## How to deliver

One static board per screen, drawn at 402pt on FLIM's ground with the attached tokens, with
the compact and large widths and the AX3 variant beside it. A reviewer panel is fine but say
so. No simulated backend, no demo people who look real (use the attached calibration
photographs of objects and places, never faces), no monetization, no onboarding redesign (that
is a later phase). Do not produce a design system export; the app has one.

Before each board, write three lines: which of the five loop steps it serves, what the owner
will see change on his phone, and what you deliberately left alone. After all six, write the
list of decisions you could not make without the owner, each as a question with the two answers
and what each would change.

The owner judges everything on his phone, next to the real app. Draw for that comparison.
