# FLIM — UI, usability, and social retention audit

September 12, 2026. Reviewed HEAD: `123c96d`.

## Main assessment

FLIM already has much of the social functionality it needs: a chronological feed, personal pages, captions, emoji reactions, comments, replies, comment likes, mentions, tags, shared rolls, and monthly chapters. The next opportunity is to make these feel like one understandable place to spend time with friends.

**The strongest product direction is everyday photo sharing with friends, supported by shared rolls for occasions.** A person should get value on an ordinary Tuesday when nobody is organizing a trip. Capture → shared roll → reveal → another roll is a valuable loop, but it cannot be the only definition of activation if people came back for Lapse's social experience.

The design already has an identity: dark surfaces, warm accents, restrained typography, large photographs, and film-strip navigation. Preserve that. The main work is clearer destinations, reliable feedback, easier friend finding, and stronger emphasis on the next social action.

My recommendation is to spend the next product batch on **first connection, first interaction, and first response**, alongside a small set of concrete usability fixes. Do not start with another major feature, a wholesale redesign, or more push campaigns.

## Scope and evidence

Three agents reviewed social/feed/profile UX, onboarding/camera/roll usability, and backend behavior affecting social feedback. The primary reviewer inspected the corresponding source and existing simulator demos.

- Current changes since `3efea93`: five commits, 20 files, approximately 835 insertions and 132 deletions.
- Source-confirmed findings are distinguished below from design recommendations and hypotheses requiring user observation.
- The installed simulator's feed and chapter preview harnesses were opened. The feed fixture lacked its externally planted photo assets; the chapter used synthetic numbered cards. These allowed limited inspection of layout and hierarchy, **not** production photo quality, actual loading performance, or a full authenticated journey. The installed demo binary was not established as an exact build of HEAD. Missing fixture images/glyphs are not reported as production defects.
- No application code or live data was changed. No messages or campaigns were sent. Tests and deployment records were inspected, not independently rerun. This report is the audit artifact.
- PENDING still distinguishes shipped 1.5.2/build 365 from native work in the next train. Verify installed-client rollout before declaring a source fix available to everyone.

For context, Lapse's current App Store release notes describe a return to a disposable camera for keeping memories. The relevant reference for this audit is its former social experience, not a claim that its camera is unavailable. [Lapse App Store listing](https://apps.apple.com/us/app/lapse-disposable-camera/id1636699256).

## What to preserve

1. **The photographic identity.** The camera look and image hierarchy are established. Avoid another grain/codec redesign in a usability batch.
2. **People/day grouping.** It makes the feed about a person's day rather than a contest among individual posts. Keep reactions and comments clearly attached to the selected photograph.
3. **Low-pressure expression.** Emoji reactions, comments, and a calm caught-up state already support casual participation. No need for streak penalties, compulsory posting, or endless content.
4. **Durable personal pages and chapters.** These give users something that feels like theirs, beyond the latest feed window.
5. **Explainable discovery.** Existing inviter, roll-mate, follower, and mutual-connection signals are a good foundation. Do not pad the list with random people merely to make it look busy.
6. **Shared-roll consent.** Follow-up rolls invite people; they do not silently enroll them. Members being able to save their roll's photos is now an explicit product decision.
7. **Fast camera access and contextual introductions.** Keep the short onboarding approach. Improve what it communicates instead of restoring a long tutorial.

## The two social loops

| Everyday use | Shared occasion |
|---|---|
| Recognize a friend | Join a familiar group's roll |
| See their recent photographs | Contribute a photograph |
| React or leave a comment | Know who is participating and when it reveals |
| Share something from your own day | Return for everyone's photographs |
| Receive a response and reply | React, comment, save, or start another |
| Return for the people | Return for the group |

Both are already supported in large part. The product should help users enter either loop without requiring them to understand every part of Camera, Darkroom, Rolls, Feed, Page, and Chapters first.

## Concrete usability defects to fix first

### 1. High priority — Sorting accepts multiple actions during one card transition

**Source-confirmed:** `Flim/Views/Darkroom/SortDeckView.swift:340–368`.

`performSwipe` takes `cards.first` and schedules removal 280 milliseconds later. There is no transition/in-flight guard. Two quick taps can both act on photo A, then each remove a card, causing unreviewed photo B to disappear from the current deck. Keep followed by Delete can also stage contradictory actions on A.

This is especially damaging in an app whose value depends on trusting where a photograph went. It need not permanently delete B to feel like lost work.

**Change:** Claim a photo once, prevent a second action during its transition, and make delayed work address the captured photo ID. Preserve undo. Verify repeated taps, swipe-plus-tap, and rapid conflicting actions with three distinct photos.

### 2. P2 — Activity consumes the unread signal before showing the activity

**Source-confirmed:** `FeedView.swift:363–368`; `ActivityFeedView.swift:160–174`.

Tapping the bell updates the seen timestamp and clears the unread count before Activity fetches its content. If loading fails or the sheet is dismissed before content arrives, the next visit's New boundary has already advanced.

**Change:** Advance the read watermark after successfully presenting the corresponding events. A failed load should retain the unread signal and offer Retry. Distinguish opening Activity from actually receiving its contents.

### 3. P2 — Friend search says “No one matches” before the search finishes

**Source-confirmed:** `UserPageView.swift:983–987, 1022–1035`; `FeedService.swift:607–620`.

The general `loaded` flag remains true after initial suggestions. Typing can therefore produce a no-match message during the 300ms debounce and network request. Search failure is also converted to an empty array. After the awaited request there is no query/generation check to ensure its results still belong to the current search.

For a small social network, telling someone a real friend does not exist is a high-cost mistake.

**Change:** Explicit states for suggestions, searching, results, no results, and failure. Retain the query identity through the request. Say “No match for…” only after that exact query succeeds with no results. Provide Retry on failure and a clear invite alternative after a real no-match.

### 4. P2 — Activity cannot refresh while someone stays in it

**Source-confirmed:** `ActivityFeedView.swift:126–160`.

Activity loads on entry but has no pull-to-refresh or visible-screen refresh. Someone following a conversation must close and reopen the sheet to see new events.

**Change:** Add pull-to-refresh first. Preserve scroll position and already loaded content on failure. Consider modest foreground refresh later if observed conversation use warrants it. This does not require merging Feed and Activity.

### 5. P2 — A local-save failure warning may never appear

**Source-confirmed:** `PhotoService.swift:177–181, 356`; `CameraView.swift:624–633`.

Raw persistence failure sets `uploadError`, but the camera renders that message only when there are failed uploads. A locally unsaved shot waiting for upload does not necessarily enter that list; upload startup then clears the warning.

**Change:** Separate local safety from network upload status. If a shot exists only in memory, make that visible immediately and keep the message until local persistence or server success resolves it. Do not display “saved” prematurely.

### 6. P2 — Uploading and developing are presented as the same state

**Source-confirmed:** `CameraView.swift:562–579`.

The VoiceOver label for a single upload is “Developing.” Network upload and the intentional roll reveal delay are different events. A personal shot is not waiting for a group reveal.

**Change:** Use consistent language: “Saving on this phone,” “Uploading,” “Saved,” and separately “Reveals at 9 PM.” Keep visual chrome compact while exposing the full meaning to accessibility.

### 7. P2 — A successful notification recipient can cancel another person's retry

**Source-confirmed:** `supabase/functions/send-social-push/index.ts:321–322, 772, 1076`.

For multi-recipient comments, one failure adds the source to `pendingRetry`; a later success deletes the same source key. The comment can then be marked fully sent even though its owner or another participant never received the notification.

This is a backend bug with direct social impact: someone replies, but the person they hoped would respond is not notified.

**Change:** Settle the source only after aggregating every required recipient's result. One person's success cannot clear another person's failure. Test owner failure followed by participant success, and the reverse order.

### 8. P3 — Empty-feed copy contradicts the friend finder

**Source-confirmed:** `FeedView.swift:680`; `UserPageView.swift:997–1004`.

The empty feed says nobody is suggested or ranked, immediately beside a button opening contextual suggestions.

**Change:** Explain the action rather than defending the product philosophy. Suggested copy: “Find someone you know, or invite a friend.” Where relevant, explain that feed posts are chronological and Find friends uses existing connections.

## Screen-by-screen design recommendations

These are product recommendations, not claims of measured conversion improvement.

### Entry and onboarding: establish a social reason without slowing capture

Current onboarding says “FLIM is a camera” and explains the finished look (`OnboardingView.swift:62–74`). That is accurate, but does not distinguish the reason this community returned.

Test a short line such as **“A camera for the moments you share with friends.”** Keep the existing camera CTA. For invited arrivals, prioritize the known context: who invited them and, for a roll, its name and reveal time. The app already preserves inviter and roll-link context; use that information rather than adding a generic tutorial.

After entry, make the next social action relevant to the arrival:

- Personal invitation: make the inviter recognizable and their page easy to open.
- Roll invitation: join the intended roll and offer a first contribution.
- Public campaign: help locate a known person; do not imply everyone admitted by the same campaign is a real-life friend.

Do not require several follows, contacts access, or invitations before allowing use. Optional name/color setup can move later if observed sessions show it obstructs entry; do not remove it solely on theory.

### Navigation: make the social destination easier to discover

`MainTabView.swift:80, 160–180` starts on Camera and orders Camera, Darkroom, Rolls, Feed. That is coherent for a camera tool. For someone returning to see friends, the social surface is the last tab.

**Test, rather than immediately reorder:** preserve the last meaningful tab on ordinary returns, retain direct camera/notification deep links, and compare social task completion. Camera launch must remain fast when that is the user's intent. Do not force every return into a capture task or surprise current users with a wholesale navigation change.

Keep Feed and Activity separate, respecting the existing decision. Improve the bell's reliability and make its accessibility label/read state meaningful. Profile access through the feed header should be checked in unprompted sessions; do not add a fifth tab before knowing people cannot find their page.

### Feed: make photographs feel like invitations to respond

The per-person/day presentation is a strength. The fixture screen shows a large photo area, filmstrip, reactions, caption, and comment preview. With a long card, some conversation content sits low in the viewport. Because the demo lacked real images and the normal tab container, that is a hierarchy hypothesis to test, not a production clipping finding.

Watch whether newcomers can:

1. Notice that a friend's day contains more than one photo.
2. Move to the next frame without accidentally leaving the day.
3. Identify which frame a reaction/comment targets.
4. Read a caption, reply, and return to their previous position.

If the filmstrip is missed, add a restrained current/total cue such as “3 of 14” or improve the existing selected-frame affordance. Do not stack more competing badges above every photo.

Keep an obvious “Add a comment”/reply entry. Captions, replies, likes, tags, and mentions already exist; the task is their discoverability and reliability, not building duplicate social controls.

The feed's seven-day window (`FeedUnit.swift:288`) should have a clear route to the friend's older page/chapters. In a small network, a quiet recent feed must not imply all memories disappeared. Preserve the calm caught-up state and offer a specific, optional action instead of endless suggestions.

### Darkroom and sorting: reduce the feeling of administration

“Sort” describes a task; newcomers need to understand the benefit: decide what stays private and what goes on their page. Keep those consequences near the actions.

The current controls make Delete the largest central button (64 points versus 54 for Keep/Post; `SortDeckView.swift:274–279`). **Design recommendation:** reduce destructive visual prominence. Give Keep/Post at least equal emphasis and retain a clear, accessible delete action and undo. The source establishes the size difference; user testing should establish how much it affects mistakes.

Do not make caption/tag editing mandatory before posting. Keep fast sharing, but ensure the optional compose action is recognizable. After a post, a lightweight “Posted to your page” confirmation with “View” would help users understand where it went. This must not override the owner's chosen first-sort landing in Darkroom.

Use consistent destination language:

| Action | Meaning to communicate |
|---|---|
| Keep personal photo | Only you, in Darkroom |
| Post | Visible on your page under the current member-access policy |
| Shoot into a roll | Shared with that roll's members when it reveals |
| Save/export | A file leaves FLIM for the device/share destination |

Do not imply “Keep” saves to the system Photos library. Do not call posts friends-only while other members may open the page. The owner deferred changing the audience policy; accurate labels are the immediate requirement.

### Rolls: turn joining into participation

Create/join confirmations end with “Done” (`CreateRollView.swift:157`, `JoinRollView.swift:131`). The code already selects the roll as the camera destination, but the button does not explain what to do next.

Recommended primary actions: **“Take the first photo”** for a new roll or **“Shoot into [roll]”** after joining. Route to the selected camera destination; keep invite sharing available as secondary. Where a developed roll is being opened, the action should describe viewing instead.

The default twelve-hour delay is not inherently a flaw. Its waiting screen needs immediate social reassurance: recognizable members, participation/frame counts where appropriate, and an exact reveal time. Never expose hidden photos just to make the waiting state busier.

“Start another with this group” already exists. Consider presenting it at a natural reveal completion point as well as in the detail menu. It should remain optional and invite-based.

### Activity: make responses easy to notice and continue

Treat this as a conversation inbox, not a record of application events. Preserve photo thumbnails, actor identity, comment previews, follow-back, and exact-thread routing.

Fix unread timing and refresh before adding visual polish. Then review hierarchy: comments and mentions should remain directly actionable; multiple reactions can be grouped without hiding who responded. Preserve a person's place when opening a photo and returning.

Do not add a generic badge merely to manufacture urgency. The signal should mean there is something the person can actually read or respond to.

### Profiles and chapters: make the archive personal and social

The chapter demo has a strong visual hierarchy: month, a small summary, a photo stack, and one clear “Play the month” CTA. Preserve that simplicity.

Monthly chapters should not be the first time the app feels rewarding. New users need a satisfying page with their first few shared photos. At the end of a chapter, an optional return to a meaningful photograph/comment is more aligned with the app than another score or badge.

Good future enhancements: choosing a chapter cover, excluding a frame from a recap, and more control over permitted exports. These extend existing value. They should follow reliable first-week social participation.

## Accessibility and visual consistency

- **Targets:** Feed first-run/caught-up CTAs have explicit 38-point heights; a post menu is 34×34 (`FeedView.swift:606, 654, 671`; `FeedUnitCard.swift:296–299`). Expand interactive areas without making all chrome visually heavy.
- **Labels:** Username color choices are 30-point circles without descriptive labels/selected values (`UsernameView.swift:75–85`). Make each color name and selection available to VoiceOver.
- **Text:** The shared theme already improves tertiary contrast, but some screens use direct dark-gray values. Audit instructional/error text and important actions, not just theme tokens. Actual contrast through glass/materials requires rendered checks.
- **Large text:** The global ceiling is `.accessibility2` (`FlimFont.swift:100–107`). Reflow fixed layouts before raising it. Test the smallest supported phone, keyboard open, and long names/captions.
- **State language:** Standardize loading, saving, uploading, developing, posting, and exporting. They describe different promises.
- **Feedback:** Success should confirm the user's intention—“Posted,” “Joined,” “Saved on this phone”—while failures preserve a clear next action. A haptic alone is not enough.

## Features worth considering, in order

1. **An easier first social connection:** contextual inviter/roll-mate entry using existing discovery, with explicit follow behavior.
2. **A reliable reply-and-return loop:** Activity refresh/read state and uninterrupted navigation back to a conversation.
3. **A lightweight post-success bridge:** view the posted photo/page or continue photographing, without another mandatory sheet.
4. **Natural repeat-group continuation:** surface the existing follow-up action after a reveal.
5. **Personal recap choices:** cover/pick exclusions and dependable exports.

I would not lead with DMs, a public discovery feed, streaks, forced invites, more badge systems, a feed/Activity merge, or a new camera look. These either conflict with prior decisions or need evidence that they solve a real unmet social need.

One larger strategic distinction should remain visible: Lapse's friends-oriented feeling and FLIM's one-way following/member-readable pages are not identical. The current audience decision is deferred, so this is a product-model consideration for later discussion, not authorization to change privacy or relationship semantics now.

## How to tell whether the changes work

At 60+ users, report absolute counts alongside percentages and examine group-level behavior. Avoid claiming improvement from a handful of percentage-point changes.

**Everyday social funnel:** account created → recognizes/connects with someone → sees a friend's photograph → reacts/comments → posts/contributes → receives a response from another person → returns and interacts again.

**Shared-roll funnel:** invited → joins intended roll → durable first contribution → at least two contributors → reveal viewed → response/save → second participating roll.

Useful measures:

- New users making a friend-photo interaction in their first session and first day.
- Contributors receiving a reaction/comment from another person within 24 hours.
- Median time to first response; separately count people receiving no response.
- Reciprocal active relationships per week, not merely follower totals.
- Return to the same person's conversation or group within seven days.
- Friend searches that successfully open a known person's page versus no-match/error abandonment.
- Personal-post and shared-roll participation separately.
- Owner/campaign outreach separately from organic friend interaction.

Derive response metrics from existing server records where possible. Add client instrumentation only where it answers a decision, and avoid storing comment text or media just for analytics. Fix delivery defects before using missing responses as evidence of weak interest.

### A small usability study before a larger redesign

Recruit five willing people: two former Lapse social users, two newcomers joining an existing friend, and one infrequent current user. Use consented test accounts/content. This is a proposed study, not research performed during the audit.

Ask them to do these without teaching the interface:

1. Find a specific friend and see their newest photographs.
2. React to the second photo and leave a comment on that exact photo.
3. Take a photo, keep one private, and post another; explain who can see each.
4. Open a reply notification and respond.
5. Join a roll, take a photo into it, and explain when everyone can see it.
6. Find an older memory or chapter and save an eligible photo.

Record hesitation, wrong turns, misunderstood audiences, accidental actions, and completion time. Ask “What do you expect this button to do?” before correcting anyone. Include keyboard, VoiceOver/large-text checks where participants or a separate accessibility pass can support them.

## Latest reliability changes: brief status

The previous audit generated substantial fixes. Current source now contains account-bound retry/restore, a real scoped activation flush with migration, path-bound re-signed URLs, refresh generation carried through setup, follow-up quota checked inside its lock, corrected invitation rollback/errors, photo-to-post rendition synchronization, and a schema bootstrap/replay CI check. A unified per-shot recovery entry was also added.

These are meaningful improvements. This UI pass did not rerun all transport, crash, migration, or production checks and should not be treated as a replacement for that verification. The local-save-warning visibility and multi-recipient notification bug above show why user-visible outcomes still need to be tested end to end.

R2 remains separate infrastructure work. For this next batch, preserve image quality, use existing renditions, and avoid adding expensive video/chat infrastructure without demand. Future monetization should protect free social participation; supporter or event-host benefits should fund the experience rather than gate reading a friend's reply or seeing a shared reveal.

## Recommended implementation order

**Batch 1 — Make core interactions trustworthy:** sort transition guard; correct Activity read timing; real search states; Activity refresh; visible capture-safety status; aggregate notification recipient outcomes.

**Batch 2 — Make the first social session clearer:** contextual arrival copy; recognizable inviter/friend route; action-oriented roll completion; consistent private/post/roll/save labels; larger targets and accessibility labels. Preserve camera speed and first-sort destination.

**Batch 3 — Observe and refine:** run the usability study; measure first interaction/response and repeat relationships; then decide whether navigation/resume behavior, filmstrip affordances, recap controls, or new features deserve investment.

The success criterion is not simply that more people open FLIM or take a picture. It is that people find someone they care about, share ordinary moments, receive a response, and want to return to that person or group.
