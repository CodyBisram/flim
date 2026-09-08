# Brief for Claude Design: the FLIM profile page

Written 2026-09-08, after 1.5.1 shipped. Paste the block below into Claude Design as the
opening prompt. It is data-led on purpose: what the page is, what is on it, the numbers, one
problem to solve, the constraints, and the artboards wanted back.

---

I'm redesigning the profile page of FLIM, an invite-only iPhone app that is a disposable camera
with one film look. You point and shoot, the frame comes back with the look already on it, and
if you post it, it goes to a feed of only the people who follow you. There is no algorithm and
no public feed. Every share carries an orange segment-display date stamp in the bottom corner,
like the date back on a 90s point-and-shoot. The app is dark only.

WHAT THE PROFILE PAGE IS TODAY, top to bottom, on a 393pt iPhone:

1. A cover photo band, 150pt tall, that runs up behind the status bar and fades into the page
   at the bottom. The back and settings buttons sit over it in their own circular scrims.
2. A round avatar, 88pt, overlapping the bottom edge of the cover. Up to four earned badges
   flank it, two per side, as small text pills. A badge is a small honour like being among the
   first hundred accounts, or having shot the most in a roll. Tap a pill and the handle line
   below swaps to a one-line explanation of the badge for a few seconds, then swaps back.
3. Display name, 22pt light. Under it the @handle, 13pt, with the account's signup number
   pinned to the right edge in a tiny monospaced "edge number" style, like frame numbers on
   film. A "Follows you" pill appears under that when true.
4. Bio, centred, up to three lines.
5. Three stats in a row: shared, followers, following. Shared is the number of posts.
6. Buttons. Someone else's page: one full-width Follow / Following pill. Your own page: Edit
   profile beside an accent Invite button that carries your remaining invite count.
7. The Chapters shelf: a horizontal row of covers, one per finished month, newest first. A
   chapter is that month's shared photos played back like a reveal, ending on a stats card
   (most reacted shot, biggest fan, the hour you shoot at, longest streak, and so on). The
   owner chooses which stats other people see. Only finished months appear; the current month
   is not there until it ends.
8. The grid: every shared photo, 3 columns, 3:4 frames, grouped under month labels, newest
   month first. Tap a frame and it opens as the post with its reactions and comment thread.
9. Empty states: a first-time page with no posts, and a blocked-account panel that replaces
   the grid.

THE NUMBERS, from production today:
- 55 accounts, 36 with at least one post.
- Median 12 posts per posting account, max 214.
- Median 8 followers, max 54. This is a small-circle app by design; a page is seen by
  people who know the person.
- Median 2 months with posts, max 3. The app is ten weeks old, so most shelves hold one to
  three chapters. Design for 1, 3, and 12 chapters.
- Reactions are per-emoji with counts. There are no likes.

THE ONE PROBLEM TO SOLVE:
The page is a stack of five different ideas (cover, identity, stats, chapters, grid) in the
order they were built, and the two things people actually come for are at the bottom. Someone
opens a friend's page to see what they shot lately and to open a chapter. Today they scroll
past a header taller than the screen to get there. Chapters, the marquee feature of the last
release, reads as a row of thumbnails you could mistake for the grid. Make the page feel like
one object, put the photographs first, and make a chapter feel like the event it is without
turning the page into a dashboard.

SECONDARY GOALS:
- Identity in one glance without a 300pt header. The cover photo can go if it earns nothing.
- Badges and the signup number are quiet by design. They can move, they cannot get louder.
- The date stamp and the film-strip language are the brand. Use them structurally (a strip,
  a contact sheet, an edge number) rather than as decoration.
- The owner's page and a friend's page should be the same design with different buttons,
  not two layouts.
- A page with one chapter and 12 posts must look finished, not empty. A page with 12
  chapters and 214 posts must stay navigable.
- Design the empty first-time page as a real state, not a placeholder.

HARD CONSTRAINTS:
- 393pt wide, portrait, dark only. Background is near-black, text is white, secondary text
  is grey.
- The accent colour is chosen by each user in Settings (default warm amber). Treat it as a
  variable that must work as any hue, not a brand colour. Use it sparingly: one button, one
  active state.
- Photographs are 3:4 and are never cropped to square. Never put text or controls over a
  photograph except the app's own date stamp, which is already burned in.
- Do not touch the tab bar or the navigation chrome above the page.
- No gamification: no progress bars, no streak flames, no levels, no "you're 80% there".
- No em dashes anywhere in copy. Short declarative sentences. No exclamation marks.
- Use real-looking content: warm film-look photographs with soft grain and dark corners, a
  three-line bio, a name and handle, badges with names like "First hundred" and "Roll MVP",
  chapter covers for June, July, and August 2026.

ARTBOARDS I WANT BACK:
1. A friend's page as it should be, with 3 chapters and about 40 posts.
2. The same design as the owner's own page, showing the Edit and Invite buttons and the
   "new badge to see" moment.
3. The same design with 1 chapter and 12 posts, and with 12 chapters and 214 posts, side by
   side, to prove it holds at both ends.
4. The first-time empty page.
5. One artboard that shows the transition from the page into a chapter: what the cover does
   when tapped and what the first frame of the chapter looks like, so the two feel continuous.

Make them tappable where the interaction matters (badge tap, chapter tap, stats tap). Show at
most two directions for the overall layout, label which one you recommend, and say why in
three sentences or fewer. If a constraint above makes something impossible, say so rather
than bending it.
