# FLIM usability study: five people, six tasks, one afternoon

Written 2026-09-13 from the UI and social audit's proposal, for the owner to run before the
version 2 redesign. It is the only item on that audit's list that tells us what a redesign
should fix, rather than what an auditor thinks it should. Nothing here needs code.

Revised 2026-09-14 after the everyday audit and the v2 package: newcomers arrive three
different ways instead of all through a roll link, the archive task is split in two so a
refusal can be told apart from a failure to find the control, and three observations were
added that decide the two v2 questions the owner sent to the study: whether FLIM should open
on the feed, and whether the tab order should change. **Run it on the released 1.5.3 build**,
the App Store one, not TestFlight and not the v2 build: the study measures the app people
have, and its findings decide what v2 changes.

## Who

Five people, not close friends who already know the app inside out:

| Seat | Who | How they arrive | Why |
|---|---|---|---|
| 1 | Used Lapse's old social version | Your personal invite link (`/i/CODE`) | Expectations FLIM either meets or breaks; the invite preview names you |
| 2 | Used Lapse's old social version | A roll link, to a roll you started | Same expectations, the occasion door |
| 3 | Newcomer joining a friend already on FLIM | Your personal invite link | The real first session, with a real reason to be here |
| 4 | Newcomer, no friend on FLIM | A cohort code typed by hand (make one for the study; see docs/METRICS.md, invite campaigns) | The honest cold start: nobody to follow, has to find someone |
| 5 | Current FLIM user who opens it less than weekly | Their own account | Knows the surfaces, has not built habits around them |

Three doors on purpose. The first version of this study sent every newcomer through a roll
link, which would have measured the occasion journey and told us nothing about everyday sharing.
Seat 4 is the one the v2 package calls the no-known-person path; watch it closely.

Recruit by message: "Would you spend 30 minutes trying an app while I watch and take notes? I
will not help you and that is the point. Coffee on me." Book them one at a time, 40 minutes
apart, so you can reset between sessions.

## Setup, the night before

- Two phones: the participant's (a fresh account, made through whichever door their seat
  says) and yours as the friend. Make a study-only cohort code for seat 4 and use your own
  personal link for seats 1 and 3, so the study does not skew a public campaign's numbers.
- Your account needs: at least ten posts across two days, one open roll with a few frames from
  you, one developed roll with a reveal the participant has not watched, and one chapter.
- Seat 5 uses their own account; ask permission to watch, not to record content.
- One sheet of paper per person (the recording sheet below). A phone timer.
- Reset between sessions: delete the previous participant's test account (Profile, Delete
  Account), create the next roll link.

## The rule

You say the task, then nothing. No hints, no "try the tab on the right," no reacting to a wrong
turn. If they stop, wait ten seconds, then ask "What do you expect to happen if you tap that?"
and write the answer down before they tap. Only when they give up do you show them, and you
write down that you had to.

## The seven tasks

Say each one in these words, one at a time, and start the timer. Tasks 1 to 4 are the
everyday loop and matter most; 5 is the occasion; 6 and 7 are memory and ownership.

0. (Before task 1, the moment they land after sign-up, say nothing and write down where they
   go first and what they tap. Then:) "Imagine it's an ordinary Tuesday and you just opened
   this. What would you do first?" Write the answer verbatim. This one observation is what
   decides whether FLIM should open on the feed.
1. "Find me on FLIM and look at the newest photo I posted." (Seat 4: "Find someone you know on
   FLIM." If they know nobody, the honest outcome is that they say so; write down what the
   app offered them instead.)
2. "React to my second-newest photo, then leave a comment on that exact photo."
3. "Take a photo of anything. Keep it just for yourself. Take another and post it. Then tell me
   who can see each one."
4. (Send them a reply to their comment from your phone.) "Something just happened. Open it and
   answer me."
5. "Join the roll I started, shoot into it, and tell me when everyone gets to see the photos."
   (Seat 2 is already in it: "Shoot into the roll you joined, and tell me when everyone gets
   to see the photos.")
6. "Find something I posted last month."
7. "Save one of the photos you took today to your phone. Now try to save one of mine from last
   month, and tell me what you think happened."

Task 7 is expected to end in a refusal on a friend's chapter: only rolls and your own photos
can be saved. Splitting it from task 6 is deliberate: finding last month and understanding the
ownership rule are two different things, and the first version of this study could not tell a
person who never found the control from a person who found it and was refused.

## What to write down, per task

- Time from your last word to done, or to giving up.
- Every wrong turn: which screen they went to that was not on the way.
- Every hesitation over three seconds, and where the finger was hovering.
- Their answer to "what do you expect this button to do," verbatim, before they tap.
- For task 3: their words for who sees the kept photo and who sees the posted one.
- For task 5: their words for when the roll shows.
- For task 0 and every return to the home screen afterwards: which tab they reach for. FLIM
  opens on Camera; the feed is the fourth tab. Count how many times a person looking for their
  friends' photos taps something other than that tab first.
- Their own word for each thing: "roll", "chapter", "darkroom", "keep". Never supply it.
- Anything they say unprompted. "Oh" and "huh" count.

## The recording sheet

```
Participant ____   Seat ____   Phone ____   Date ____

Task 1  time ____  done / gave up   wrong turns: ______________________
        expected: ______________________________________________________
Task 2  time ____  done / gave up   wrong turns: ______________________
        reacted on the right photo? Y/N   commented on the right photo? Y/N
Task 3  time ____  kept: who sees it? "________________" posted: "________________"
Task 4  time ____  found the notification? Y/N  replied in the thread? Y/N
Task 5  time ____  joined? Y/N  shot? Y/N  "everyone sees it ________________"
Task 6  time ____  found last month? Y/N   wrong turns: ______________________
Task 7  time ____  saved own? Y/N  found the control on mine? Y/N  understood the refusal? Y/N
Task 0  first tap: __________  "on a Tuesday I'd ________________________________"
        taps before reaching the feed, over the whole session: ____
Their words:  roll "______"  chapter "______"  darkroom "______"  keep "______"
Unprompted: _______________________________________________________________
Would you use this with your friends? "___________________________________"
```

## Afterwards

Ask five questions and write the answers down: "What was the app for?" "Who can see the photo
you posted?" "What did you expect to happen that didn't?" "What would bring you back tomorrow?"
"Who would you invite?" Then thank them. Do not explain the app.

What counts as a failure, before you tally anything else: anyone answering "only my friends"
or "only approved people" to the audience question; anyone reaching for Post when they meant
Keep; anyone unable to find the reply that arrived; anyone who cannot say what a roll is after
joining one.

Put the five sheets side by side. A wrong turn made by three of five people is a design problem.
A wrong turn made by one is that person. Anything three people misread about who sees a photo
or when a roll shows is the first thing the redesign fixes. The counts go into the next planning
note next to the funnel numbers in docs/METRICS.md, so the redesign starts from both.

The two v2 decisions this study settles (docs/V2_RECONCILIATION.md, conflicts #1 and #2):

- **Feed-first launch.** Yes if three or more of five, on task 0 or on an ordinary return,
  went looking for friends' photos before the camera, or said so for their Tuesday. No if three
  or more reached for the shutter. Two and two means the launch stays as it is and the question
  waits for more people.
- **Tab order.** Yes if the tally of "taps before reaching the feed" is three or more for three
  or more people. That is people failing to find the fourth tab, which reordering fixes; a
  person who found it once and never lost it again is not a vote.

## Accessibility add-on, if a participant is willing

Ask seat 5 to turn on VoiceOver for task 1 and the largest text size for task 3. Note whether
they can still find you and still tell who sees what. That is the rendered check the
accessibility pass could not do from a computer.
