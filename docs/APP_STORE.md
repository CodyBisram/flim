# FLIM: App Store Connect listing

Copy-paste-ready metadata + a screenshot plan + reviewer notes. Tweak the voice to taste.

---

## Name & subtitle options

### App name (30 char max)
1. **FLIM** (4 chars): primary, brand-forward, short and memorable
2. **FLIM: Disposable Camera** (23 chars): descriptive, keywords-loaded
3. **Film Rolls** (11 chars): descriptive, generic alternative

### Subtitle (30 char max)
1. **Disposable camera for friends** (30 chars): current choice, descriptive + social angle
2. **Shoot now, develop later** (25 chars): action-oriented, emphasizes the core mechanic
3. **Shared rolls, real moments** (26 chars): warm, social, emphasizes shared experience

**Recommendation:** Use app name `FLIM` + subtitle `Disposable camera for friends` (primary choice above).

## Promotional text (170 char max, editable anytime without review)
> Shoot on film, wait for it to develop, and share the moment with the people who actually matter. No likes to chase. No feed to doomscroll. Just your people.

## Description

> **FLIM is a disposable camera for your closest friends.**
>
> Point, shoot, and let it develop, just like the real thing. Personal shots appear in your Darkroom right away. Shots into a shared roll stay private until the whole roll reveals together at a fixed time: 12 hours after the roll was created. Every reveal feels like a little surprise waiting to happen. Grab an invite from a friend and start shooting.
>
> **Real film feel.** Every photo gets FLIM's signature film look baked right in at capture: warm color, fine grain, and a subtle glow. No filters, no choices, no second-guessing. Just one beautiful look that works for every moment.
>
> **Rolls for your people.** Start a shared roll with up to 50 friends and shoot together. Everyone's photos land in the same place, and the entire roll develops at once. Trips, parties, nights out, all revealed together. Join rolls with invite codes, comment on each other's shots, and react with emojis.
>
> **A feed that's yours.** Follow friends, see their posts, react, and comment. It's invite-only and private by design. The people you see are the people you chose to invite. No public likes. No algorithm. No strangers. Just a calmer way to stay close to the people who matter.

**Features:**
- One signature film look, applied at capture (no post-processing)
- 12-hour development window (photos reveal at the same time as their roll)
- Shared rolls with up to 50 members via invite codes
- Private photo feed from people you follow
- Reactions (emojis) and comments on photos and posts
- Photo tagging
- Real blocking and reporting (reviewed within 24h)
- Push notifications for roll reveals and social activity (comments, reactions)
- Email OTP sign-in, invite-only access

## Keywords (100 char max, comma-separated, no spaces)
`disposable,film,camera,photo,friends,retro,vintage,analog,rolls,develop,aesthetic,private,social,grain`

Note: 100 chars exactly. Keywords are research-informed for Photo & Video + Social Networking categories; "disposable," "film," "camera," and "photo" are must-haves for app store visibility; "friends," "private," and "rolls" emphasize the social/closed-network angle; "grain," "analog," "vintage," and "aesthetic" signal the signature visual style.

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
- None collected.

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
- **None.** No analytics SDK, no advertising, no third-party tracking. One-way social graph (follows) is optional; blocking is bidirectional and RLS-enforced.

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

> ## ⚠️ SUBMISSION BLOCKER: there is no way for a reviewer to sign in
>
> Verified against the current source: `AuthService` contains no reviewer path, no fixed code, no
> allowlisted email. FLIM is invite-only and sign-in is email OTP, so a reviewer who installs the
> build reaches the email screen and stops there. **Apple reviews every update, not just the
> first**, and an app a reviewer cannot get into is rejected on sight. 1.0 passed because it
> shipped a fixed-code branch that was deliberately stripped after approval.
>
> This is not a copy problem; it has to be built and shipped in the submitted binary, so it
> gates the whole submission. Pick one:
>
> 1. **Allowlist a reviewer email backed by a real inbox** (recommended). Create a dedicated
>    mailbox, allowlist it so it skips the invite requirement, and put the mailbox credentials in
>    App Review Information. The normal OTP flow then just works, nothing fake ships, and access
>    is revoked by deleting the account. Costs one small change in `AuthService` plus a mailbox.
> 2. **Re-add a scoped, time-boxed fixed-code branch** for this submission and strip it after.
>    Fastest, and it means shipping a hardcoded credential in a public binary. Only if 1 is not
>    possible before submitting.
> 3. **A read-only demo mode** needing no account. Cleanest for reviewers, most work, and it is a
>    new user-facing surface in a release whose whole point is stability. Not for 1.2.
>
> **Recommendation: option 1.** Whichever you pick, fill in the Sign-in block below and sign in
> once yourself with that exact flow before submitting.

> **FLIM is invite-only.** To demo the app:
>
> **Sign-in:** *(fill in per the decision above)*
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

**Setup before submission:**
1. Establish a reviewer sign-in path (see the warning above) and write the exact steps into the Sign-in block.
2. Sign in once yourself with that flow to set the username and confirm it works end-to-end.
3. Pre-seed test data (optional but recommended): follow a test account from the review account, create a roll, take a few photos so the reviewer sees a non-empty app.

**History:** 1.0 shipped with a fixed-code branch in `AuthService` gated on the exact email `review@flim-app.com` (that email skipped the OTP send; the code `482915` signed in via a password credential derived in-app). It was removed after approval so no hardcoded credential ships in the public binary. The matching Supabase Auth user should be deleted too if it still exists.
