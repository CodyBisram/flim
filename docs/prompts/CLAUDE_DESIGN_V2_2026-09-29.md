# FLIM v2: the full redesign. Prompt for Claude Design (2026-09-29)

Paste everything below the line into a new Claude Design project. Earlier v2 briefs in this folder
are superseded; this one starts from the app as it ships today. Attach, in this order:

1. Screenshots of the current app at 402pt, one per screen listed in section 3 (take them on the
   phone: camera, Darkroom with unsorted shots, the sort deck mid-swipe, Feed with a few units,
   the Spotlight strip and week sheet, Rolls list, a roll's detail before and after develop, the
   reveal, a profile with badges and a chapter shelf, a chapter recap, Activity, the invite sheet,
   the onboarding screen, sign-in). Also the App Store icon.
2. `Flim/Views/Theme.swift` and `Flim/Views/Components/FlimFont.swift` (today's tokens and type).
3. The folder `outputs/glass-2026-09-29/` (before and after shots from the iOS 26 glass pass).

---

## 0. What you are designing, and how much freedom you have

FLIM is an invite-only iOS camera app: a disposable camera for a few close friends. Version 1 was
an MVP built screen by screen over a summer. It works, it has 80 people on it, and it looks like
what it is. Version 2 is the app FLIM should have been from the start: something a person opens
and thinks "this is beautiful, I want to use this every day," whether they have been on it since
July or joined tonight through a friend's code.

You have full autonomy over the visual system, the structure, the navigation, and every screen.
You may rearrange screens, merge them, split them, or tear one down and build it back up. You may
propose a new icon and a new brand mark. You may change the tab order and what each tab holds.
You may change how any state looks. The bar is the best camera and photo-sharing apps on the
phone, not "better than v1": the polish of Instagram, the momentum of TikTok, the intimacy of
BeReal and Locket, the taste of Lapse, Retro and Dispo. Learn from all of them, copy none of them.
FLIM has its own idea, below, and the design should feel like that idea, not like a competitor
with a different accent color.

What you may not change is the product itself: what the app does, its rules, and its words, in
section 4. Those are settled. Everything else is yours, with one condition: every departure from
today gets a sentence saying why it is better for the person holding the phone.

This is a long job. Section 8 says how to pace it so the owner can say yes early and you do not
design forty screens in a direction that gets rejected.

## 1. What FLIM is

**The idea.** You shoot with your phone the way you shot with a disposable camera: you frame it,
you press the shutter, and you do not see it. Shots develop later, into a private Darkroom. You go
through them when they are ready and decide what to do with each one. Friends see only what you
post. There are no filters to pick, no likes to chase, no feed to fall into.

**The look.** One film look. Every frame is 3:4, rendered through the same film pipeline (grain,
color, bloom, a 14-segment date burned into the exported back). The frame is the hero of every
screen; chrome exists to serve it. The app is dark: near-black ground, white type, one accent the
person picks (amber, rose, violet, teal, lime, sky; amber is the default and the brand's).

**The parts, as they exist today.**

- **Camera.** A full-width 3:4 viewfinder, a shutter, flash, flip, a self timer, a zoom pill, and
  a roll picker (which roll this shot goes to, or your own Darkroom). After a shot: a short
  "Saved in FLIM" chip, then the top bar shows "N to sort" once shots have developed. Shots take
  time to develop (the wait is the point; the delay is set by the app, not the person).
- **Darkroom.** Your private shelf. Developed shots arrive here first, grouped by day and month,
  with bursts stacked. Nobody else ever sees the Darkroom. From here you open the **sort deck**.
- **Sort deck.** One frame at a time. Swipe right to Post it to your page, left to Keep it
  private, down to Delete. Posting can add a caption and tag people. People sort fast, often 5 to
  20 frames in a row, often right after a batch develops. When a sort ends on its own, a sheet
  offers the frames just posted for Spotlight (see below).
- **Feed.** Your friends' posted frames, grouped by person into units (a person's day of shots as
  one unit with a film-strip of thumbnails and one frame large), reactions (emoji, a small
  suggested set), comments with @mentions, and the people tagged in a frame. A "N new" pill on a
  unit shows what you have not seen. Pull to refresh. The Feed also carries the weekly Spotlight
  strip and a "people you may know" row.
- **Spotlight.** Each week a person can put up ONE frame they shot that week. Only the team at
  FLIM sees what is put up. When the week closes, the team chooses a few and shows them to everyone
  as a short strip at the top of the Feed; the chosen get a notification, a Spotlight badge, and
  the frame stays on their page. Nobody votes, nothing is ranked, nobody sees who else put up.
- **Rolls.** A shared disposable camera for an occasion: you create a roll, friends join with a
  code or a link, everyone shoots into it, nobody sees anything until the roll develops (a set
  time). Then a **reveal**: a paged, ceremonial run through every frame, each one developing in
  front of you, once per person. A roll has members, a cover, a develop time, and a Live Activity
  countdown on the lock screen while it is developing. Rolls are the feature people come back for.
- **Your page (profile).** Your posted frames as a grid, your avatar and cover, a bio, an accent
  color, your Founding number (member #N for the first hundred), up to two badges you choose to
  display from the ones you have earned (twelve automatic ones, three given by hand, on a ladder
  of tiers: founding, gold, silver, bronze, accent), your Spotlight frames, and a **chapter
  shelf**: every finished month as a chapter you can open. Other people's pages show the same,
  minus the private parts, with Follow.
- **Chapters.** On the first of the month, the month you shared arrives on your page as a recap:
  it plays like a reveal and ends on the month in numbers (shots, days, people). You can share a
  chapter's export. Stats can be shown or hidden.
- **Activity.** Reactions, comments, tags, follows, roll invites, Spotlight picks. Unread is
  marked by an accent dot on the bell.
- **Invites.** The app is invite-only. Each person has a personal code and a few invites; you earn
  one back when someone you invited shoots their first frame. Rolls have their own join codes.
  Time-boxed campaign codes exist (the owner posts one with a reel). A link `flim-app.com/i/CODE`
  previews the inviter and opens the app.
- **First run.** One onboarding screen, then phone number, OTP, username. A new account gets a
  one-way follow of the person who invited them and a first-visit line on Feed and Darkroom.
  Camera permission is asked when the person first reaches the camera; notifications are asked
  when there is a reason (a roll is developing).
- **Settings and account.** Accent color, save-to-camera-roll on develop, notification choices,
  blocked people, chapter stats visibility, feedback, sign out, delete account.
- **System surfaces.** Toasts (success, error, info), an offline pill, an update nudge and an
  update gate, an undo capsule after a sort, permission primers, empty states everywhere.

## 2. Who uses it

Eighty people, nearly all friends and friends of friends of the founder, most in New York, some
abroad (a Bali cohort). They shoot in the evening (the peak is 6 to 9 PM), in bursts, and sort in
one sitting. Forty-two opened the app this week. The founder answers feedback personally and gives
badges by hand. New people arrive through a friend's code or a reel; their first minute is a
sign-in, a username, and an empty Darkroom with a camera waiting.

Use this to design for real moments (a burst of 14 shots to sort at 9 PM, a roll developing while
everyone is still at the table, a chapter arriving on the first of the month), not as targets.
There are no numbers to move in this brief. The number that matters is whether someone who just
joined wants to open it again tomorrow.

## 3. Every screen today, and the states it must have

Design each of these, in whatever structure you choose, and show every state listed. A state that
is missing is a screen that will look broken on someone's phone.

| Screen | States |
|---|---|
| Splash and launch | first launch, returning, offline with a cached account, update gate, update nudge |
| Onboarding | the one screen (name the promise, one button), with and without an invite preview ("You're in with X's code", campaign code variant) |
| Sign-in | phone entry, OTP entry, wrong code, resend, rate-limited, username pick (taken, too short, ok), reviewer sign-in (hidden) |
| Camera | idle, no permission (ask, denied), developing count, roll selected, flash on/off, timer set and counting, zoom, just shot (saved chip), queued offline, "N to sort" |
| Darkroom | empty (new account), shots developing (with time), developed and unsorted, sorted grid by day and month, burst stacks, select mode with delete, month closing row, loading, load failed |
| Sort deck | a card, the three actions, mid-swipe in each direction, caption and tag compose, posted notice, undo, last card, session end with the Spotlight offer, offer declined, first sort of a new account (no offer), offline |
| Feed | empty (no one followed yet, first-visit line), loading, units with N new, a unit expanded, reactions, comment count, tagged people, people-you-may-know row, Spotlight strip (this week's picks), pull to refresh, couldn't refresh, post gone, blocked content absent |
| Post detail and photo viewer | a frame full-bleed, caption, tags, reactions, comments, share, flag, more menu, the night rack (a day's frames), the roll rack, zoom, swipe to dismiss |
| Comments | list, empty, composer, mention suggestions, reply, like, own comment delete, failed to load, failed to send |
| Spotlight | first-time explainer, the week sheet (put up, swap, remove, "still posting"), the strip, a chosen frame on a page, the pick notification landing, nothing chosen this week |
| Rolls | empty, list with developing (countdown), developed and unrevealed, revealed, ended; create roll (name, develop time, cover); join with code (valid, invalid, ended, already a member); roll detail before develop (members, code, share link, your shot count, leave), developing (Live Activity too), after develop (grid, save all, partial save error, cover pick); members sheet; reveal (start, per-frame develop beat, mid-run, last frame, done, replay not allowed); develop-ask sheet |
| Your page | own page full, own page empty (new account), someone else's page (follow, following, blocked), badges (0, 1, 2 displayed; the picker with a new badge to reveal; the explanation sheet; "Given by Cody" line on hand-given ones), Founding number and no number, accent chosen, cover and avatar (set and unset, crop sheet), chapter shelf (none yet, one, many), Spotlight frames |
| Chapter recap | the play-through, the closing card (month in numbers), share export preview, stats hidden variant, empty month |
| Activity | empty, list with "New" section, each item type (reaction, comment, tag, follow, roll invite, Spotlight pick), a photo that is gone |
| Invites | your code, invites left (3, 1, 0), earned one back, share sheet, campaign code landing (web page too: `flim-app.com/i/CODE`) |
| Settings | the list, accent picker, notifications, blocked people (empty, list, unblock failed), feedback sheet (send, sent, failed), delete account (confirm, deleting, failed) |
| Notifications | the push itself (a friend posted, a roll developed, a reaction, a comment, a tag, a chapter arrived, a Spotlight pick, an invite came back, the digest), and where each lands |
| Widgets and Live Activity | the Darkroom widget, the look-back widget (last month's frame), the lock-screen shutter, the roll countdown on the lock screen and Dynamic Island |
| System | toasts (success, error, info), offline pill, undo capsule, permission primers (camera, notifications), loading shimmer, the empty state pattern, error state pattern with retry, keyboard-up composers |

Show each screen at the default text size and at least the Feed, sort deck, and a sheet at
Accessibility XL. Show Reduce Transparency once for glass surfaces.

## 4. Rules you design within (settled, do not change)

**Product rules.**
- Shots are not seen when taken. They develop later. No "view now."
- The Darkroom is private, always. Nothing there is visible to anyone else.
- Posting is a deliberate act per frame (the sort). No auto-posting.
- Spotlight: one frame a week, the team at FLIM chooses, nobody votes, nobody sees who put up.
  Do not name weekdays in Spotlight copy (weeks close early Monday, New York time, but the copy
  says "when the week closes"). Never say "featured", "winner", or "top".
- Rolls develop at a set time and reveal once per person. The reveal is a ceremony, not a grid.
- Invite-only stays. Founding 100 numbers stay. Badges ratchet (once earned, never lost).
- No likes counts on the Feed. Reactions are emoji, small, and not tallied as a score.
- One film look, 3:4 frames. Do not propose filters, looks, or aspect choices.
- Dark app. A light theme is not asked for. Six accents; amber is the brand's.

**Copy rules.** Plain, warm, short. Sentences a friend would say. Never an em dash. Never an
exclamation mark in the app's own voice. "Shots" and "frames" are the words for photos; "the
team at FLIM" chooses Spotlight; "Given by Cody" is on hand-given badges (Cody is the founder).
Existing strings can be rewritten, but every new string goes in a list for the owner's yes.

**Platform.** iOS 18 and 26, iPhone only, portrait. iOS 26 gets Liquid Glass for chrome (the tab
bar, floating buttons, sheets, toasts); iOS 18 gets the same design in material. Dynamic Type on
every text; glyphs in fixed chrome do not scale. Reduce Motion and Reduce Transparency honored.
SF Symbols for glyphs (a custom brand mark is welcome). Everything must be buildable in SwiftUI
by one engineer; no effect that needs Metal shaders per frame.

## 5. What is open, with the owner's current leanings

- **Structure and tabs.** Today: Camera, Darkroom, Rolls, Feed, with the profile behind an
  avatar in the Feed header. Rearrange freely. The owner has been asked before whether Camera
  should be the launch tab; answer it with a design, not a survey.
- **The Feed's shape.** Units per person per day exist because one person posting twenty frames
  flooded everyone. Keep the intent (no flooding, a person's day as a thing), change the form.
- **The reveal and the chapter recap** share a ceremony vocabulary (frame by frame, a closing
  card). Make it one language.
- **The Darkroom and the sort deck** are where people spend their private time. Make sorting
  feel good in the hand at speed: this is the app's core interaction, more than the Feed.
- **Badges** have five tiers and a glow reserved for Founding. Redesign the pills; keep the
  ladder.
- **The icon** today is one universal PNG (dark ground, cream frame, lens ring, amber strip).
  Propose the layered iOS 26 icon and a brand mark that can replace the aperture symbol used on
  the splash and empty states.
- **Motion.** Today there are 17 spring configurations. Propose four named motions and where
  each applies, plus the two ceremonies (reveal, chapter) with their own timing.
- **Type.** The system font today. A display face for titles and the date stamp is welcome if
  it earns its place; body stays system.

## 6. The bar

A person on FLIM since July should open v2 and feel the app grew up without moving their
furniture: the same idea, unmistakably better. A person who joined tonight should feel, in the
first minute, that they are holding something made with care, and that there is a reason to
come back tomorrow (a roll developing, a chapter coming, a frame to sort).

Specifically:
- The frame is always the hero. Chrome recedes. Photos are never cropped to fit chrome.
- Every screen has a first-run state that teaches by showing, not by a tour.
- Waiting is designed, not hidden: developing shots, a developing roll, and a month closing are
  moments, with their own visual language.
- Nothing looks like a default list. Grouped lists for settings are fine; the product screens
  are not.
- Speed: sorting, reacting, and opening a frame feel instant. Show what happens during the wait.
- Empty states are the best-looking screens in the app, because a new person sees them first.

## 7. Deliver

1. **A design system**: color (ground, surfaces, the six accents, text, states), type roles,
   spacing and radius scales, the glass rules for iOS 26 and the material fallback, motion
   tokens, iconography (SF Symbols list plus the brand mark), and the component set (buttons,
   pills, cards, sheets, toasts, the frame, the film strip, badges, avatars, chips, composers).
2. **Every screen in section 3, at 402pt, in every listed state**, grouped by flow, with the
   navigation between them drawn.
3. **The five flows end to end**: first run through first shot; shoot, develop, sort, post;
   create a roll through reveal; a week of Spotlight; the first of the month.
4. **A motion spec**: the four named motions, the two ceremonies, and every transition between
   screens.
5. **The icon and brand mark**, with the iOS 26 layered version and the iOS 18 fallback set.
6. **A change log**: one line per departure from today's app, and why.
7. **A copy list**: every new or changed string, for the owner's yes.

Dark only. iPhone 16 Pro width (402pt). Real photographs in the frames (warm, evening, friends,
food, streets; not stock-looking), and real-looking names, captions and comments.

## 8. How to pace it

Round 1: the design system and three hero screens (Camera, Feed, the sort deck), with the icon.
Stop there and wait for the owner's yes on the direction. Round 2: the Darkroom, Rolls and the
reveal, your page, chapters. Round 3: everything else in section 3, every state, the flows, the
motion spec. Round 4: the change log, the copy list, and the Accessibility XL and Reduce
Transparency passes.

Ask questions only when a product rule in section 4 blocks a design you believe is better; put
the design next to the question so the owner can see the trade.
