# FLIM — App Store Connect listing

Copy-paste-ready metadata + a screenshot plan + reviewer notes. Tweak the voice to taste.

---

## Name & subtitle options

### App name (30 char max)
1. **FLIM** (4 chars) — primary, brand-forward, short and memorable
2. **FLIM: Disposable Camera** (23 chars) — descriptive, keywords-loaded
3. **Film Rolls** (11 chars) — descriptive, generic alternative

### Subtitle (30 char max)
1. **Disposable camera for friends** (30 chars) — current choice, descriptive + social angle
2. **Shoot now, develop later** (25 chars) — action-oriented, emphasizes the core mechanic
3. **Shared rolls, real moments** (26 chars) — warm, social, emphasizes shared experience

**Recommendation:** Use app name `FLIM` + subtitle `Disposable camera for friends` (primary choice above).

## Promotional text (170 char max — editable anytime without review)
> Shoot on film, wait for it to develop, and share the moment with the people who actually matter. No likes to chase. No feed to doomscroll. Just your people.

## Description

> **FLIM is a disposable camera for your closest friends.**
>
> Point, shoot, and let it develop, just like the real thing. Your photos don't appear instantly. They take their time, revealing 12 hours after capture, so every roll feels like a little surprise waiting to happen. Grab an invite from a friend and start shooting.
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
- Push notifications for roll reveals
- Email OTP sign-in, invite-only access

## Keywords (100 char max, comma-separated, no spaces)
`disposable,film,camera,photo,friends,retro,vintage,analog,rolls,develop,aesthetic,private,social,grain`

Note: 100 chars exactly. Keywords are research-informed for Photo & Video + Social Networking categories; "disposable," "film," "camera," and "photo" are must-haves for app store visibility; "friends," "private," and "rolls" emphasize the social/closed-network angle; "grain," "analog," "vintage," and "aesthetic" signal the signature visual style.

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
- **Path 1 (Preferred):** **12+** — if Apple accepts the moderation controls + auto-hide + 24h review as sufficient (common for invite-only closed-network apps with UGC).
- **Path 2 (Fallback):** **17+** — if Apple requires a blanket UGC rating regardless of moderation. This is defensible for a social photo app.

**Recommendation:** Answer the questionnaire truthfully (all "Yes" above), emphasizing that moderation is built-in, automatic, and swift. Mention invite-only status (limits exposure). If Apple asks for a higher rating, accept it — 12+ vs. 17+ is not a material sales difference for a closed-network app, and overstating moderation will get rejected on review.

## Support & marketing URLs
- **Support URL:** `https://flim-app.com/support`
- **Marketing URL:** `https://flim-app.com`
- **Privacy Policy URL:** `https://flim-app.com/privacy`

---

## App Privacy ("nutrition label") worksheet

**Data collected & linked to the user:**

### Contact Info
- **Email address** — sign-in + account recovery. Not used for marketing or third-party sharing. Readable by the user only (column-level grants hide it from other users).

### User Content
- **Photos** — user-captured images, uploaded to encrypted private Storage. Accessible only to the user and roll members / followers (RLS-enforced).
- **Comments, reactions, tags** — social interactions on photos and posts. Stored per social item (post/photo).

### Identifiers
- **Device ID (APNs push token)** — for push notifications (roll reveals, social activity). Ephemeral; rotates when the OS issues a new one.

### Usage Data
- None collected.

### Tracking / Analytics
- **None.** No analytics SDK, no advertising, no third-party tracking. One-way social graph (follows) is optional; blocking is bidirectional and RLS-enforced.

**Not collected:** Location, contacts, browsing history, purchases, health data, search history, financial information, precise location.

**Privacy controls in-app:** Users can block others (bidirectional), report photos/posts/users for moderation review, delete their own photos, and delete their account (cascades to all their content).

---

## Screenshots (shot-list)
6.9" (iPhone 16 Pro Max) + 6.5" required. Shoot these on-device (clean status bar via `xcrun simctl status_bar` or a real device):
1. **The camera** — clean viewfinder + shutter. Caption: *"Shoot like a disposable."*
2. **The Darkroom grid** — a few developed shots. Caption: *"Watch them develop."*
3. **A feed post** — photo + reactions + a comment. Caption: *"A feed that's just your friends."*
4. **A shared roll** — roll cover + members. Caption: *"Start a roll together."*
5. **The reveal / a great developed photo full-screen.** Caption: *"Every moment, on film."*

Tip: seed a nice-looking account first so the screenshots aren't empty.

---

## Reviewer notes (App Store Connect → App Review Information)

> **FLIM is invite-only.** To demo the app:
>
> **Sign-in:**
> 1. Open FLIM, enter the email **review@flim-app.com**, and continue.
> 2. On the code screen, enter: **482915**
>    (No email is sent for this review account. The code above works directly, so no inbox access is needed.)
>
> **What to check:**
> - **Camera:** Tap the shutter to take a photo. Personal shots develop immediately and appear in the Darkroom; shots taken into a shared roll develop together 12 hours after the roll was created.
> - **Darkroom:** View your developed photos in the grid. Tap to view full-screen.
> - **Rolls:** Create a new roll or join an existing one using an invite code (try `TESTT1` for a pre-seeded test roll, or create one).
> - **Feed:** Browse posts from other users in the feed; like, comment, and react with emojis.
> - **Safety:** Tap ••• on any photo or post to **Report** or **Block** the user. Both actions are reachable from the UI. Reported content is auto-hidden after 2 reports and reviewed within 24 hours. Blocking is bidirectional.
> - **Notifications:** Grant notification permission to see push notifications when photos develop (local fallback works without APNs credentials).
>
> **Account access:** The reviewer account has full functionality. Photos uploaded by the reviewer are visible in the Darkroom and deletable via the ••• menu. The account can be created/deleted between review cycles; accounts older than 30 days with no posts are auto-deleted.

**Setup before submission:**
1. Create the demo account: Supabase Dashboard → Authentication → Add User → email `review@flim-app.com`, password `482915-flim-app-review-only`, auto-confirm ON. (No allowlist entry needed — the review path skips the invite gate and OTP send.)
2. Sign in once yourself with the flow above to set the username and confirm it works end-to-end.
3. Pre-seed test data (optional but recommended): follow a test account from the review account, create a roll, take a few photos so the reviewer sees a non-empty app.

**Technical detail:** the review path is a fixed-code branch in `AuthService` gated on the exact email `review@flim-app.com`: entering that email skips the OTP send, and the code `482915` signs in via a password credential derived in-app. It is unreachable for any other email, holds no privileged data, and the Supabase Auth user should be **deleted after approval** (the code path can stay; it's inert without the user).
