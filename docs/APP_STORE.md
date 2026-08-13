# FLIM: App Store Connect listing

Copy-paste-ready metadata + a screenshot plan + reviewer notes. Tweak the voice to taste.

---

## Name & subtitle

Shipped with 1.3:

| Field | Value | Chars |
|---|---|---|
| App name | `FLIM: Disposable Camera` | 23 / 30 |
| Subtitle | `Shoot film with your friends` | 28 / 30 |

The App Store name is not the home screen name. `CFBundleDisplayName` is `FLIM` on both the app
and the widget target, so the icon stays four characters no matter how long this field gets.

### The version to switch to when signups open

`film` sits in the subtitle today. Whether moving it into the name would rank it any higher is
genuinely unsettled: Apple does not publish the relative weight of the name and the subtitle, and
ASO practitioners disagree, with a common view being that the name leads slightly and a credible
view being that the two are equivalent. If they are equivalent, moving `film` buys nothing at all
and the question answers itself.

Either way it was not done for 1.3, for two reasons that do not depend on the weighting.
`FLIM: Disposable Film Camera` puts FLIM and Film two words apart, which reads as a typo (Apple does
not fuzzy-match them, so the pun buys nothing and only costs clarity). And while the app is
invite-only, someone who finds it by searching a broad term downloads it, hits an invite wall, and
leaves. Ranking for discovery terms optimises a funnel that is deliberately closed.

When the invite list opens, the pair below is worth revisiting. Its real gain is not `film`, it is
`shared` and `rolls`, which we rank for nowhere today:

| Field | Value | Chars |
|---|---|---|
| App name | `FLIM: Disposable Film Camera` | 28 / 30 |
| Subtitle | `Shared rolls with your friends` | 30 / 30 |

Both fields are metadata, editable on any submission, so this costs nothing to defer.

## Promotional text (170 char max, editable anytime without review)
> Shoot together, wait together, see them together. FLIM is a disposable camera for your group. No filters to pick, no likes to chase, no feed to fall into.
>
> Previous (also fine, evergreen): Shoot on film, wait for it to develop, and share the moment with the people who actually matter. No likes to chase. No feed to doomscroll. Just your people.

## Description

> **PASTE THE BLOCK BELOW.** Paragraphs are single unwrapped lines on purpose; App Store Connect
> keeps your line breaks exactly as pasted, so hard-wrapping here produces a ragged listing.

    FLIM is a disposable camera for your closest friends.

    Point, shoot, and let it develop, just like the real thing. Personal shots land in your Darkroom right away. Shots into a shared roll stay hidden until the whole roll reveals at once, twelve hours after it started. Nobody sees them early, not even the person who took them. The waiting is what makes the reveal worth showing up for.

    Real film feel. Every photo gets FLIM's film look baked in at capture: warm color, grain through the midtones where film puts it, and the soft red glow real film gives a bright window or a streetlight. No filters. No sliders. One look, applied the moment you shoot, the same for everyone.

    Rolls for your people. Start a shared roll with up to 50 friends and shoot into it together. Everyone's photos land in the same place, and the whole roll develops at once. Trips, parties, nights out, all revealed together. Watch a roll fill up as its reveal gets closer, with a countdown on your lock screen, then play it back one shot at a time. Join with an invite code, comment on each other's photos, react with emojis.

    A feed that's yours. Follow friends, see what they post, react and comment. Mention someone with @ to bring them into it. FLIM is invite-only, so everyone you see is someone a friend chose to let in. No public like counts. No algorithm deciding what you look at. No strangers.

    FEATURES
    • One film look, applied at capture, no post-processing
    • Twelve hour development window, with a roll's shots revealing together
    • Shared rolls with up to 50 members, joined by invite code
    • A reveal that plays your roll back one shot at a time, with a lock screen countdown
    • A private feed from the people you follow
    • Reactions, comments, and @mentions on photos and posts
    • Photo tagging you can edit any time, and you can untag yourself from anything
    • Blocking and reporting, reviewed within 24 hours
    • One daily notification rounding up what friends posted, instead of one per photo
    • Email sign-in with a one time code, invite only

    You need an invite to join. If you do not have a code yet, ask the friend who sent you here.

### Why this differs from the 1.2 description

Three deliberate cuts, kept here so nobody restores them by accident.

"Every reveal feels like a little surprise waiting to happen" told the reader what to feel, and
"little surprise" undersold the mechanic the whole app is built on. Replaced with the fact stated
plainly: nobody sees them early, **not even the person who took them**. That had never been said
anywhere in the copy and it does the persuading on its own.

"Just one beautiful look that works for every moment" went the same way. Beautiful is the reader's
call, and "works for every moment" is filler. What replaced it, grain through the midtones where
film puts it, is lifted from our own 1.2 release notes and is the most convincing sentence written
about the look so far.

"Grab an invite from a friend and start shooting" moved from the end of the opening paragraph to
the very bottom. It is a logistics note, and it was occupying the strongest real estate on the page.

## Keywords (100 char max, comma-separated, no spaces)

`photo,retro,vintage,analog,rolls,develop,instant,private,social,grain,polaroid,album,35mm,lofi,dump`

99 chars. Rewritten for 1.3 because the name and subtitle changed.

The rule that drives this list: **Apple indexes the app name, the subtitle, and the keyword field
together and deduplicates across all three.** A word already in the name or subtitle is dead weight
here. The previous list carried `disposable`, `camera`, `film` and `friends`, all four of which now
appear in the name or the subtitle, so roughly 31 characters of a 100 character budget were buying
ranking we already had. Removing them freed room for `polaroid`, `album`, `35mm`, `lofi` and `dump`.

This holds regardless of how the name and subtitle are weighted relative to each other, which Apple
does not publish and which practitioners disagree about. Deduplication is the part that is not in
dispute.

`dump` looks odd alone. Apple builds combinations across indexed terms, so `photo` plus `dump`
covers "photo dump", which is how the people this app is for actually describe it. The same
mechanism means `film` in the subtitle plus `camera` in the name already covers "film camera"
without either word appearing here.

Two rules if this is edited again: never repeat a word across name, subtitle and keywords, and do
not add plurals of words already present. Apple handles both.

## What's New (version 1.4)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    Tapping a notification now opens the thing it is about. The post, the comment, the profile, the roll that just developed. It used to put you on the camera every time, whatever it said.

    Reply to a comment right under it, instead of starting a new one at the bottom. And you will know when someone likes what you wrote.

    The reaction bar suggests an emoji or two based on what is actually in the photo, next to the usual heart and fire. Behind the plus, the picker now holds every emoji your phone can draw instead of a fixed handful.

    Add a caption or tag people while you are sorting, instead of posting first and going back for it afterwards. Tagging now leads with the people you are most likely to pick, so it is usually one tap.

    Edit a caption anywhere your photo lives, not just from the feed.

    Sorting deals your oldest shot first, so a session plays back in the order you took it.

    Profiles say "Follows you" when someone already does, and the button says "Follow back" rather than pretending you found them first.

    A reaction to a photo you are tagged in now reaches you, and shows up in Activity, the same as a reaction to one you took.

    Your Darkroom marks the shots you have already shared, so you can tell developed from developed and posted without opening each one.

    Underneath: pull to refresh no longer interrupts itself, cover photos are no longer washed out, rolls you can no longer shoot into stop cluttering the camera, the small controls are easier to hit, and an edit or a delete that quietly failed now says so instead of looking like it worked.

### Ship notes (internal, do NOT paste)

- The notification line is first because it is the biggest behavioural change: every tap used to
  land on the camera, and one of those notifications is "your roll developed", which was sending
  people away from the reveal at the exact moment they were told to go and see it.
- Say nothing about activation instrumentation, device token pruning, the render probe, caches, or
  schema work. None of it is a user-facing feature and the analytics line in particular belongs in
  the privacy label, not the release notes.
- "photos no longer go missing" is claimable and was claimed in 1.3 as well, because a different
  cause was fixed each time. 1.3 fixed a capture killed between upload and row insert. 1.4 fixed
  the retry queue deleting the image it was holding. Keep it vague in public copy.
- Do NOT re-claim Dynamic Type, tooltips, or anything from 1.1 and 1.2's notes.
- No em dashes in any user-facing copy.

## What's New (version 1.3)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    FLIM now runs on a lot more iPhones. If it would not install on someone's phone before, it probably will now.

    Sharing a photo from the full screen view actually shares it. That button has never worked until now.

    Tapping someone's name opens their profile the same way from everywhere in the app, with a way back out. Before, opening a profile from inside a roll could leave you on a screen with no exit.

    Double tap a photo to like it, the same gesture wherever there is something to react to.

    A shot that misses its roll because the roll finished developing now lands in your deck instead of getting stuck. Activity reads as sentences rather than breaking into a second column.

    Underneath: photos no longer go missing if the app closes while one is uploading, and a long list of fixes to how photos load, save, and hold their place.

### Ship notes (internal, do NOT paste)

- The headline is the deployment target dropping from iOS 26.0 to 18.0 (`1a38bd1`). It needed zero
  source changes because the iOS 26 calls were already behind availability checks with working
  fallbacks. It is first in the notes because it is the only line that changes who can install the
  app at all.
- Do NOT re-claim Dynamic Type. 1.2 already said "text now follows your device's text size
  setting". 1.3 widened it, which is not worth a second mention.
- The share button claim is honest and worth making. It never worked in any shipped build: it
  looked the image up by signed URL while `CachedImage` stores under `cacheKey|maxPixel`, so the
  lookup could not hit and the button silently did nothing. Fixed in `59ce50e`.
- "Photos no longer go missing" covers two real defects, both fixed this cycle: a capture killed
  between its upload and its row insert left bytes with no photo (`c8083d6`), and the retry queue
  could delete the image it was holding because `save` and `prune` were unsynchronised
  (`5dfd0e4`). Claimable, but keep it vague in public copy; naming the mechanism invites the
  question of how long it was there.
- Not mentioned on purpose: blocked accounts could still fetch photo bytes with a cached path until
  `58af639`. It is a security fix and the right move is to ship it quietly, not to advertise that
  the hole existed.
- No em dashes in any user-facing copy.

## What's New (version 1.2)

> **⚠️ PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    A better reveal, a warmer film look, and a profile picture you can frame yourself.

    Rolls now show how close they are to developing, and whichever develops soonest sits at the top. On the camera, a roll about to close tells you how long you have left to shoot into it.

    The reveal plays slower, so each photo has room to land, with a bar that fills as it goes. Press and hold to stop on one you like. The first photo appears straight away instead of making you wait for it.

    A warmer film look. Bright windows and streetlights now bleed a soft red glow the way real film does, and grain sits where film puts it: through the midtones, not across a clear sky.

    Choose exactly which part of a photo becomes your profile picture. Sorting your shots now shows the whole frame, so nothing hides past the edges.

    Tag people any time, not just as you post, and remove yourself from any photo you are tagged in. Mention friends in comments with @. Other people's reactions now appear while you are still looking. One notification a day rounds up what your friends posted, instead of one for every photo, and your notifications are grouped by when they happened.

    Text now follows your device's text size setting. Plus a fix for a crash in the lock screen countdown, and a long list of smaller fixes to how photos load, open, and hold their place.

### Ship notes (internal, do NOT paste)

- The lock screen crash IS claimable this time. It was symbolicated from our own crash reports
  (`RollRevealLiveActivity.swift:31`, a ClosedRange built from `Date()...revealAt` that trapped the
  moment the reveal passed) and fixed in `c08b68d`. This supersedes the earlier note that said not
  to claim a crash fix, which was written when the only crash on record was unidentified.
- The one crash still unexplained is from 31 July and predates dSYM archiving. Do not reference it.
- 1.1's notes advertised "a few helpful tips along the way". Those tooltips are GONE in 1.2.
  Nothing above references them; do not reuse 1.1's paragraph.
- No em dashes in any user-facing copy.

## What's New (version 1.1)

> A smoother, more polished FLIM: a redesigned camera, a truer film look, and easier ways to catch up with your friends.
>
> Redesigned camera viewfinder: bigger, centered, and faster to shoot with, plus a few helpful tips along the way. Recalibrated film look, closer to real film than ever. Smoother, more reliable rolls: no more hiccups scrolling through a developed roll. Redesigned notifications: tap straight through to the photo, comment, or profile you're looking for. Better suggestions for who to follow. A round of reliability fixes under the hood.

## What's New (version 1.0)

> FLIM is live. Shoot on film, wait for it to develop, and share with your closest friends.
> 
> Features: One signature film look baked in at capture. Shared rolls that develop together after 12 hours. A private feed from the friends you follow. Reactions, comments, and tagging. Blocking and reporting with 24h review. Email OTP sign-in, invite-only access.

## Category
- **Primary:** Photo & Video
- **Secondary:** Social Networking

## Age rating questionnaire

FLIM includes user-generated content (photos, comments, tags, reactions). Apple's questionnaire will probe moderation.

**Questions likely to appear:**

| Question | Answer | Note |
|----------|--------|------|
| Does the app include user-generated content? | **Yes** | Photos, comments, reactions, tags, user profiles. |
| Can users report or block other users? | **Yes** | Full bidirectional blocking + photo/user reporting (auto-hide at 2+ reports, manual review within 24h). |
| Is there a content moderation policy? | **Yes** | Reported content auto-hides; human review within 24h; users can delete their own content instantly; deletion cascades to photos, comments, reactions. |
| Are usernames and profile pictures moderated? | **Yes** | Profile setup (username, display name) is gated behind invite-only access; photos pass through moderation on report. |

**Expected rating outcomes:**
- **Path 1 (Preferred):** **12+** if Apple accepts the moderation controls + auto-hide + 24h review as sufficient (common for invite-only closed-network apps with UGC).
- **Path 2 (Fallback):** **17+** if Apple requires a blanket UGC rating regardless of moderation. This is defensible for a social photo app.

**Recommendation:** Answer the questionnaire truthfully (all "Yes" above), emphasizing that moderation is built-in, automatic, and swift. Mention invite-only status (limits exposure). If Apple asks for a higher rating, accept it. 12+ vs. 17+ is not a material sales difference for a closed-network app, and overstating moderation will get rejected on review.

## Support & marketing URLs
- **Support URL:** `https://flim-app.com/support`
- **Marketing URL:** `https://flim-app.com`
- **Privacy Policy URL:** `https://flim-app.com/privacy`

---

## App Privacy ("nutrition label") worksheet

**Data collected & linked to the user:**

### Contact Info
- **Email address**: sign-in + account recovery. Not used for marketing or third-party sharing. Readable by the user only (column-level grants hide it from other users).

### User Content
- **Photos**: user-captured images, uploaded to encrypted private Storage. Accessible only to the
  user and roll members / followers (RLS-enforced). As of 1.2 a photo chosen from the device
  library can also be used as a profile picture or cover. That goes through `PhotosPicker`, the
  out-of-process system picker, so the app receives only the single image the user picked and
  needs no photo-library permission (hence no `NSPhotoLibraryUsageDescription`). The cropped
  result is uploaded like any other user content.
- **Comments, reactions, tags**: social interactions on photos and posts. Stored per social item (post/photo).

### Identifiers
- **Device ID (APNs push token)**: for push notifications (roll reveals, social activity). Ephemeral; rotates when the OS issues a new one.

### Usage Data
- **Product Interaction**, **linked to identity**, purpose **App Functionality** and **Analytics**.
  `activation_events` records one row per person per milestone: first launch, first shot, roll
  created, roll joined, invite sent, invite redeemed, post shared, reveal watched. It is written by
  the app, stored in our own Supabase project, and readable only by the owner. It records that
  something happened once, never a frequency, never content.
- This said "None collected" until 1.4 and that was true then. The instrumentation shipped in 1.4,
  so the label had to change with it. Declaring nothing while a shipped build collects something is
  the mismatch Apple actually penalises.
- **Tracking stays NO.** It is first party, never shared with a data broker, and never used for
  cross-app or cross-site advertising, so no ATT prompt is required. Over-declaring this as
  Tracking would be its own error.

### Diagnostics
- **Crash Data / Performance Data**: on-device crash, hang, and CPU-exception diagnostics via
  MetricKit (Apple's own framework, not a third-party SDK), uploaded to our own Supabase project
  so they're visible without physically connecting the affected device to Xcode. Linked to the
  account only when the device happens to be signed in at the time (nullable otherwise); not
  used for tracking, advertising, or any purpose beyond fixing bugs. Not readable through the
  app or its API by any user, including the account it's linked to, owner-only, via the
  Supabase Dashboard. As of 1.2 each diagnostic also carries the app build number, the OS
  version, the device MODEL (e.g. "iPhone17,1", a hardware class, not a device identifier) and
  the time the diagnostic window closed. All four exist to make a crash actionable: which build
  to symbolicate against, and whether a crash is widespread or one device. Still no analytics,
  no advertising identifier, and nothing that identifies a device across installs.

### Tracking / Analytics
- **No tracking.** No advertising, no third-party tracking, no data broker, nothing that follows
  anyone across apps or sites, so the ASC Tracking toggle stays off and no ATT prompt is needed.
- **First-party product analytics only**, the milestone rows described under Usage Data above.
  Deliberately kept in our own database rather than sent to an analytics vendor, because the App
  Store description promises no algorithm and no strangers and shipping behaviour to a third party
  to measure retention would contradict that for the sake of charts.
- One-way social graph (follows) is optional; blocking is bidirectional and RLS-enforced.

**Not collected:** Location, contacts, browsing history, purchases, health data, search history, financial information, precise location.

**Privacy controls in-app:** Users can block others (bidirectional), report photos/posts/users for moderation review, delete their own photos, and delete their account (cascades to all their content).

---

## Screenshots

Five primary screenshots, in recommended App Store upload order (the first 2-3 appear prominently in search):

1. **02-feed-post.png**: The Feed showing a @cody post of a sunlit hydrangea garden with the film look, emoji reaction bar (heart, fire, laugh, wow, raised hands), and comment field. Caption: *"A feed that's just your friends."*

2. **01-camera-viewfinder.png**: The live Camera tab viewfinder framing a vibrant garden of purple flowers and greenery, with Personal mode pill top-left, zoom pills, and shutter button visible. Shows the film look applied to the live viewfinder. Caption: *"Shoot like a disposable."*

3. **05-roll-invite-code.png**: The New Roll share sheet overlay on the Rolls list, displaying a 6-character invite code (World Cup '26 / ZPE7EF) with Copy code and Share buttons. Shows the invite mechanic. Caption: *"Invite them with a code."*

4. **03-darkroom-developing.png**: The Darkroom showing "28 shots", a "2 DEVELOPING" row (hourglass tiles, one tagged World Cup '26) above a DEVELOPED grid of film-look photos. Shows the development mechanic. Caption: *"Watch them develop."*

5. **04-rolls-list.png**: The Rolls tab list showing World Cup '26 (developing, reveals in 11h 59m), Summer '26, Graduation Party, Road Trip, each with member count and invite code. Shows shared rolls. Caption: *"Rolls for your people."*

**Spare:** 06-rolls-list-alt.png (near-duplicate of 04, hold for future alternates).

### Before uploading

These are 6.9" device captures (1320x2868 pixels) ready for App Store Connect.

**Important:** Screenshots 03 and 04 contain recognizable faces of real people. Confirm you have consent to publish them, or swap them for faceless alternatives before uploading.

---

## Reviewer notes (App Store Connect → App Review Information)

> ## App Review sign-in (implemented, needs one manual step)
>
> FLIM is invite-only and signs in with an emailed code, so a reviewer has no inbox and no invite
> and would otherwise dead-end on the email screen. **Apple reviews every update, not just the
> first.** 1.0 solved this with a hardcoded code that was stripped after approval.
>
> 1.2 replaces it: entering **`review@flim-app.com`** on the email screen opens a password sheet
> instead of mailing a code. Every other address keeps the invite check and the emailed code,
> unchanged.
>
> The **address** is in the binary, because it is what the gate compares against, and an address is
> not a credential. The **password** is not: it lives in Supabase Auth and in the App Review
> Information box below. Revoking access means changing that password, no app update required.
>
> ### ⚠️ Do this before submitting (once)
>
> 1. Supabase Dashboard → **Authentication → Users → Add user**
> 2. Email `review@flim-app.com`, set a strong password, tick **Auto Confirm User**
> 3. Install the build, enter that address, sign in with the password, and **set a username**
>    so the reviewer lands in the app rather than on the username screen
> 4. Follow a test account and create a roll with a few photos, so the app is not empty
> 5. Paste the password into App Review Information, in the Sign-in block below
>
> Steps 3 and 4 matter: without them a reviewer signs in successfully and sees an empty app,
> which reads as broken. Do not skip step 3, the reviewer should never have to invent a username.

> **FLIM is invite-only.** To demo the app:
>
> **Sign-in:** Enter `review@flim-app.com` on the first screen. A password prompt appears
> (this account signs in by password rather than the emailed code the app normally uses).
> Password: **_______________** ← paste before submitting.
>
> **What to check:**
> - **Camera:** Tap the shutter to take a photo. Personal shots develop immediately and appear in the Darkroom; shots taken into a shared roll develop together 12 hours after the roll was created.
> - **Darkroom:** View your developed photos in the grid. Tap to view full-screen.
> - **Rolls:** Create a new roll or join an existing one using an invite code.
> - **Feed:** Browse posts from other users in the feed; like, comment, and react with emojis.
> - **Safety:** Tap ••• on any photo or post to **Report** or **Block** the user. Both actions are reachable from the UI. Reported content is auto-hidden after 2 reports and reviewed within 24 hours. Blocking is bidirectional.
> - **Notifications:** Grant notification permission to see push notifications when photos develop (local fallback works without APNs credentials).
>
> **Account access:** The reviewer account has full functionality. Photos uploaded by the reviewer are visible in the Darkroom and deletable via the ••• menu. The account can be created/deleted between review cycles; accounts older than 30 days with no posts are auto-deleted.

**Setup before submission:** see the numbered list in the App Review sign-in block above. The
auth check for review@flim-app.com is already shipped; what remains is creating the Supabase user,
setting a username on it, seeding a little content, and pasting the password into App Review
Information.

**History:** 1.0 shipped a fixed-code branch in `AuthService` gated on `review@flim-app.com`,
where the code `482915` was itself in the binary and extractable with `strings`. It was removed
after approval. 1.2's replacement keeps the same address and the same "email plus password" shape
a reviewer expects, but the password is server-side, so the shipped binary contains no usable
credential. If the 1.0-era Supabase user still exists, reset its password rather than deleting it,
so the address stays stable across submissions.
