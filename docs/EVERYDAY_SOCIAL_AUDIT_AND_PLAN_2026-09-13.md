# FLIM: everyday photos with friends

## Audit and product game plan — September 13, 2026

**Product center:** A place to share everyday photos with friends, with a camera that makes those moments feel special.

Reviewed HEAD: `98ccbbd`. Comparison baseline: `123c96d`, used for the September 12 UI/social audit. Seven intervening commits changed 65 files, including archived review documents. Three agents reviewed product UX, client usability/reliability, and backend audience/measurement behavior; the primary reviewer cross-checked the findings and developed this plan.

This was a read-only source audit. No application code, production data, deployments, campaigns, or automations were changed. Tests were inspected, not run. Saved production observations below come from repository documents and were not freshly queried. This document is the deliverable. Native changes in HEAD must not be assumed available in the shipped App Store binary; verify release/build status separately.

## 1. Where FLIM is now

**FLIM has enough functionality to deliver its intended social experience. The immediate priority is to make the journey between those functions coherent and dependable.**

The everyday loop should be:

> See something from someone you know → respond → share a moment of your own → receive a response → return to that person.

The camera makes creating those moments appealing. Shared rolls bring a group's perspectives together. Chapters make the accumulated photos worth revisiting. Each contributes to the same purpose, without requiring an event or a large audience to enjoy the app.

The latest changes substantially improve this foundation: safer sorting, honest friend search, refreshable Activity, action-oriented roll confirmations, clearer labels, accessibility work, follower-based post access, and useful measurement infrastructure.

The remaining defects are concentrated in **transitions**: follow → content appears; post → view destination; Activity load → unread acknowledgement; private content → notification recipient. Correcting those is more valuable than another major social feature right now.

### What the recorded usage says

| Saved observation | Evidence | Interpretation |
|---|---|---|
| September 12: 70 accounts, 32 openers, 18 shooters, 106 photos, 43 posts, 180 post reactions, four post comments | `docs/NUMBERS.md` | There is already everyday creation and lightweight social response. This is one day's snapshot, not a retention rate. |
| September cohort measured September 13: 20 accounts; 12 followed beyond their inviter; eight reacted/commented; seven posted; all seven received a response; 15 returned another day | `docs/METRICS.md:227–231` | Encouraging evidence for the everyday loop. These are overlapping milestone counts, not an ordered conversion funnel. |
| Same cohort: two joined another person's roll, one contributed, one watched a reveal | Same source | Make everyday sharing the main entry experience; keep improving rolls as a separate use case. This small sample does not justify removing rolls. |
| Since September 1: 335 posts, 309 answered, median first response 42 minutes, 191 answered within an hour, 25 older posts unanswered | `docs/METRICS.md:242–244` | Responses are already a real part of the experience. Separate organic responses from owner outreach before claiming a self-sustaining community. |

Do not infer that four comments means conversation is failing, or that zero rolls on one day means rolls have no value. The useful question is whether people get the kind of connection they came for and return to the same people.

## 2. Audit findings

### A1 — P2: Following can reveal an apparently empty profile

**Evidence:** `Flim/Services/FeedService.swift:194–199`; `Flim/Views/Feed/UserPageView.swift:191`.

Following is optimistic: `followingIds` changes before the database insert completes. The profile observes that change and immediately reloads its newly restricted posts. That request can beat the follow commit, legitimately receive no rows, and leave the page saying there are no posts. Successful follow completion does not change the observed value again.

**Fix direction:** Separate pending button feedback from confirmed relationship state. Fetch restricted content after the follow succeeds, or reconcile it using a confirmed relationship revision.

**Acceptance:** On a slow/reordered connection, following a populated profile reveals its posts without manual refresh. Failed follow restores a coherent state and offers retry.

### A2 — P2: Unfollowing leaves already loaded photos and chapters visible

**Evidence:** `UserPageView.swift:153–191`.

The new observer handles only becoming a follower. It does not conceal/reload content when following ends; loaded posts and chapters can remain on screen.

**Fix direction:** Immediately switch the profile to the appropriate nonfollower state and invalidate relevant presentation caches after unfollowing. Respect the explicit tagged-post exception rather than hiding content indiscriminately.

**Acceptance:** Follow → view → unfollow updates the visible page immediately. Reopening does not restore a stale follower-only grid. Previously downloaded files and signed-URL lifetimes need a separate documented cache policy; a UI change alone does not revoke all cached bytes.

### A3 — P1: Notifications do not consistently apply the new post audience

**Evidence:** `supabase/migrations/2026-09-13_followers_only_reads.sql:1–55`; `supabase/functions/send-social-push/index.ts:737–769`.

Post/table/storage/chapter reads now use follower or explicit post-tag eligibility. Service-role social notification paths still mainly check blocks and covered-post rules. A comment mention can send protected text and a deep link to a nonfollower who cannot open the post. A previous thread participant who unfollows can also receive later comment previews.

**Fix direction:** Check current recipient/post eligibility before sending protected text or a deep link. If comment mentions are intended to grant access, that must be an explicit product exception implemented consistently; currently the SQL exception is for explicit photo tags.

**Acceptance:** Test follower, nonfollower mention, tagged nonfollower, former participant after unfollow, blocked account, and post owner. Nobody receives protected previews they are not allowed to read. Every permitted notification opens its intended content.

**Related small metadata gap:** `get_suggested_emoji`'s SECURITY DEFINER posted-photo branch (`supabase/schema.sql:5120–5135`) does not use the new audience predicate. A caller knowing the photo ID can obtain its suggested emoji. This is not an image-byte bypass, but should be included in the boundary review.

### A4 — P2: Activity can acknowledge a reply absent from the fetched list

**Evidence:** `ActivityFeedView.swift:178–197`; `FeedView.swift:319–321`.

Activity now waits for successful loading before acknowledgement, which fixes the previous defect. It still stamps the current time after fetching activity and awaiting supporting data/image URLs. A reply arriving after the query snapshot but before that callback can fall before the new seen timestamp without ever appearing on screen.

**Fix direction:** Acknowledge a captured query boundary or an explicit returned event watermark. Check that the presentation is still active before consuming unread state.

**Acceptance:** Pause thumbnail resolution, create a new reply, then let loading finish. The new reply remains unread until it has actually been retrieved/presented.

### A5 — P2: Local capture-safety warning still clears too early

**Evidence:** `PhotoService.swift:181–185, 361`; `CameraView.swift:626`.

The new `localSaveFailed` flag makes the warning eligible to display, but upload startup still clears `uploadError`. The camera requires a non-nil message, so the warning can disappear before a durable replacement or successful upload exists.

**Fix direction:** Keep local persistence state and its message separate from network upload errors, scoped per capture. Clear only when that shot is safely persisted or confirmed uploaded.

**Acceptance:** Simulate raw-save failure followed by a delayed upload. The warning remains visible and accessible until the photo is safe; another successful shot must not clear it incorrectly.

### A6 — P2: Explicit “View” navigation can lose to a default destination

**Evidence:** `SortDeckView.swift:157–162, 407–419`.

The posted confirmation's View action starts closing the sort deck and immediately requests the user's page. The close path can later complete pending work and issue the first-sort Darkroom destination. That later default can override what the person explicitly requested.

**Fix direction:** Pass the intended destination through a single close/navigation operation. Explicit View should override the default first-sort landing; ordinary first-sort completion should continue to land in Darkroom as previously chosen.

**Acceptance:** On a new account, post and tap View with a delayed commit. The page opens once, with the new post. Closing normally still returns to Darkroom.

### A7 — P2: Reveal follow-up presentation needs dismissal sequencing

**Evidence:** `RollRevealView.swift:544–548`; `RollDetailView.swift:715–719`; existing review `docs/reviews/2026-09-13.md`.

The closing-card action dismisses a full-screen reveal and requests a sibling sheet in the same handler. This creates competing presentation transitions; the sheet can fail to appear. The source pattern is confirmed, but device reproduction was not performed in this audit.

**Fix direction:** Store the follow-up intent and present only after the cover's dismissal completes. Use one owner for that presentation sequence.

**Acceptance:** Repeatedly finish a reveal and tap Start another, including slow animations and Reduce Motion. The create sheet appears exactly once.

### A8 — P3: Several confirmations still need ownership or destination checks

- The posted notice's unscoped three-second timer can hide a newer notice (`SortDeckView.swift:445–449`). Tie expiry to the notice/post identity.
- The developed-roll Join branch says “See the roll” but only dismisses (`JoinRollView.swift:131–132`). Explicitly route to the joined roll when that branch is reached.
- Visible publishing text often says only “Post to your page,” while the precise follower audience is mainly elsewhere/accessibility copy (`ShareToFeedSheet.swift:61–65, 152, 303`; `SortDeckView.swift:309`). Include one short visible audience line where the decision is made.

### A9 — P2 for decision quality: Measurement labels overstate what the queries prove

**Evidence:** `supabase/migrations/2026-09-13_funnels.sql`; `2026-09-13_nightly_numbers.sql`.

The new queries are useful, but:

- `weekly_funnels` counts milestones independently. It does not establish that the same people performed steps in order, in a fixed first-week window.
- “Reacted or commented on a friend” means another person's post; it does not establish reciprocal friendship.
- “Never got a response” considers aged posts. Someone with an unanswered old post and an answered recent post can still enter that group.
- The seven-day opener average excludes dates with no activity rows, inflating the average if a day is empty.
- `reports_open` counts reports whose notification is unsent. Notification delivery does not mean moderation was resolved.

**Fix direction:** Rename the current report to cohort milestones or add a genuinely ordered, bounded funnel; fix the response and zero-day calculations; track moderation status separately. Segment owner outreach, app builds, and arrival type before making product conclusions.

## 3. What the previous audit successfully changed

| Area | Current source assessment |
|---|---|
| Rapid sorting | Transition guard and captured-ID removal close the double-action/skipped-card case. |
| Friend search | Explicit loading/no-result/error states, retry, and stale-result checks added. |
| Activity | Refresh added; old content preserved on refresh failure; acknowledgement moved after success. Watermark race remains narrower work. |
| Roll confirmations | Active create/join actions now describe taking a photo and route to camera. |
| Reveal and waiting state | Follow-up action and group participation information added. Verify the new presentation path. |
| Upload label | Accessibility says Uploading instead of Developing. |
| Destructive emphasis | Delete reduced to the same control size as Keep/Post. |
| Accessibility | Larger/minimum-height controls, scrolling auth surfaces, color labels, and a higher Dynamic Type ceiling. Device validation remains required. |
| Social push settlement | The previous failure-erased-by-another-success bug is fixed in source. New audience gating is the next issue. |
| Privacy | Posts, image access, and chapter source reads now enforce follower/tag access. Do not repeat the old ordinary-member access finding. |
| Measurement/study | Nightly numbers, two milestone reports, first-response statistics, and a concrete study kit now exist. Use and refine them. |

The nightly review ledger contains many historical entries labeled unverified. Do not treat their count as a count of current defects. Triage against HEAD, record closure evidence, and keep one active issue list rather than commissioning parallel implementations of stale findings.

## 4. The product contract

### Promise

**FLIM is a place to share everyday photos with friends, with a camera that makes those moments feel special.**

Suggested short expression: **“Everyday moments. Shared with friends.”**

The experience should satisfy five rules:

1. Opening FLIM can be worthwhile without taking a photo.
2. Sharing a small, ordinary moment is enough; no occasion or polished caption is required.
3. A person understands who can see the photo before sharing it.
4. Replies and reactions lead back to the exact photograph and person.
5. Personal memories remain useful after they leave the recent feed.

### Each surface's job

| Surface | Primary user question | Primary outcome |
|---|---|---|
| Feed | What have my people been up to? | See, react, or reply to a familiar person |
| Camera | Can I capture this moment now? | Fast, trustworthy capture with the FLIM look |
| Darkroom | What do I want to keep private or share? | A clear privacy/sharing choice |
| My page | What have I shared? | Recognizable personal history and a clear first-post route |
| Activity | Who responded, and what can I respond to? | Continue a conversation |
| Rolls | What did this occasion look like to all of us? | Shared contribution and reveal |
| Chapters | What do I want to remember from this month? | Revisit and personalize a meaningful collection |

This is a hierarchy of purpose, not a mandate to remove tabs. Keep Feed and Activity separate. Preserve camera deep links, the approved film look, and the chosen first-sort landing.

### State the audience accurately

The new rule is **followers**, with instant one-way following and explicit tag exceptions. It is not approval-based friendship or a private account. Use “Visible to people who follow you” at posting, with an accessible explanation of exceptions. Do not promise approved-friend privacy.

Treat the viewer's own photos, their shared-roll photos, and another person's feed/chapter content according to the current export policy. Marketing shorthand must not substitute for precise controls.

## 5. Game plan

### Batch 0 — Finish the transitions that can undermine the promise

**Priority:** A1–A6 first; include A7/A8 as bounded presentation fixes. Apply A3 to the backend before expanding public traffic.

**Work:** confirmed follow/content loading, unfollow presentation invalidation, authorized notification previews, Activity watermark, per-photo safety status, and one destination per close action.

**Owners by discipline:** backend for recipient authorization; iOS services for relationship/read/persistence state; iOS presentation for navigation and sheet ownership; QA for suspended-request and device scenarios.

**Exit gate:** Two ordinary test accounts can follow, view, unfollow, post, reply, and reopen notifications under slow/failing requests without misleading content, unread loss, or unauthorized previews. A new user's View CTA opens the promised page. Record exact client build and migration state.

### Batch 1 — Give every entry point the same center

This is a small content/entry-flow release, not a full visual redesign.

| Entry/screen | Current emphasis | Proposed change |
|---|---|---|
| Website hero and store introduction | Disposable camera and baked-in look | Lead with everyday photos and friends; immediately support it with the distinctive camera look. |
| Onboarding | “FLIM is a camera.” | Test “Everyday photos, shared with friends.” Supporting line: “Point, shoot, and share the moments in between.” Keep the direct camera action. |
| Personal invite arrival | Preserved inviter context and automatic inviter follow | Show a recognizable inviter and “See [name]'s photos” when appropriate. Do not ask to follow someone already followed. |
| Roll invite arrival | Join context | Preserve the roll intent, reveal time, and Shoot into this roll action. |
| Public campaign arrival | Common inviter plus discovery | Help find a known person; do not treat unrelated campaign members as a genuine friend group. |
| Publishing | Destination wording spread across surfaces | One consistent visible audience statement and a reliable Posted → View path. |
| Own empty page | No posts yet | One clear route to share a photo already in Darkroom, or take a first photo if none exists. |

**Dependencies:** Confirm actual current entry routing before inserting more surfaces. Reuse existing inviter/discovery and notification destinations. No compulsory follow quota, posting quota, contact permission, or new onboarding carousel.

**Exit gate:** Unprompted participants can describe FLIM's purpose, find their known person, and explain private versus follower-shared photos. A returning user is not shown first-run guidance again.

### Batch 2 — Make returning for people easy

Current normal launch starts on Camera, with Feed fourth (`MainTabView.swift:80, 162–180`). This may serve camera intent well and social intent poorly. It is a testable design question, not a confirmed bug.

**Recommended experiment:** Resume the last meaningful tab on an ordinary return. Keep widget/quick-capture launch on Camera and notification/invite launch at the intended destination. If first-time entry has no contextual destination, preserve immediate camera access and a clear route to friends. Consider Feed as a returning-user fallback only after observing the study; do not change launch policy and tab order simultaneously.

Within Feed, verify the existing filmstrip makes multiple photos discoverable, the selected frame is obvious, and reactions/replies target that frame. Add a restrained selected/total cue only if observation shows the existing affordance is missed.

Within Activity, preserve location when opening and returning from a thread. Make comment/mention previews actionable; keep reactions lightweight. Do not turn caught-up states into endless content or pressure to post.

**Exit gate:** Returning participants reach a friend's photograph or conversation with fewer wrong turns, while quick capture remains immediate and does not acquire new setup steps. Evaluate observed completion and counts, not just more app opens.

### Batch 3 — Reinforce response and personal continuity

After entry and navigation are dependable:

1. Make follow-back and relevant shared context easy to recognize using the existing relationship signals.
2. Keep a reply tied to its exact frame and return path. Do not add a second comments system or DMs to solve a navigation problem.
3. Give the newest few posts a satisfying home on a person's page; monthly chapters should not be required for an early sense of ownership.
4. Offer chapter cover/pick control or memory revisiting only where study participants show demand.
5. Keep shared-roll follow-up as the occasion-specific continuation, with clear opt-in invitations.

**Exit gate:** More eligible new contributors receive a response and return to interact again, without worsening notification opt-outs, capture reliability, or confusion about audiences. Improvements must persist beyond owner-led outreach.

## 6. Run the study already written

Use `docs/USABILITY_STUDY.md`, with two adjustments for the adopted center:

- Do not start every newcomer through a roll invitation. Include personal-invite, campaign/no-known-context, and roll-invite entry. Otherwise the study evaluates the occasion journey more than everyday sharing.
- Split the last task into finding an older memory and identifying/saving an eligible photo. A friend's chapter export is intentionally restricted; distinguish understanding that rule from failing to find a control.

Run the five sessions with consented test content and record wrong turns, task completion, expectation, and assistance. Prioritize tasks 1–4—find a friend, respond to an exact frame, capture/choose audience, and answer a reply—for the everyday loop. Keep roll participation and archive/export as separate tasks.

At this community size, use the study plus sequential rollout observation rather than claiming statistically decisive A/B results. Choose the two largest observed obstacles and fix those before broadening the redesign.

## 7. Measurement and decision rules

### Primary product outcome

**Weekly reciprocal participation:** distinct pairs who both interact with the other's photos during a rolling seven-day window, counting reactions/comments and deduplicating the pair. Define this across personal posts and shared-roll photos explicitly; report the two contexts separately before combining them.

This measures people connecting. It does not require every user to create every week, and should not become a visible score or a pressure mechanic.

### Supporting measures

| Question | Measure |
|---|---|
| Can newcomers find their people? | Successful known-person page open and first friend-photo interaction, by arrival type |
| Do contributors get a response? | First contribution answered within 24 hours; median response time among answered contributions; unanswered count separately |
| Does response create another visit? | Return and further interaction after first response, within seven days |
| Is the camera still excellent? | Capture-to-durable-save latency/failure and quick-capture task completion |
| Is the social UI trustworthy? | Follow-success-but-empty cases, notification destination failures, search errors, unexpected unread clearing |
| Are we creating noise? | Notification denial/mute/opt-out behavior alongside useful reply returns |
| Are costs sustainable? | New retained bytes, rendition coverage, actual downloaded bytes where available, and request volume |

Use mature cohorts for first-week outcomes: a signup from yesterday has not had seven days to return. Report sample sizes and owner-assisted versus organic activity. Do not call the existing 15/20 “came back another day” count day-seven retention.

Before setting numerical targets, fix A9 and retain a stable baseline across comparable cohorts/builds. At 70 recorded accounts, a single enthusiastic friend can move the result materially.

## 8. Keep scope disciplined

**Do now:** correctness at social transitions, coherent entry/publishing copy, known-person discovery, the existing usability study, and reliable measures of reciprocal use.

**Test next:** ordinary-return destination, selected-frame clarity, page first-post route, and natural conversation continuation.

**Later, when supported by demand:** recap personalization, richer occasion-host controls, optional supporter/event monetization, and the complete R2 migration.

Do not add DMs, public ranking, streak penalties, forced invitations, or another badge system to compensate for an unclear core journey. Do not reopen the declined Feed/Activity merge, rename work, or camera-look revisions in these batches.

The current saved storage figure is 4.29 GiB as calculated by the nightly query, not a fresh measurement and not evidence about bandwidth. Keep existing image quality and renditions while measuring cost. An eventual paid plan should fund valued extras and retained media without gating seeing a friend's reply or a shared reveal.

## 9. Implementation handoff

Recommended parallel work after approval to implement:

- **Backend:** A3 audience/notification consistency and A9 measurement semantics; ordinary-user authorization tests.
- **iOS state and reliability:** A1/A2 follow transitions, A4 Activity boundary, A5 per-capture safety.
- **iOS presentation:** A6–A8 destination/presentation ownership, then Batch 1's bounded copy and entry work.
- **Owner/product:** run the existing study, review arrival types, and choose the return-navigation experiment from observed behavior.

Keep acceptance checks attached to each task. Update the existing review ledger instead of copying all historical audit findings into a new undifferentiated backlog. Deployment verification, device verification, and observed usability should be recorded as separate evidence.

The next milestone is concrete: **someone opens FLIM to see a familiar person's day, responds without friction, shares a moment when they want to, and gets a reason to return.** Everything in these batches should make that sequence easier or more trustworthy.
