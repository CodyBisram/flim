# Brief for Claude Design: FLIM's first five minutes

Written 2026-09-08. Paste the block below into Claude Design as the opening prompt. Numbers are
from production, accounts created since 2026-08-01 (38 people), read on 2026-09-08.

---

I'm redesigning the first five minutes of FLIM, an invite-only iPhone app that is a disposable
camera with one film look. You point and shoot, the frame comes back with the look already on it.
Your own shots are ready right away in a Darkroom, where you keep them or post them to a page
that only the people who follow you can see. A shared roll is the other half: friends shoot into
one roll and nobody sees a frame, not even their own, until it develops twelve hours later, for
everyone at once. The app is dark only. Every share carries an orange segment-display date stamp,
like a 90s date back.

WHAT THE FIRST FIVE MINUTES ARE TODAY, in order:

1. A splash, then the email screen: "Shoot now. See it later. Enter your email to get started."
   Below the email field, a collapsed "Have an invite code?" row. If the email is not already
   allowlisted the row opens and reads "You'll need an invite code to join". Codes are six
   characters. Most people arrive from a friend's personal invite link, which shows the code on
   a web page and sends them to the App Store, so they are typing a code they saw a minute ago.
2. A six-digit code arrives by email. "Check your email." with a "No code yet? Check your spam
   folder." line.
3. Username screen: "Pick a username." with rules, an optional first name, and "PICK YOUR
   COLOR", a row of accent swatches that recolour the whole app.
4. Three onboarding cards, swiped, with a Skip: "Shoot now." (the look, no filters), "Sort your
   shots." (instants ready now, rolls develop together), "Share the moment." (post, follow,
   react, invite-only). The last card's button says "Take your first shot" and triggers the
   camera permission dialog.
5. The camera. A full-width 3:4 viewfinder, a shutter, a flash toggle, a roll picker. The first
   shot lands in the Darkroom.
6. Later, on the feed, a notification primer sheet: "Don't miss the reveal", "Turn on
   notifications" or "Not now".

THE NUMBERS, for the 38 accounts created since August 1:
- 36 launched the app; 28 finished the cards (8 skipped or left mid-way).
- 26 have taken at least one photo. 12 have never taken one.
- Median time from account creation to first shot: 130 minutes. The button says "Take your
  first shot" and the first shot happens two hours later, if at all.
- 11 of 38 have taken ten or more.
- 21 have posted to their page. 8 have joined a roll, 3 have started one, 5 have watched a
  reveal. The reveal is the moment the product is built around and 5 of 38 have seen it.
- 16 turned notifications on, 3 said no, 17 were never asked or dismissed the primer.
- 7 redeemed a personal invite code; the rest were let in by email allowlist.

THE ONE PROBLEM TO SOLVE:
The first five minutes explain the product instead of producing a photograph. A person types a
code, a username, picks a colour, reads three cards about shooting, sorting, and sharing, grants
camera access, and then a third of them never press the shutter and the rest wait two hours.
Design a first run whose only goal is a first frame in the Darkroom within the first minute of
having the app open, and a first look at what a roll is within the first session, with the
explaining done by the thing itself rather than by cards about it.

SECONDARY GOALS:
- The invite is the way in and it is also who brought you. A personal invite code is the only
  thing that opens the door, and it names a person: make that person the first follow, and
  design the moment the code resolves into a name. A roll code is different and comes later: it
  only joins an existing member to a roll, it does not admit anyone, and a new person who was
  sent one still needs a personal code first. Design what happens when someone arrives holding a
  roll code and no account.
- Username, name, and colour are three decisions before anyone has seen a photograph. Decide
  what can wait, what can be defaulted, and what is worth asking up front. The colour picker is
  loved once people find it; it does not have to be step three.
- The camera permission ask should feel like part of picking up the camera, not a dialog after a
  slideshow. The notification ask should arrive at the moment it makes sense: when the first
  roll starts developing and there is something to be told about.
- Design the first Darkroom with one photo in it and the first roll with one frame in it, as real
  states. Today they are the general screens with less in them.
- A returning person (signed in, second launch) must never see any of this again.

HARD CONSTRAINTS:
- 393pt wide, portrait, dark only. Near-black background, white text, grey secondary text.
- The accent colour is chosen by each user (default warm amber) and must work as any hue. Use it
  for one action at a time.
- Sign-in is email plus a six-digit emailed code, and the app is invite-only. Neither changes.
  No phone numbers, no social sign-in, no "continue as guest".
- No tutorial overlays with arrows, no coach marks, no progress bars, no confetti, no
  gamification.
- Photographs are 3:4, never cropped square, never with text over them except the app's own
  date stamp. Use warm film-look photographs with soft grain and dark corners as content.
- No em dashes in copy. Short declarative sentences. No exclamation marks. The app is written
  FLIM in caps.
- The camera screen's layout (viewfinder, shutter, flash, roll picker) is not in scope; design
  what happens around it, not inside it.

ARTBOARDS I WANT BACK:
1. The whole first run as a flow, from App Store open to first frame in the Darkroom, one
   artboard per screen, with the elapsed time you expect at each step.
2. The moment a personal invite code resolves into the person who sent it, and what a new
   person sees when they arrive holding only a roll code.
3. The first Darkroom with one photograph in it, and the first roll with one frame in it.
4. Where the notification ask lives in your flow, and what it says.
5. Everything you removed from today's flow, listed, with one line each on where it went
   (later, defaulted, or gone).

Make the flow tappable end to end so the pacing can be felt. Show at most two directions for
the overall approach, label which you recommend, and say why in three sentences or fewer. If a
constraint makes something impossible, say so rather than bending it.
