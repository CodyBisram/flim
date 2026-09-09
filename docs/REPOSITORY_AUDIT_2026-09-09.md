# FLIM repository audit

Date: September 9, 2026

**FLIM has a strong product foundation, but I would fix photo durability and authorization before widening the public rollout.** The biggest opportunities are protecting every captured photo, getting friend groups to their first shared reveal, and making repeat viewing inexpensive. Adding more features comes after those.

Three delegated audits covered native reliability, backend/storage/security, and product/UX. Their findings were cross-checked against the source and current infrastructure pricing. No application files were changed during the audit. This was a source audit, not a live penetration test or device performance benchmark. Production policies, billing, deployment settings, and current conversion rates remain unverified.

The findings below distinguish code defects from product recommendations and things that need production validation. Source links are relative to this document; line references describe the repository at audit time and may shift after changes.

## What is already working well

FLIM is substantially beyond a camera MVP. It has a distinctive image pipeline, shared rolls, sorting, social interactions, blocking/reporting, upload recovery, local image caching, monthly recaps, contact-sheet sharing, contextual permission prompts, and an analytics dashboard.

Some particularly good choices:

- Native capture and on-device processing avoid paying a server to process every photograph.
- Separate master, feed, and thumbnail renditions reduce download costs.
- Stable storage-path cache keys survive signed-URL changes.
- Account-change generations protect many asynchronous responses.
- Keyset feed pagination, batched metadata reads, and bounded image caching provide a sound performance foundation.
- Image encoding decisions have actual comparison tests behind them.

The code is generally thoughtful. The recurring weakness is that individual protections do not always compose into a safe end-to-end workflow.

## Highest-priority launch fixes

Treat the photo-loss and authorization findings as P1: address them before substantially increasing exposure.

### 1. An upload timeout can permanently destroy a photo

The sequence is:

1. The master uploads.
2. The database insert commits.
3. The response gets lost.
4. The client assumes the insert failed and deletes the master.
5. Recovery finds the database row and deletes the local recovery copy as “already uploaded.”

That leaves a photo record without its master or a recovery copy. This follows from the upload cleanup at line 544, confirmation query at line 1163, and recovery cleanup at line 1250 of [PhotoService.swift](../Flim/Services/PhotoService.swift).

**Fix direction:** treat a timeout as an unknown outcome. Retain the bytes until both the row and object are verified. Give each capture an explicit, durable upload state.

### 2. Shots waiting in the capture queue are still only in memory

A new capture waits for the previous processing/upload pipeline before reaching disk persistence. Several shots taken on a slow connection can therefore disappear if the process terminates. The actor-backed upload store does not protect captures that have not reached it yet. See [PhotoService.swift](../Flim/Services/PhotoService.swift), line 155.

There is also a narrower crash window between writing the pending JPEG and its JSON sidecar; recovery can prune that JPEG.

**Fix direction:** persist the capture, original shutter timestamp, film choice, and destination immediately. Process and upload from that durable queue. Expose three understandable states: “Saved on this device,” “Syncing,” and “Backed up.”

### 3. Photo and account deletion can leave broken live records

Photo deletion removes storage objects before deleting the database row. If the second operation fails, the UI can restore a photograph whose bytes are gone. Account deletion follows the same destructive-first pattern and swallows storage errors; a failed removal of a full 1,000-object page can repeatedly fetch the same page. See [PhotoService.swift](../Flim/Services/PhotoService.swift), line 1354, and [AuthService.swift](../Flim/Services/AuthService.swift), line 699.

**Fix direction:** record deletion intent on the server, hide the item, retain its object inventory, and perform retryable cleanup. A database transaction cannot make external object deletion atomic; a durable cleanup job can make it recoverable.

### 4. Direct API calls can bypass roll invitation and membership rules

The membership INSERT policy checks that someone is inserting themselves, but does not require going through the invite RPC. An authenticated caller who knows a roll UUID can bypass the intended join path. The normal join RPC also counts members without locking the roll, allowing concurrent joins to exceed the cap. See [schema.sql](../supabase/schema.sql), line 639.

Photo INSERT does not require roll membership, and photo UPDATE primarily checks ownership. That permits state changes the UI would never offer, including moving photos between rolls and altering moderation/development fields. See [schema.sql](../supabase/schema.sql), line 683.

**Fix direction:** enforce membership, limits, timing, and immutable fields at the database boundary. Restrict direct writes and use narrowly scoped, locked RPCs for state transitions.

### 5. Client-controlled image paths can grant access to unrelated images

Post creation validates the referenced photo ID, but does not bind the supplied storage paths to that photo. Storage authorization then trusts those paths. A caller who knows another object’s path can attach it to an otherwise legitimate post. Avatar and cover paths have a similar trust problem.

See post write policies at line 1297 and storage authorization at line 2143 of [schema.sql](../supabase/schema.sql).

**Fix direction:** derive canonical image paths on the server from authorized photo IDs. Validate ownership of avatar/cover uploads. A difficult-to-guess path is not an authorization check.

### 6. Comments and reactions do not consistently inherit the parent post’s visibility

The final read policies for comments, reactions, tags, and comment likes check certain block relationships but do not require that the parent post be readable. Direct queries can expose discussion metadata associated with hidden or otherwise restricted posts. See [schema.sql](../supabase/schema.sql), line 2070.

**Fix direction:** require a visible parent, then apply the participant-specific restrictions.

### 7. The public-facing privacy promise exceeds what ordinary posts enforce

The website describes sharing between friends, but ordinary posts are readable by authenticated, unblocked users, subject to the special covered-post restriction. Following is not required by the post policy. See [website copy](../web/index.html), line 206, and [schema.sql](../supabase/schema.sql), line 2061.

This becomes more consequential when “authenticated users” includes strangers.

**Recommendation:** choose the audience contract explicitly. For a friends-first product, I favor approved relationships/private accounts and an obvious audience label when publishing. If posts are intentionally visible throughout FLIM, the interface and marketing should say so.

### 8. Privileged scheduled functions need explicit caller authorization

Several push handlers perform service-role work without checking who invoked them. Gateway JWT verification, even when enabled, is not equivalent to authorizing only the scheduler. Repeated calls can trigger scans and overlapping sends. The storage sweeper also exposes its privileged candidate inventory through its dry-run response without its own owner check. See [develop handler](../supabase/functions/send-develop-push/index.ts), line 240, and [sweep response](../supabase/functions/sweep-orphaned-storage/index.ts), line 163.

**Fix direction:** authorize every privileged handler, including read-only/dry-run branches, with a narrowly scoped scheduler or administrator credential.

### Deployment verification: invite-only admission

**Verify that invite-only admission is enforced in hosted Auth.** The repository contains a client allowlist check, but the audit did not find a server Auth hook/configuration proving uninvited users cannot bypass it. This is a deployment verification item, not a claim that production has been bypassed.

## Caching, performance, and concurrency

| Finding | User or cost impact | Recommended change |
|---|---|---|
| Rendition upload/repair uses deterministic paths without reconciling existing objects | A successful object upload followed by a lost response or failed row patch can leave repair stuck on duplicate-object errors; the app keeps downloading masters | Make rendition creation and row linking idempotent; verify existing objects |
| Darkroom assigns cached signed URLs a new one-hour lifetime | An already-old URL can expire while the view still considers it fresh; retry reuses it | Return actual expiry with the URL and refresh once on an authorization failure |
| Signed-URL persistence swallows cancellation | The intended debounce can write the entire cache repeatedly during a signing batch | Exit on cancellation before persisting |
| Concurrent image loads are not coalesced | Prefetch and visible views can request the same bytes simultaneously | Share one in-flight download per immutable asset |
| Disk cache trims when the main view appears | The 200 MB target can be exceeded during long sessions | Add periodic/write-triggered trimming with a global budget |
| Reaction writes can overlap | A failed earlier request can roll back a later successful reaction | Serialize or version mutations; undo only the failed change |
| Refresh can lose to ongoing pagination | Pull-to-refresh returns without refreshing while an older page completes | Give each feed query a generation and queue or supersede refreshes |
| Profile history has no explicit pagination | Growing responses or silent truncation at the configured server row limit | Cursor pagination and separate aggregate counts |

Evidence:

- Renditions: [PhotoService.swift](../Flim/Services/PhotoService.swift), line 789.
- URL expiry: [DarkroomViewModel.swift](../Flim/Views/Darkroom/DarkroomViewModel.swift), line 248.
- Persistence: [SignedURLStore.swift](../Flim/Services/SignedURLStore.swift), line 102.
- Image loading/cache: [PhotoGridCell.swift](../Flim/Views/Darkroom/PhotoGridCell.swift), lines 288 and 429.
- Reaction writes: [FeedService.swift](../Flim/Services/FeedService.swift), line 1209.
- Feed refresh: [FeedService.swift](../Flim/Services/FeedService.swift), line 807.
- Profile history: [FeedService.swift](../Flim/Services/FeedService.swift), line 1520.

Additional correctness issues worth fixing:

- **Offline photos receive upload-time history.** `InsertPhoto` omits `taken_at`, so the database default can place a retried photograph in the wrong day or month. Preserve shutter time separately from ingestion time. [Photo.swift](../Flim/Models/Photo.swift), line 112.
- **Contact-sheet export silently skips failed images.** It can successfully share an incomplete recap without explaining the omissions. Retry missing frames or explicitly identify partial output. [ChapterRecapViewModel.swift](../Flim/Views/Profile/ChapterRecapViewModel.swift), line 298.
- **Push delivery can both duplicate and lose notifications.** Jobs read unsent work, send, then mark it complete without an atomic claim; transient failures can also be marked finished. Use leased jobs, recipient-level outcomes, backoff, and bounded concurrency. [Develop push](../supabase/functions/send-develop-push/index.ts), line 248.
- **The invite limiter can throttle the whole launch.** Preview and redemption share a global 30-per-hour counter. Waitlist requests have a global 60-per-hour limit and then return success without saving the request. Use layered per-source limits and honest retry responses. [schema.sql](../supabase/schema.sql), lines 6100 and 4193.
- **Cleanup can stop indefinitely above its safety cap.** The sweeper aborts above 500 candidates and returns HTTP 200. Keep the safety protection, but alert and provide resumable recovery. [Sweep cap](../supabase/functions/sweep-orphaned-storage/index.ts), line 146.
- **Account cleanup is incomplete locally.** Image/signature caches are shared by asset path, and some account-specific stores remain after sign-out/deletion. Define account isolation and purge behavior, while protecting unsynced captures from accidental loss.
- **Public moderation needs stronger controls.** Two reporters can auto-hide photos, report eligibility is weak, and writable moderation fields undermine enforcement. Add server-owned moderation state, abuse limits, and a review workflow.

## Image quality and storage efficiency

**Preserve the current encoding policy until new measurements justify changing it.**

The actual pipeline uses:

| Rendition | Long edge | JPEG quality |
|---|---:|---:|
| Stored master | 2,048 px | 0.85 |
| Feed | 1,400 px | 0.79 |
| Thumbnail | 500 px | 0.80 |

The [encoding implementation](../Flim/Services/InstantFilmProcessor.swift), line 49, documents comparisons where HEIC reduced the desired grain, and higher-quality HEIC lost the size advantage. Feed JPEG quality is already close to its tested floor.

That changes the optimization priorities:

1. Ensure every photo has its intended renditions.
2. Avoid duplicate downloads and unnecessary master downloads.
3. Generate renditions from the same graded pixels, preserving the existing single-generation path.
4. Reconcile and remove genuinely orphaned objects.
5. Only then revisit codecs or compression, using representative photos and device comparisons.

The 2,048-pixel master also matters commercially: do not promise original sensor resolution or large print quality without validating those outputs.

For storage reduction, offer **opt-in cleanup of unwanted/burst shots**, with a preview and verified export option. Do not automatically delete old masters merely because their feed renditions still exist. Those masters are the user’s best stored copy.

## R2 migration assessment

**R2 is a good direction for growth, but the current migration is incomplete.**

The repository has a delivery Worker, an authorization RPC, and a backfill script. It does not yet implement the full production media lifecycle.

Important gaps:

- The Worker caches **permission decisions**, not image bytes. Successful network requests still call R2.
- Positive permission decisions remain cached for ten minutes after an access change.
- Its authorization and path handling do not cover every avatar/cover case supported by current Storage policies.
- The backfill covers photo renditions, not every independently stored profile/cover asset.
- Migration stamping checks existence rather than fully verifying size/checksum.
- Continuous handling of new uploads, repairs, and deletions across both stores is missing.
- The native image loader needs authenticated requests, token refresh, and controlled fallback.
- The handwritten JWT verifier needs compatibility with the project’s actual signing keys and controlled malformed-request handling.

See [Worker](../cloudflare/worker/worker.js), line 26, [authorization RPC](../supabase/migrations/2026-08-21_r2_can_view_photo.sql), line 11, and [backfill](../scripts/r2_backfill.py), line 79.

Recommended architecture:

- **Supabase:** authentication, relationships, photo metadata, permissions, billing entitlements.
- **R2:** private immutable image objects.
- **Worker:** authorize access, then serve cached bytes or read R2.
- **Durable media jobs:** track upload completion, rendition repair, migration verification, and deletion.
- **Device:** durable capture queue plus bounded decoded/raw image caches.

Authorization must remain ahead of serving cached bytes. Define the acceptable revocation delay explicitly. Already-downloaded photos cannot be recalled.

Also, do not assume a one-hour signed URL means access always ends in one hour: Supabase documents that signed-token expiry and CDN response cache duration are independent. [Supabase Smart CDN documentation](https://supabase.com/docs/guides/storage/cdn/smart-cdn)

## Infrastructure economics

**R2 will not eliminate the $25 Supabase subscription while you retain its paid database/Auth service.**

Published pricing checked for this audit:

- Supabase Pro includes 100 GB storage, plus separate 250 GB cached and 250 GB uncached egress allowances. Overage rates are $0.0213/GB-month storage, $0.03/GB cached egress, and $0.09/GB uncached egress. [Supabase pricing](https://supabase.com/pricing)
- R2 Standard storage is $0.015/GB-month with free egress. It includes 10 GB-month storage, one million Class A operations, and ten million Class B operations monthly; excess operations are billed. [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- Workers Paid starts at $5/month, with request and CPU allowances/overages. [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)

The following is an **illustrative model, not a projection of the current bill**. Assume each active user has 180 retained photos averaging 1.5 MB across renditions, adds 30 monthly, and causes 500 network image fetches averaging 375 KB monthly after device-cache savings.

| Active users | Stored images | Monthly image delivery | Supabase, 80% CDN hits | Supabase, all uncached | Supabase + R2 + $5 Worker |
|---:|---:|---:|---:|---:|---:|
| 100 | 27 GB | 18.75 GB | $25.00 | $25.00 | $30.26 |
| 1,000 | 270 GB | 187.5 GB | $28.62 | $28.62 | $33.90 |
| 10,000 | 2,700 GB | 1,875 GB | $129.13 | $226.63 | $70.35 |

The R2 column assumes completed migration, no duplicate Supabase image storage, and usage within included operation/CPU allowances. These figures exclude additional database compute, non-image traffic, email, monitoring, backups, and other services. **Inactive users’ retained libraries still cost money** and must be added to a real model.

At small scale, migration can increase the bill. At heavier viewing volume, it becomes attractive. Base timing on measured bytes, cache hits, storage growth, and operational readiness—not user count alone.

For a safe migration: repair lifecycle bugs first, inventory all assets, verify copies, enable delivery for a small cohort, compare failure/latency/cost metrics, then expand. Retire duplicate storage only after the rollback window and reconciliation checks.

## Onboarding, retention, and UX

**The first shared experience is the highest-value opportunity.**

Some old documentation describes problems already addressed: the three-card onboarding has been replaced, usernames are prefilled, inviter previews exist, and chapter contact-sheet sharing is implemented. Historical conversion numbers should not be treated as measurements of the September redesign.

Prioritized product work:

| Opportunity | Concrete change | Success measure |
|---|---|---|
| One invitation journey | A roll invite deliberately handles app admission and eventual roll membership | Invite opened → joined → contributed |
| Faster first value | Test prefilled handle + Continue; move optional name/color choices later | First kept shot within five minutes |
| Clear capture confidence | Show local-save and backup status; make retry errors actionable | Capture loss, queue age, successful recovery |
| Repeat groups | “Start another with this group” after a successful reveal | Second shared roll within 30 days |
| Better event setup | Configure reveal timing during creation and explain it to guests | Multi-person contribution and reveal viewing |
| Better recaps | Replace selected frames/covers, exclude unwanted shots, improve export completeness | Completed exports and repeat recap use |
| Notification control | Separate reveal/social/digest preferences and local quiet hours | Useful opens versus opt-outs |
| Trustworthy archive | Full-library export and clear storage/retention information | Export completion and support issues |

The existing two-invite journey is particularly costly: a newcomer opening a roll link can be told to ask for a separate app invite. That is extra coordination at exactly the moment someone wants to join their friends. [Roll landing page](../web/join.html), line 58.

For UI/UX, preserve the visual identity and focus on clarity:

- Always make **Personal versus named roll** and **publishing audience** unmistakable.
- Separate “developing” from “not uploaded yet.”
- Show useful explanations for unavailable images and incomplete exports.
- Improve large-text auth layouts and keyboard reachability.
- Label color swatches, expose selection state, and enlarge their touch targets.
- Test VoiceOver, Reduce Motion, and the largest text sizes across capture, sorting, reveal, and deletion.

Accessibility support already exists, but the app globally caps Dynamic Type at `.accessibility2`; raising that requires layout work. [FlimFont.swift](../Flim/Views/Components/FlimFont.swift), line 89.

Strengthen measurement as well. Activation milestones are fire-and-forget with no retry, so important first-occurrence events can be missing or recorded late. Repeated usage tracking already exists; the missing piece is reliable event delivery and experiment attribution. [Activation.swift](../Flim/Services/Activation.swift), line 63.

The primary retention metric should be **groups with at least two contributors that return for another roll**, alongside repeat personal capture. App opens alone can reward notification noise.

## Monetization

**Test an event package first and an annual plan second.** These prices are experiment hypotheses, not established willingness to pay.

| Offer | Initial price hypothesis | What people would buy |
|---|---:|---|
| Event/host package | $9.99–$19.99 per event | One organizer pays; guests participate free; enhanced event setup, presentation, exports, and a defined archive allowance |
| Annual FLIM Plus | $19.99–$29.99/year | Additional archive capacity, advanced recap customization, premium export formats |
| Supporter purchase | $4.99–$9.99 | An optional way for existing fans to support development |
| Physical prints/contact sheets | Validate manually first | A tangible keepsake from a completed roll or chapter |

The event package fits birthdays, trips, and weddings because one person has a reason to organize and pay. Avoid requiring every guest to subscribe. Existing basic roll functionality should remain useful; charge for a more valuable hosted experience.

For an annual plan, keep the storage allowance explicit. Avoid lifetime unlimited storage: revenue arrives once while the obligation grows indefinitely. Define downgrade behavior in advance and give people time and tools to export; do not surprise them by deleting memories.

Preserve free access to the core camera, the signature look, ordinary participation, and basic export. Intrusive ads and paying to see a reveal would weaken the experience that makes the app worth sharing.

Using a 15% commission assumption, a $19.99 annual purchase yields approximately **$16.99/year before taxes, refunds, and other costs**, or $1.42/month averaged. Around **18 annual subscribers cover a $25/month infrastructure floor**; around 22 cover $30. That covers infrastructure, not development/support or growing usage. Apple’s reduced rate requires qualification and enrollment in its Small Business Program. [Apple program details](https://developer.apple.com/app-store/small-business-program/)

There is currently no StoreKit gating. Paid digital features require purchase restoration, verified entitlements, refund/revocation handling, and clear allowance enforcement—not just a paywall. Use StoreKit as the straightforward starting point; evaluate storefront-specific alternatives separately. Physical goods use a different payment model. [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Recommended sequence and validation

| Stage | Scope | Exit condition |
|---|---|---|
| 1. Protect trust | Capture durability, ambiguous upload outcomes, deletion workflow, authorization policies, privileged endpoint checks, invite limits | Fault-injection and multi-account authorization checks pass |
| 2. Make delivery dependable | Rendition reconciliation, URL expiry, request coalescing, pagination/reaction races, push retries, cache isolation | Measured recovery, latency, memory, and delivery behavior meets agreed targets |
| 3. Improve activation | Unified invites, clear audiences/status, accessibility, repeat-group flow, reliable funnel events | New cohorts reach first contribution and repeat usage more reliably |
| 4. Scale and monetize | Complete R2 lifecycle when justified; test one paid event offer | Verified storage migration and actual paid demand |

The repository has substantial tests, but the most important missing coverage is **failure between systems**: server commit followed by response loss, termination during capture persistence, partial deletion, concurrent reactions, refresh during pagination, and authorization through direct API calls.

Release checks should also compare deployed policies/cron/Auth settings with the repository, exercise an empty-database setup, and cover the actual minimum supported iOS version. The README says iOS 26, while [project.yml](../project.yml), line 19, targets iOS 18, which illustrates why the older operational notes need reconciliation.

The strongest recommendation is to spend the next engineering effort on **never losing a shot and making the first shared roll effortless**. Those improvements protect the product’s value, reduce support costs, and create a much stronger foundation for charging for events and keepsakes.
