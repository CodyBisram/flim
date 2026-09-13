# FLIM usability study: five people, six tasks, one afternoon

Written 2026-09-13 from the UI and social audit's proposal, for the owner to run before the
version 2 redesign. It is the only item on that audit's list that tells us what a redesign
should fix, rather than what an auditor thinks it should. Nothing here needs code.

## Who

Five people, not close friends who already know the app inside out:

| Seat | Who | Why |
|---|---|---|
| 1, 2 | Two people who used Lapse's old social version | They carry expectations FLIM either meets or breaks |
| 3, 4 | Two newcomers who are joining a friend already on FLIM | The real first session, with a real reason to be here |
| 5 | One current FLIM user who opens it less than weekly | Knows the surfaces, has not built habits around them |

Recruit by message: "Would you spend 30 minutes trying an app while I watch and take notes? I
will not help you and that is the point. Coffee on me." Book them one at a time, 40 minutes
apart, so you can reset between sessions.

## Setup, the night before

- Two test accounts on two phones: the participant's account (fresh, made through a roll link
  from you so the first run is the real one) and yours as the friend. Use codes that are not
  public ones, so the study does not skew the FLIMGO numbers.
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

## The six tasks

Say each one in these words, one at a time, and start the timer.

1. "Find me on FLIM and look at the newest photo I posted."
2. "React to my second-newest photo, then leave a comment on that exact photo."
3. "Take a photo of anything. Keep it just for yourself. Take another and post it. Then tell me
   who can see each one."
4. (Send them a reply to their comment from your phone.) "Something just happened. Open it and
   answer me."
5. "Join the roll I started, shoot into it, and tell me when everyone gets to see the photos."
6. "Find something I posted last month and save one of my photos to your phone."

Task 6 is expected to end in a refusal on a friend's chapter: only rolls and your own photos can
be saved. What matters is whether they understand why, not whether they succeed.

## What to write down, per task

- Time from your last word to done, or to giving up.
- Every wrong turn: which screen they went to that was not on the way.
- Every hesitation over three seconds, and where the finger was hovering.
- Their answer to "what do you expect this button to do," verbatim, before they tap.
- For task 3: their words for who sees the kept photo and who sees the posted one.
- For task 5: their words for when the roll shows.
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
Task 6  time ____  found last month? Y/N  understood why saving was refused? Y/N
Unprompted: _______________________________________________________________
Would you use this with your friends? "___________________________________"
```

## Afterwards

Ask three questions and write the answers down: "What was the app for?" "What did you expect
to happen that didn't?" "Who would you invite?" Then thank them. Do not explain the app.

Put the five sheets side by side. A wrong turn made by three of five people is a design problem.
A wrong turn made by one is that person. Anything three people misread about who sees a photo
or when a roll shows is the first thing the redesign fixes. The counts go into the next planning
note next to the funnel numbers in docs/METRICS.md, so the redesign starts from both.

## Accessibility add-on, if a participant is willing

Ask seat 5 to turn on VoiceOver for task 1 and the largest text size for task 3. Note whether
they can still find you and still tell who sees what. That is the rendered check the
accessibility pass could not do from a computer.
