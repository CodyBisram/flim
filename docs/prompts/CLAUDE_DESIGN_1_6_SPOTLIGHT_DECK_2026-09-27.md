# FLIM 1.6: Spotlight from the sort deck. Prompt for Claude Design (2026-09-27)

The owner wants Spotlight used from day one of 1.6, by people upgrading. The rules and the server
are settled and shipped to TestFlight (build 411 and the local fix after it); this brief is only
about how a person puts a frame up, or swaps one in, while posting from the sort deck, and whether
the feed and the profile need anything to match. Paste everything below the line into a new
Claude Design project.

Attach, in this order:

1. Screenshots from build 411 or later, at 402pt:
   - the sort deck: a card, the three circles, the "Add a caption or tag people" pill, a card
     mid-swipe to Post, the "Posted to your page" notice
   - the Spotlight ask in the deck ("Put this one up for Spotlight?"), on a middle card and on
     the last card
   - the first-time Spotlight sheet over the deck
   - the compose sheet ("New Post")
   - a feed card with its menu open showing "Put it up for Spotlight", and one showing "Swap it
     into Spotlight"; the same menu on the post opened from your profile
   - the Spotlight strip in the feed, and the week's sheet
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` (tokens and type roles).

---

## 0. What you are designing

FLIM is an invite-only iOS camera app: a disposable camera for a few close friends. Shots develop
into a private Darkroom; the sort deck is where a person goes through them and swipes each one:
right to Post it to their page (their followers' feed), left to Keep it private, down to Delete.

Spotlight (new in 1.6): each week a person can put up ONE frame they shot that week. Only the team
at FLIM sees what is put up. When the week closes, the team chooses a few and shows them to
everyone as a short strip in the feed; the chosen get a notification, a Spotlight badge and the
frame on their page.

Today, the only way to put a frame up is buried in each post's "..." menu. The owner's goal: the
moment of posting from the sort deck is when a person is looking at their best frames, so that is
where Spotlight should be offered, clearly and without friction, including SWAPPING when a frame
is already up. The feed and profile can stay as they are unless you find they need to change to
make the deck flow make sense.

The codebase is public: https://github.com/CodyBisram/flim (branch `main`). Read these before
designing; they are the ground truth, and your design must be buildable against them:

- `Flim/Views/Darkroom/SortDeckView.swift`: the deck. Note the hold-for-Undo: each swipe is held
  and only posted at the next swipe or when the deck closes. The current ask (`askPhoto`) appears
  at the swipe, not when the post lands, for that reason. When the last card is swiped the deck
  closes itself.
- `Flim/Models/Spotlight.swift`: `SpotlightPostedAsk` (when the deck may ask), `SpotlightMenuItem`
  (the menu's states: put up, swap, take down, disabled with a reason), `OwnSpotlightEntry` (this
  week's bounds, whether anything is up and which post), the refusal strings.
- `Flim/Views/Feed/SpotlightViews.swift`: `SpotlightFirstTimeSheet`, `SpotlightFlow`,
  `SpotlightMenuSection`, the strip.
- `Flim/Services/FeedService+Spotlight.swift`: `putUpForSpotlight` (an optimistic put-up; a
  put-up while another frame is up SWAPS it, server side, and the answer names the frame taken
  down), `takeDownFromSpotlight`.
- `docs/SPOTLIGHT_1_6_PLAN.md`: the whole feature and every decision behind it.

## 1. Rules you design within (settled, do not change)

- One frame per person per week. The week runs Monday 04:00 to Monday 04:00, New York time.
- Only a frame SHOT this week can go up (capture time, not post time), by the person who shot it,
  with nobody tagged, from an account not in a covered window. The server refuses anything else.
- Putting up a second frame the same week swaps it for the first. A frame can be taken down until
  the week closes. After that nothing changes until the team publishes.
- The first put-up on an account shows the first-time sheet (what Spotlight is, that only the team
  sees it, one frame a week) before anything is sent.
- Nothing public shows that a frame is up. Only the person themselves may see it.
- No server changes for this: everything above already exists as RPCs.

## 2. What exists in the deck today, and what the owner found on device

After a qualifying frame is swiped to post (nothing up yet this week), the notice area under the
card shows "Put this one up for Spotlight?" with "Not now" and "Put it up". "Put it up" posts the
held frame at once (no more Undo for it) and runs the put-up; the answer shows in the deck. It
goes away on the next swipe, on Undo, or after eight seconds. It never appears when a frame is
already up, so there is no way to SWAP from the deck.

On device, the owner found:
- On the last card the deck empties and the ask sits alone on a large, blank screen; the only way
  out was the close button in the top corner, which does not read as "no". (A "Not now" was added
  after; the blank screen remains.)
- The ask is small text in the notice area; easy to miss while swiping fast.
- There is no sense, anywhere in the deck, of which frame is up this week, so swapping is
  impossible to reason about.

## 3. Design these states (402pt artboards, dark, the app's own tokens)

Propose two directions, then recommend one, and draw every state below in the recommended one:

A. Nothing up this week, a qualifying frame is posted. The offer.
B. A frame IS up this week, a qualifying frame is posted. Offer the swap, showing the frame that
   is up (its thumbnail, and the day it was posted) so the person knows what they would take down.
C. The posted frame does not qualify (shot before this week, tagged, someone else's shot). Decide
   whether the deck says anything; justify either way. Silence is allowed.
D. The last card of the deck, in A and in B. No large empty screen; an obvious way to decline.
E. Posting through the compose sheet (caption and tags). Tagged frames cannot go up; untagged ones
   can. Decide whether Spotlight appears in the compose sheet itself or after it; justify.
F. The first-time sheet appearing from the deck, and returning to the deck after it.
G. After a put-up or a swap: the confirmation, in the deck, and how a person changes their mind
   (take it down) without leaving the deck, if you think they should be able to.
H. The Sunday-night edge: a frame shot this week can take hours to develop, so the week may close
   before it reaches the deck. What, if anything, the deck says.
I. The feed and the profile: whether the own-post menu, or your own post, should show anything
   more (for example, which of your frames is up this week). The plan says nothing public shows a
   frame is up; your own view may. The feed may stay exactly as it is. Justify any change.

## 4. Constraints

- The deck's layout never moves: the card never resizes and the three circles stay put. Anything
  you add lives in the space the notice already uses, on the card itself, or in a sheet.
- Swiping must stay fast. The offer can never block the next swipe. Hold-for-Undo stays.
- Existing tokens, type roles and components only. No new colours. 44pt minimum targets, Dynamic
  Type up to the largest accessibility sizes, Reduce Motion respected.
- Copy: no em or en dashes anywhere. The people choosing are "the team at FLIM", never the owner or
  an editor. A Spotlight is named by its week ("the week of September 28"), never by a weekday; a
  frame may be named by the day it was posted ("your frame from Tuesday"). Banned: featured,
  winner, top, picked, best of, circled. Never a ring, star, or badge drawn on a photograph; a
  frame in Spotlight reads as lit, not marked.
- Nothing about Spotlight may look like a contest or a score. No counts of how many people put
  frames up.

## 5. Deliver

1. The two directions, one board each, with a paragraph on the trade-off. Then your
   recommendation.
2. Every state in section 3 in the recommended direction, at 402pt, including the largest Dynamic
   Type size for A and D.
3. A copy table: every user-facing string, new or changed, with where it appears.
4. An implementation note per state naming the file and type it changes (from the list above),
   what new state the deck needs, and anything the current code does that your design depends on
   changing. Keep it to what 1.6 can ship: client only.
