# FLIM: App Store Connect listing

Copy-paste-ready metadata + a screenshot plan + reviewer notes. Tweak the voice to taste.

---

## Name & subtitle

Decided for 1.3 and NEVER APPLIED: App Store Connect still carried
`FLIM: Disposable Film Camera` on 2026-08-20 (verified against the live listing via the API),
because the rename is an owner-only ASC step and it slipped. Apply it with the 1.4.2 submission;
name and subtitle only ship with a version, so this is the moment.

| Field | Value | Chars |
|---|---|---|
| App name | `FLIM: Disposable Camera` | 23 / 30 |
| Subtitle | `Shoot film with your friends` | 28 / 30 |

Why dropping `Film` from the name is right, restated from the 1.3 decision below: FLIM and Film
two words apart reads as a typo, Apple does not fuzzy-match the pun, `film` stays fully indexed
from the subtitle, and the keyword field was already deduplicated assuming this name. FLIM also
now ranks first for the query `FLIM` regardless, so the brand token is doing its work without
help.

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
> Chapters: on the first of the month, the month you shared arrives on your page. It plays like a reveal and ends on the month in numbers. Every past month is there. (162 chars, for the 1.5.1 window)
>
> Superseded, 1.5 window: The reveal lost its timer: page a developed roll at your own speed. Invites are finite now, three each, and you earn one back when the friend you brought in shoots theirs. (169 chars, for the 1.5 window)
>
> Superseded, 1.4.2 window: New: badges for how you shoot, a Darkroom widget, a widget that resurfaces last month's frames, and a one-tap shutter on your Lock Screen. (135 chars)
>
> Evergreen, switch back anytime: Shoot together, wait together, see them together. FLIM is a disposable camera for your group. No filters to pick, no likes to chase, no feed to fall into.
>
> Previous (also fine, evergreen): Shoot on film, wait for it to develop, and share the moment with the people who actually matter. No likes to chase. No feed to doomscroll. Just your people.

## Description

> **PASTE THE BLOCK BELOW.** Paragraphs are single unwrapped lines on purpose; App Store Connect
> keeps your line breaks exactly as pasted, so hard-wrapping here produces a ragged listing.

    FLIM is a disposable camera for your closest friends.

    Point, shoot, and let it develop, just like the real thing. Personal shots land in your Darkroom right away. Shots into a shared roll stay hidden until the whole roll reveals at once, twelve hours after it started. Nobody sees them early, not even the person who took them. The waiting is what makes the reveal worth showing up for.

    Real film feel. Every photo gets FLIM's film look baked in at capture: warm color, grain through the midtones where film puts it, and the soft red glow real film gives a bright window or a streetlight. No filters. No sliders. One look, applied the moment you shoot, the same for everyone.

    Rolls for your people. Start a shared roll with up to 50 friends and shoot into it together. Everyone's photos land in the same place, and the whole roll develops at once. Trips, parties, nights out, all revealed together. Watch a roll fill up as its reveal gets closer, with a countdown on your lock screen, then play it back one shot at a time. Join with an invite code, comment on each other's photos, react with emojis.

    Chapters. On the first of every month, the month you shared arrives on your page as a cover. It plays like a reveal, fifteen frames picked on your phone, and ends on the month in numbers: your most reacted shot, your biggest fan, the hour you shoot at. You decide which numbers other people see. Every past month is already there, and any month can be shared as a contact sheet.

    A feed that's yours. Follow friends, see what they post, react and comment. Mention someone with @ to bring them into it. FLIM is invite-only, so everyone you see is someone a friend chose to let in. No public like counts. No algorithm deciding what you look at. No strangers.

    FEATURES
    • One film look, applied at capture, no post-processing
    • Twelve hour development window, with a roll's shots revealing together
    • Shared rolls with up to 50 members, joined by invite code
    • A reveal that plays your roll back one shot at a time, with a lock screen countdown
    • Chapters: every month you shared, as a playable recap with the month in numbers
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

## What's New (version 1.5.1)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    Chapters. On the first of every month, the month you just shared arrives on your page as a cover. Open it and it plays like a reveal: fifteen frames chosen on your phone for the ones worth seeing, then the month in numbers. Your most reacted shot, your biggest fan, the hour you shoot at, the day you shot the most, your longest streak, the people you filled rolls with. You choose which of those numbers other people see. Every past month is already there, and you can share any month as a contact sheet.

    Rolls got steadier. The reveal no longer steps back a frame while you scroll. A roll's photographs open in the order they were taken, and a viewer that used to stop at a hundred now holds the whole roll. A burst of near identical shots stacks into one frame in the grid, tap to fan it open, and the reveal plays the sharpest of them with a note about the rest. When a roll develops, everyone in it hears about it, not only the people who did not shoot. A roll that has already developed no longer takes new members.

    Notifications land where they say. A comment on a roll photograph opens that photograph with the thread. A reaction opens the photograph. The daily digest opens the top of the feed and counts only what arrived since you last opened the app, so it stops promising you things you have already seen. Everything that reaches your phone as a push now also appears in your activity, including the threads you joined but did not start.

    A photograph shared into a chapter opens as the post it is, with its reactions and its thread. The viewer's reactions row never shows the count from the frame you just left. And if the app ever asked you to retry an upload that had already gone through, it will stop asking on its own.

### Ship notes (internal, do NOT paste)

**Promotional text for the 1.5.1 window** (170 char max, editable anytime without review):

> Chapters: on the first of the month, the month you shared arrives on your page. It plays like a reveal and ends on the month in numbers. Every past month is there. (162 chars)

**What was deliberately left out of the copy.** The rename feature was removed (nothing to say
about a thing that is gone). The cross-account cache guard, the profiles view flip, the owner
identity pin and the join refusal's server side are all security or integrity work with no user
story; none is mentioned. Burst detection runs Vision on device and nothing about the image leaves
the phone; the copy says "chosen on your phone" and "near identical shots" and no more, because
the mechanism is not the point. The "you choose which numbers other people see" line is load
bearing for App Review: it names the control.

**The look did not change in 1.5.1.** Flash falloff shipped in this train (dec7b57) and grain was
tried and reverted the same week; the rendered look is byte identical to 1.5.0 except for flash
frames, which now carry real falloff. Screenshots shot on 345 are current.

**MARKETING_VERSION is 1.5.1 on BOTH targets in `project.yml`** since f8d1dd8 (2026-08-31); the
release candidate is build 345 (df918be). Releasing closes the train, so the first upload after
approval must carry 1.5.2 (or 1.6) or ASC rejects it with "Invalid Pre-Release Train".

After the release goes READY_FOR_SALE, arm the update nudge (the field is `latest_version`, NOT
`minimum_version`):

    update app_release_gate set latest_version = '1.5.1';

`minimum_version` stays 0.0.0.

**Release option:** choose "Manually release" at submission.

**Reviewer path:** confirm `ReviewerSignInSheet` still works against build 345 before submitting.

**App Privacy:** unchanged. Vision runs on device; the two new photo columns (`burst_group`,
`sharpness`) are derived integers inside the already declared Photos data type; the chapter stats
are aggregates of data already visible on the profile. No new data type, no tracking.

## What's New (version 1.5)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    The reveal is yours now. The timer is gone. When a roll develops you page through it at your own speed, and every frame still develops in front of you the first time you reach it. A strip along the bottom holds the whole roll at a glance, so you can jump to any frame and come back. Nothing moves on without you.

    Rolls got a screen worth opening. The roll you are shooting into sits at the top with its own countdown, the ones ready to open are gathered under it, and everything you have already seen keeps its place in an album below. Shooting into a roll takes one tap from anywhere on the page.

    The Darkroom got bigger. Your photographs are three across now and roughly twice the size, laid out as film: rows of frames on a perforated strip that ends where your shots end. Your profile and every roll read the same way.

    Every photograph shows its whole frame. Grids used to crop a quarter off the top and bottom of every shot to make it square. They do not any more, so what you framed is what you see, everywhere in the app.

    The feed stops taking things away. It used to clear itself as you read it. Now a week of your friends' photographs stays where you left it.

    Invites are real. Everyone has three. When someone you brought in takes their first photo, that invite comes back to you. Your page says how many you are holding, and the invite screen shows them as frames on a strip, with the spent ones marked by who they went to.

    And underneath: every word on screen answers to your text size, sharing a photo now says plainly whether it is going to your page or leaving the app, and covers and avatars stop flashing a letter at a photograph your phone already had.

### Ship notes (internal, do NOT paste)

**Promotional text for the 1.5 window** (170 char max, editable anytime without review):

> The reveal lost its timer: page a developed roll at your own speed. Invites are finite now, three each, and you earn one back when the friend you brought in shoots theirs. (169 chars)

**What was deliberately left out of the copy.** The security fix (any signed-in user could claim
the owner's email and reach the admin surface) is not mentioned: it was never exploited, disclosing
the shape of it in release notes helps nobody, and Apple does not require it. The invite-quota
mechanics beyond "three each and you earn one back" are also out, because the earn-back rule
(inviter only, on the invitee's FIRST PHOTO) is more detail than a release note should carry and
is stated in the app itself.

**Chapters was NOT in 1.5.** It was backlogged 2026-08-29 and shipped in 1.5.1 (see that
section above). Kept here so the 1.5 notes stay a true record of that release.

**The look did not change in 1.5.** If flash falloff and grain land before submission, this
section needs a paragraph and the screenshots need reshooting, because renditions are never
rewritten and the store screenshots would otherwise show a look the build no longer produces.

**MARKETING_VERSION must be 1.5.0 on BOTH targets in `project.yml`** before the submitted build is
made. Releasing closes the train, so the first upload after approval must carry the next bump or
ASC rejects it with "Invalid Pre-Release Train".

After the release goes READY_FOR_SALE, arm the update nudge (the field is `latest_version`, NOT
`minimum_version`):

    update app_release_gate set latest_version = '1.5.0';

`minimum_version` stays 0.0.0. Raising it above a build someone is still running hard-blocks that
install with no client-side recovery.

**Release option:** choose "Manually release" at submission, so the release moment is predictable
and the update nudge can be armed the same hour.

**Screenshots need reshooting for this train.** The Darkroom is three across, every grid is 3:4
rather than square, the Rolls screen was rebuilt, and the reveal has no progress bar. Existing
screenshots show none of that. `05-roll-invite-code.png` in particular now misrepresents the
invite mechanic, which is finite and shown as a film strip.

**Reviewer path:** FLIM is invite-only, so confirm `ReviewerSignInSheet` still works against the
current build before submitting. A reviewer who cannot get in is an automatic rejection.

## What's New (version 1.4.2)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    Badges. FLIM now keeps a record of how you shoot: your first light, the rolls you filled, the reveals you opened first, the people you brought in. Stamps come in founding, gold, silver, bronze and accent, struck like medals, and they only ever show what actually happened. Tap one on any profile and the page itself tells you what it means, and how to earn it if you have not. You pick which four lead on your page, or let your rarest four speak for themselves. New ones develop in when you come look. They never interrupt you.

    Widgets. A Darkroom widget counts the prints waiting on you and shows the roll developing right now. Look Back resurfaces a frame from a year, a month, or a week ago. A shutter on your Lock Screen opens the camera in one tap and quietly shows when a roll is ready. The developing countdown on your Lock Screen got restruck to match.

    Reactions got smarter. The quick row under a photo now offers six emoji, and up to three are guessed on your phone from what is actually in the photograph. Searching the full picker works the way you type: "laugh", "lol" and "bday" all find what you meant. And a reaction you pick lands at the front of the row, where you can see it arrive.

    And the usual sweep underneath: the feed loads lighter, the sort deck opens faster, and a deleted roll no longer counts down anywhere.

### Ship notes (internal, do NOT paste)

The badge push was built, shipped, and removed inside this train: badges are discovered, not
announced. The dot on the Home avatar and the "new badges to see" pill are the whole announcement
path, and `send-social-push` no longer flips `earned_badges.push_sent`.

After the release goes READY_FOR_SALE, arm the update nudge (this is the "minimum version" step,
and the field to touch is `latest_version`, NOT `minimum_version`):

    update app_release_gate set latest_version = '1.4.2';

`minimum_version` stays 0.0.0. Raising it above any build someone is still running hard-blocks
that install with no client-side recovery; the nudge from `latest_version` is the whole intent.

Name change ships with this submission: `FLIM: Disposable Camera` (see Name & subtitle above).
Keywords and subtitle unchanged, both already assume the new name's deduplication.

Check the App Privacy section while in there: it must list Crash Data (Diagnostics) and Product
Interaction (Usage Data), both linked to identity, to match what the privacy page now discloses
(crash reports since late July, the firsts and day counts). Review cross-checks the policy URL
against the labels, and the page was updated 2026-08-20.

Release option: choose it AT submission, on the version page, before Apple ever sees it.
"Automatically release this version" ships the moment review approves. "Manually release" holds
an approved build until the owner presses Release, which is the right choice here: it makes the
release moment predictable, so the update nudge can be armed the same hour.

## What's New (version 1.4.1)

> **PASTE ONLY THE INDENTED BLOCK BELOW.** Everything under "Ship notes" is internal.

    If you never saw the prompt asking about notifications, FLIM now asks again. Some people were never asked at all, which meant they quietly got nothing, and the only way out was deleting the app and reinstalling it. Your Profile also shows whether notifications are actually on, with a way to turn them on, instead of a switch that looked on either way.

    The keyboard goes away when you tap off it, or swipe the feed down. Before this there was no way to put it away at all once you started a comment.

    Replying says who you are replying to, right above where you type, with a way to call it off. Cancelling drops the reply and keeps what you had written.

    Tap a comment to open the thread.

    Deleting a photo you had posted now clears the post from your feed straight away instead of leaving a card behind for the next refresh.

    Tidier comments on each card, and a few small things sitting where they should.

### Ship notes (internal, do NOT paste)

Version gate shipped in this build (`app_release_gate`), but it can only ever act on 1.4.1 and
later: 1.4 has no code that reads it. It cannot be used to pull anyone up to 1.4.1.

The notification fix is the reason to get this out. 11 of 27 accounts had no push token, and its
one-time recovery only reaches an install once that install is running 1.4.1.

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

Five primary screenshots, in recommended App Store upload order (the first 2-3 appear prominently in search). **Reshoot on build 345**; the 1.5.0 set shows a square Darkroom, the old Rolls list, and a progress-bar reveal, none of which exist now.

1. **Feed.** A friend's post with the film look, the six-emoji reaction row, and the comment field. Caption: *"A feed that's just your friends."*

2. **Camera.** The live viewfinder with the roll pill showing a developing roll's countdown. Caption: *"Shoot like a disposable."*

3. **Chapters.** Your profile with the Chapters shelf between the actions and the film-strip grid, one cover tagged RECAP. Caption: *"Every month you shared, kept."*

4. **The month in numbers.** The closing card: most reacted with its thumb, biggest fan, golden hour, streak, longest gap. Caption: *"The month in numbers."*

5. **Rolls.** The Rolls screen with a developing roll at the top and its countdown, ready rolls gathered under it, the album below. Caption: *"Rolls for your people."*

**Spare:** the reveal mid-play with the film strip, and a roll grid with a burst stack showing its count.

Use the seeded demo content (`-seedDemo`), never a real account's photographs, and confirm no
recognizable face appears without consent.

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
