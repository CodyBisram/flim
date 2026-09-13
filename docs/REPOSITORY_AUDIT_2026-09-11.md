# FLIM repository audit — September 11, 2026

## Context and scope

FLIM 1.5.2 shipped today on build 365, with a public invite campaign and 60+ users, according to the owner and release notes. This is a second full, read-only audit following `REPOSITORY_AUDIT_2026-09-09.md`. Three agents independently reviewed backend/storage, client reliability, and product/UX; the primary reviewer cross-checked findings and assembled this report.

Reviewed HEAD: `83df50b5ee72e777499a1a54e1e8521a185eb596`. Reviewed changes from `fb90510` through HEAD: 81 files, approximately 4,502 insertions and 248 deletions, plus relevant unchanged surrounding code. Scope includes Swift services and views, SQL permissions and migrations, scheduled functions, storage/caching, R2 scaffolding, onboarding, exports, release configuration, and tests.

**Release distinction:** HEAD includes the next 1.5.3 train. `docs/PENDING.md:346–390` explicitly places durable raw captures, unified roll-code admission, deletion changes, and follow-up rolls there. Do not assume all reviewed Swift changes are in App Store build 365. Conversely, database changes described as already applied affect older installed clients immediately. The exact build-365 source artifact and live database grants were not independently retrieved in this audit.

**Evidence limits:** Findings below come from source and migration analysis, not production exploitation. Deployment claims in PENDING are recorded evidence from prior work, not a new live verification. No production requests, account changes, migrations, code fixes, or test executions were performed. This Markdown report is the only file added by this audit.

## Overall assessment

The application has improved substantially. The trust batch closes real boundary holes; image delivery now has better retry and caching behavior; onboarding preserves more context; and the group follow-up concept directly supports repeat use.

However, several items marked done are only partly closed. The highest-priority regression is a database/client mismatch: the write-boundary migration permits only `is_sorted` updates, while clients still update rendition paths, burst grouping, and development state. That can break performance and increase storage waste immediately if the migration is live. Single-photo deletion still has its original data-loss ordering. The new raw queue also needs account-switch protection.

At 60+ users, broad architectural replacement is not the immediate need. Prioritize photo integrity, permissions compatible with installed clients, consistent sharing promises, and measurement. Keep the current image look until measured evidence supports changing it.

Priority meanings: **P1** = address promptly because of data integrity, privacy, or a core production regression; **P2** = concrete reliability/product issue to schedule; **P3** = lower-frequency edge case or planned improvement. These are priorities, not claims that exploitation or loss has occurred.

## Findings requiring action

### 1. P1 — The write-boundary migration rejects legitimate client writes

**Evidence:** `supabase/migrations/2026-09-11_write_boundary.sql:18–19`; `Flim/Services/PhotoService.swift:722, 931, 1071–1075, 2270`.

The migration revokes photo UPDATE and grants only `UPDATE (is_sorted)`. The client still updates `thumb_path`, `feed_path`, `burst_group`, and `is_developed`. The migration comment stating that the app changes only one column is incorrect.

New captures insert their master with null rendition paths, upload smaller images, then patch the row. Under these grants that patch fails. The main path swallows the error; repair also swallows it and updates memory as though it worked. After refetch/relaunch, the row still lacks renditions. This means repeated master downloads, ineffective repair, and potentially unreferenced smaller objects. Burst grouping and development bookkeeping also diverge from local state.

**Recommendation:** Define narrowly authorized server operations for legitimate writes, validating ownership, immutable fields, and paths. Provide backward compatibility for installed clients before removing direct writes they require. Do not restore unrestricted UPDATE as the permanent fix.

**Acceptance:** With an ordinary user JWT and the production-equivalent grants, capture and repair must persist all intended rendition paths; burst grouping must persist; disallowed moderation/path reassignment must still fail. Repeat against build 365, not only the upcoming client.

### 2. P1 — Canonical post paths still trust an unvalidated photo row

**Evidence:** `supabase/migrations/2026-09-11_write_boundary.sql:7–12, 42–58`; `supabase/schema.sql:2143–2153, 6541–6546`.

Copying post paths from the photo is a useful improvement, but photo INSERT still does not require its paths to belong to the inserting user. A signed-in user who knows another object's path can create an owned photo row referring to it, then publish a post whose trigger copies those paths. The shared-post storage policy trusts that reference. Knowing a path is a prerequisite; this is not arbitrary enumeration of unknown objects.

**Recommendation:** Validate master, thumbnail, and feed paths at the first trusted write boundary, including photo INSERT. Validate which insert-time fields the client may choose; UPDATE restrictions alone do not make a table server-owned. Review all reference-based storage authorization together.

**Acceptance:** Creating a photo with any foreign object path must fail, and publishing cannot make a previously unreadable object readable through an attacker-owned reference.

### 3. P1 — Single-photo deletion still removes bytes before the row

**Evidence:** `Flim/Services/PhotoService.swift:1448–1469`. Reachable from `SortDeckView.swift:438`, `PhotoPagerView.swift:1750,1766`, and `RollDetailView.swift:989`.

The batch deletion function was fixed; `deletePhoto` was not. If Storage removal succeeds and the subsequent row deletion fails, the function reports failure and the UI can restore a photo whose files are already gone.

**Recommendation:** Apply one consistent deletion protocol to single and batch actions. Record deletion intent before removing bytes and reconcile ambiguous responses. Reuse the implementation rather than maintaining separate ordering rules.

**Acceptance:** Interrupt the connection between each deletion step. The result must be either an intact retryable photo or a completed deletion with cleanup pending, never a restored row pointing at deleted files.

### 4. P1 — Account deletion ignores the prerequisite failure and can loop indefinitely

**Evidence:** `Flim/Services/AuthService.swift:752–764`; related debug reset in `PhotoService.swift:1518–1529`.

The account flow now attempts photo-row deletion first, but uses `try?` and proceeds to delete objects even if that prerequisite failed. The original destructive ordering problem therefore survives on the error path. Separately, if a folder returns 1,000 objects and removal repeatedly fails, the loop lists the same objects forever and never reaches `delete_account`.

**Recommendation:** Use a durable account-deletion job or explicitly confirmed prerequisite with bounded cleanup retries. Include profile-image references and account completion, not only photo rows. Surface failure and preserve a retryable operation.

**Acceptance:** Exercise row-delete failure, object-delete failure, final account-RPC failure, and a folder with more than 1,000 objects. None may hang or claim completion incorrectly.

### 5. P1 — Queued captures can resume under the next account's generation

**Evidence:** `PhotoService.swift:134–144, 174–205, 335, 743–776, 788–802`.

Account reset clears visible arrays but does not invalidate the queued pipeline. Raw restore awaits disk loading and then enqueues work without rechecking the account. `captureAndUpload` captures the account epoch when it eventually starts, rather than retaining the epoch that owned the shutter action. A shot queued for account A can start after switching to B, adopt B's epoch, fail Storage authorization, and append A's image data to B's shared failed-upload state.

**Recommendation:** Bind each job to its original account and generation before the first asynchronous boundary. Check that identity before processing, every network operation, and UI mutation. Preserve A's files for A, while preventing A's jobs from becoming B's visible work.

**Acceptance:** Queue multiple offline shots on A, sign out, sign into B, then restore connectivity. B must never see or retry A's shots; signing back into A must recover them.

### 6. P2 — The raw and processed capture stores do not form one recovery state machine

**Evidence:** `PhotoService.swift:389–392, 774–802`; `Flim/Services/CaptureQueueStore.swift:48–59, 93–105`.

Both stores can contain the same photo between processed persistence and cleanup. Raw restore only enqueues work and returns, so the subsequent failed-upload restore can also encounter the same shot. Stable IDs help avoid duplicate database rows, but do not prevent concurrent processing/retries or misleading retry UI.

The new store also writes JPEG and JSON separately. A crash between them leaves recoverable image bytes without metadata; pruning deletes those bytes later. The initial save result is ignored at `PhotoService.swift:181`, so the UI cannot immediately distinguish a durable queued shot from one held only in memory.

**Recommendation:** Define one authoritative per-photo state and deduplicate raw/processed recovery before scheduling. Use an atomic entry/manifest strategy or a recovery path for orphan bytes. Report failed local persistence honestly.

**Acceptance:** Crash after raw bytes, after metadata, after processed persistence, after remote object upload, and after row commit. Each photo must recover once or be explicitly recoverable; no silent deletion of its only local bytes.

### 7. P2 — Pull-to-refresh can still be overwritten during page hydration

**Evidence:** `Flim/Services/FeedService.swift:926, 963–993`.

The request generation is checked after fetching posts, but the function then awaits profiles/reactions/comments/tags. Its final mutation guard checks only account epoch. A refresh during those awaits changes feed generation without changing account epoch, allowing the old request to replace or append to the refreshed feed.

**Recommendation:** Check generation after the final await and before every request-owned state mutation, including errors/loading state.

**Acceptance:** Delay reaction/profile hydration, refresh, let the new feed finish, then release the old request. The new feed and pagination state must remain unchanged.

### 8. P2 — Owner-only export is not enforced across export surfaces

**Evidence:** `Flim/Views/Profile/ChapterRecapView.swift:292–311`, `ChapterRecapViewModel.swift:307–334`; `Flim/Views/Rolls/RollRevealViewModel.swift:392–406`.

The photo pager now restricts export, but a chapter contact sheet uses the entire deck without an ownership filter, including chapters opened from another user's profile. Roll reveal's Save all also exports every deck member. These are ordinary in-app paths around the new own-photographs-only product rule and updated privacy copy.

**Recommendation:** Centralize the export eligibility rule and use it for individual images, roll exports, chapters, and future video exports. Label the resulting selection accurately. This concerns FLIM's own export features; it is not a promise to prevent screenshots.

**Acceptance:** Use a mixed-author roll and another person's chapter. Only eligible images may be included in any app-generated export.

### 9. P2 — Push delivery is still tracked too broadly, and leases are not exclusive after expiry

**Evidence:** `supabase/functions/send-develop-push/index.ts:249, 334–356`; `send-social-push/index.ts:728, 871, 1217`; `supabase/migrations/2026-09-09_push_run_locks.sql:13–37`.

Develop pushes now correctly leave a roll unsent when every device fails. Partial success still marks the entire batch sent, permanently losing transient failures for the remaining recipients. Social delivery paths also mark source rows sent without a durable per-recipient success record.

The lease lasts 240 seconds and release identifies only the sender name. If run A outlives its lease, B can acquire it; A's finally block can then release B's lock. There is no ownership token or renewal. Ordinary short runs are protected, but the claim that overlap is impossible is too strong.

**Recommendation:** Persist per-event/per-recipient delivery with terminal versus retryable outcomes. Give leases an ownership token, conditional release, and renewal or a bounded execution window. Preserve successful deliveries while retrying only failures.

### 10. P2 — Activation retry can lose new events or attribute them to another account

**Evidence:** `Flim/Services/Activation.swift:71–108`.

`flushPending` takes a local snapshot, awaits a send, then writes its shortened snapshot back. An event enqueued during that await can be overwritten. The queue is a global list of event names, without account identity, so events from A can later be flushed under B. This weakens the conversion/retention data needed for the financial model.

**Recommendation:** Serialize queue changes, acknowledge individual persisted entries, and associate authenticated events with their owning account. Define how pre-authentication milestones are attached on sign-up.

### 11. P2 — A roll creator can bypass the reveal-time operation with direct UPDATE

**Evidence:** `supabase/schema.sql:617–620` and the restricted `set_roll_reveal_at` operation.

The roll UPDATE policy checks creator identity, but does not restrict columns or force reveal changes through the bounded function. A creator using the API can choose values outside the UI/RPC's intended timing rules. This remains open after the photo/post write-boundary batch.

**Recommendation:** Enumerate valid roll mutations and enforce their invariants in the database, while preserving compatibility with supported clients.

### 12. P2 — Follow-up rolls need retry identity, limits, and recoverable UI states

**Evidence:** `supabase/migrations/2026-09-12_follow_up_rolls.sql:44–94`; `Flim/Services/RollService.swift:115–139`; `Flim/Views/Rolls/RollsView.swift:571–580`.

The new RPC creates a fresh roll and invitations on every call, with no request identity. A committed request whose response is lost can produce another roll on retry. Repeated requests can also fan out invitations and pushes without a per-caller bound. On the client, a failed invitation fetch becomes an empty list, failed dismissal is swallowed, and failed Join gives only a haptic.

**Recommendation:** Add idempotent creation and proportionate server-side limits. Retain previous invites on fetch failure; roll back failed dismissal; show an actionable Join error and per-card progress. This is upcoming-client work, with backend relevance if already deployed.

### 13. P2 — The sweeper can stop cleaning forever while returning HTTP 200

**Evidence:** `supabase/functions/sweep-orphaned-storage/index.ts:69–73, 152–166`.

More than 500 candidates aborts the entire sweep with a 200 response. Once crossed, subsequent runs do not reduce the backlog. With deletion now deliberately leaving best-effort cleanup to the sweeper, this is an active dependency, not just a distant scale concern. The rendition-linking regression can also increase orphan candidates.

**Recommendation:** Keep a safety stop, but make blocked cleanup an alertable failure with an explicit recovery path. Support inspected, bounded batches and monitor oldest orphan age and backlog bytes. Do not simply raise the cap or remove safeguards.

### 14. P2 — The schema file is not safely rerunnable at the current state

**Evidence:** `supabase/schema.sql:5476–5477, 6209–6210, 6649–6651`.

An earlier `CREATE OR REPLACE invite_preview` returns three columns, while the final version returns four. Reapplying the whole file to the final database reaches the incompatible return-type replacement before the later DROP. The creator-membership policy also creates its new name without first dropping that name on a rerun.

**Recommendation:** Establish a tested clean-bootstrap path and an incremental migration path. Avoid historical redefinitions in a supposedly current schema snapshot. Run bootstrap and migration verification in an isolated database, including a second application where rerunnability is promised.

### 15. P2 — Public-launch copy still overstates the sharing boundary

**Evidence:** `web/index.html:206–210`; updated `web/privacy.html` and the authenticated-post read policy.

The privacy page now correctly says posts can be seen by any member. The homepage still says “only ever your friends” and that sharing stays between the selected people. A followers-only home feed is not the same as followers-only access to posts.

**Recommendation:** Align homepage, onboarding, and posting copy with the current audience. The owner deliberately deferred changing post visibility; this finding does not reopen that decision. A publicly available invite code makes clear audience language more important.

### 16. P3 — Follow-up name generation can crash or produce an invalid suggestion

**Evidence:** `Flim/Models/Roll.swift:115–121`; follow-up SQL's 60-character name limit.

`n + 1` traps when a valid roll name ends with `, day 9223372036854775807` on a 64-bit device. Normal long names also become longer than the server limit when the suffix is added.

**Recommendation:** Use checked arithmetic and a length-safe fallback; validate the proposed name before submission. Cover the maximum integer and a 60-character parent name.

### 17. P2 — Queued reactions still undo later intent for the same emoji

**Evidence:** `Flim/Services/FeedService.swift:1230–1272`.

Network writes are serialized, but optimistic taps happen immediately. Start with no heart; tap add, remove, add; let the first add fail and the following delete/add succeed. The first failure removes the heart representing the third tap. Later successes do not restore it, so the server has a heart while the local screen does not. Queued reaction tasks also lack an account-generation guard.

**Recommendation:** Track mutation revisions per account/post/emoji. Roll back only if the failed operation still owns the displayed intent; otherwise reconcile the final desired state. Include this exact three-tap failure sequence in verification.

### 18. P2 — Image Retry can reuse the same rejected signed URL

**Evidence:** `Flim/Views/Darkroom/PhotoGridCell.swift:374–440, 459–477`.

HTTP 401/403 invalidates the shared SignedURLStore, which is useful, but the mounted CachedImage still holds its supplied URL. Its retry invokes the same load using that URL. Invalidating the store does not replace a view-local URL or itself request a new signature. The image can keep failing until its parent refreshes and signs again.

**Recommendation:** Let one bounded retry resolve a fresh URL by storage path and update the presentation source. Test a mounted cell whose URL expires while the screen remains open, without pulling to refresh.

### 19. P2 — Public invite traffic can exhaust shared limits, and waitlist success can be false

**Evidence:** `supabase/migrations/2026-09-09_invite_rate_layers.sql`; `supabase/schema.sql:4191–4203`.

The improved limits still share 40 previews/hour per code and 300 global operations/hour. A publicly posted cohort code concentrates legitimate newcomers on that one preview key, while an anonymous caller can consume the same allowance. Separately, the waitlist returns TRUE after its 60/hour ceiling without inserting the request.

**Recommendation:** Separate campaign traffic from per-source abuse controls and return an honest retriable result when a request is not saved. Track preview throttling separately from successful redemption. Do not present a 300-operation ceiling as capacity for 300 completed registrations.

## Earlier fixes: what is actually closed

| Area | Source-review conclusion |
|---|---|
| Invite-only Auth admission | Allowlist enforcement moved to the Auth boundary; meaningful improvement. |
| Lost upload response | Client checks for the existing row before cleanup; original unconditional-delete problem addressed. |
| Shutter timestamp | Preserved through capture/retry payloads; improved further in upcoming raw queue. |
| Post child visibility | Readable-parent checks added for comments/reactions/tags/likes. |
| Roll membership | RPC locks the roll for cap checks; direct joins restricted to creator. |
| Scheduled functions | Scheduler secret checked before privileged work. Sweeper dry-run is now protected too. |
| Invite limits | Layered email/code/global controls replace the old single low global counter. Still not a full public abuse defense. |
| Reaction writes | Per-post serialization and narrower rollback improve different-emoji races; same-emoji intent still needs protection. |
| Image downloads | In-flight coalescing added for the same asset and requested size; different sizes can still download together. |
| Signed URLs | Real stored expiry and refusal invalidation added; mounted-image retry does not itself re-sign. |
| Rendition uploads | Upsert makes object writes repeatable; linking is currently broken by finding 1. |
| Disk cache | Trims as writes accumulate, not only at launch. |
| Contact sheet completeness | Retries and missing-frame count added; ownership remains inconsistent. |
| Activation retry | Persistence added, but concurrency/account association remain incomplete. |
| Deletion | Batch ordering fixed; single and account paths remain unsafe. |
| Raw capture durability | Important upcoming improvement; recovery and account ownership need another pass. |
| Unified invite journey | Built for 1.5.3; roll link context preserved through sign-up. |
| Repeat-group loop | Built for 1.5.3 with opt-in invitations instead of automatic membership. |
| Privacy/support documentation | Much more accurate; homepage still needs alignment. |

## Performance, caching, and quality

1. **Fix rendition persistence first.** It has the clearest connection to download volume, orphan storage, and time to first image. Measure null rendition paths among recent captures before changing JPEG settings.
2. **Keep the current master/feed/thumbnail hierarchy.** The approximately 2048px master, 1400px feed image, and 500px thumbnail already separate quality needs. Preserve the approved grain/look; past codec experiments are not evidence that another format will preserve it.
3. **Measure actual bytes and fallback rates.** Record master/feed/thumb download counts and bytes, local hit rate, signing failures, download latency, and master fallback frequency by screen. App opens multiplied by a constant is not measured egress.
4. **Profile pagination is still deferred:** `FeedService.swift:1557–1563` fetches the entire user-post result in one request. Heavy individual users can encounter slow loads or API row limits before total user count looks large. Keyset pagination is the next bounded improvement when needed.
5. **Account cache isolation remains open.** Account-specific snapshots help, but shared image/signed-URL caches need a documented account-switch and revocation policy. Treat cached media, queued media, and server authorization as separate concerns.
6. **Bound restoration memory.** `CaptureQueueStore.load` loads every raw JPEG into memory and queued closures retain their bytes. A large offline backlog can turn recovery into a memory spike. Prefer incremental reads and bounded processing once correctness is established.

## Onboarding, retention, and UX priorities

The product's strongest loop is: receive a group invitation, take a first shot, anticipate the reveal, watch it together, then start another roll. The new unified invite and follow-up work support that loop. Stabilize those before adding unrelated social surfaces.

- Measure invite opened → code accepted → account created → first capture safely persisted → first roll joined → first reveal watched → second roll within 30 days. Keep capture safety separate from eventual upload success.
- Segment by inviter/group and release cohort. With 60+ accounts, absolute counts and individual failure reasons are more useful than small changes in percentages. Accounts are not equivalent to active users or paying customers.
- After a reveal, make the next group action easy while keeping invitation consent. The current follow-up design gets that distinction right; repair its error handling before wider use.
- Follow-up invitations also need to render when the user has no current rolls: `RollsView.swift:95–98` chooses the empty state, while invitation cards exist only inside `rollsScroll` at line 238. Leaving the last existing roll should not hide a pending invitation. Recheck block status for previously created invitations as well.
- Improve capture status to distinguish saving locally, waiting for upload, and needing action. A count alone should not imply the image is durable when a disk write failed.
- Keep notification requests tied to an understandable benefit. Measure permission denial separately from never being asked. Add category controls/quiet-time behavior when notification volume grows, rather than increasing reminder frequency blindly.
- Run onboarding on a small phone with the keyboard open, VoiceOver, and large text. `UsernameView.swift:79–85` has 30-point color buttons without descriptive accessibility labels; the app-wide type ceiling is `.accessibility2` in `FlimFont.swift:100–107`. Improve labels, hit areas, and layout reflow deliberately.
- Preserve the improved contextual Find friends ranking. Do not refill it with arbitrary strangers just to avoid an empty state.
- Moderation remains a real operational gap for public admission. Define who reviews reports, what evidence they see, how mistakes are reversed, and how quickly urgent reports are handled. Existing report buttons alone are not that workflow.
- Report eligibility deserves a server review: `schema.sql:883–885` validates reporter identity, while two distinct reports trigger hiding at `1584–1586`. Require visibility/eligibility and proportionate abuse controls so arbitrary known photo IDs cannot be used for easy coordinated hiding.

## Costs, R2, and monetization

### Model cumulative retained media, not just monthly active users

The owner's correction to the earlier break-even statement was right. Paying users generate storage too; free and inactive accounts can retain media indefinitely. Covering a $25 subscription does not establish sustainable unit economics.

Use monthly cohorts and these relationships:

```text
retained_GB[t] = retained_GB[t-1] + uploaded_GB[t] - physically_deleted_GB[t]
uploaded_GB[t] = new_photos[t] × measured_bytes_per_photo_all_renditions / 1e9
origin_bytes[t] = requested_image_bytes[t] × device_cache_miss_rate
contribution[t] = earned_net_revenue[t]
                  - storage[t] - delivery[t] - request/compute[t]
                  - support/refunds/other_variable_costs[t]
operating_result[t] = contribution[t] - fixed_costs[t]
```

For illustration only, 60 people each adding 20 photos/month at 1.4 MB across all stored renditions add approximately **1.68 GB/month**, or **20.16 GB/year**, with no growth and no deletion. That is not a measurement of FLIM. Acquired users, inactive archives, orphan objects, migration duplicates, and larger uploads all change the result.

Separate annual cash receipts from revenue earned over the service year. Model paid users' increased capture volume, renewal, inactive retention, and the cost of keeping a former subscriber's photos. A plan must have positive incremental contribution before additional subscribers can reliably help cover fixed costs.

### R2 is still migration work, not a ready switch

`cloudflare/worker/worker.js:73–84` caches authorization decisions for ten minutes, but still reads the object from R2 on each request. The path matcher at line 61 covers capture-style names, not avatar/cover names. The client delivery seam remains unwired in `docs/R2_MIGRATION.md`; backfill is not a continuous write/delete system.

Before cutover, verify authorization parity for private/developing/hidden/blocked/shared photos, avatars and covers; authenticated image requests; new uploads; deletes; backfill completeness; byte integrity; fallback; and rollback. Define the acceptable revocation window for cached authorization. Do not count CDN byte-cache savings that the Worker does not implement.

The existing tripwire (`scripts/r2_trigger_check.sh`) uses a fixed **9 MB per app open** model. Its output is a planning estimate, not actual bandwidth. The R2 document also contains old launch gates and very large-user cost estimates that should not be treated as today's measured financial model.

**Recommended sequence:** fix rendition linking → collect real usage and byte metrics → update the existing financial workbook → decide the migration threshold → complete and verify the storage lifecycle. R2 can reduce delivery exposure, but it does not eliminate Supabase's auth/database bill or cumulative storage costs. No provider price refresh was performed for this audit.

### Monetization experiments worth testing

| Option | Why it fits FLIM | Cost/quality constraint |
|---|---|---|
| Annual supporter plan | Lets satisfied users support the app; optional visual/profile/export presentation perks | Model renewal and ongoing retained storage; avoid an undefined lifetime-storage promise. |
| Event/host purchase | One organizer pays for a trip, party, or recurring group; friends join with low friction | Define event capacity, retention, and organizer tools; bound upload/storage exposure. |
| Printed contact sheets or albums | Physical output fits the disposable-camera experience | Validate fulfillment costs, permission, quality, and support before building integrations. |
| Premium creative/export features | Optional layouts, presentation controls, or curated outputs have visible value | Keep the core camera trustworthy; don't degrade basic image quality to manufacture an upgrade. |

Start with willingness-to-pay conversations among repeat groups and a simple plan description. Do not choose a price solely to divide $25 by an assumed payer count. Avoid advertising/engagement pressure as the first business model for this intimate group-photo product.

The owner-only export rule matters to event monetization: do not sell a host a downloadable package of everyone else's photos unless a separate consent/product-policy change explicitly permits it.

Before implementing payment, specify entitlements, purchase restoration, cancellation behavior, retention after lapse, and deletion/export behavior. These are missing product decisions, not merely a payment-button task.

## Verification and handoff plan

Existing tests cover many pure helpers and the new queue's basic ordering/isolation/pruning. They do not establish that deployed permissions accept real client writes or that multi-stage failures recover safely. The UI share harness is deliberately outside the default Flim CI test scheme (`project.yml:205–216`). SQL and Edge Function deployment remains manual in the workflow. No tests were rerun during this read-only audit.

### Next batch: integrity and production compatibility

1. Reconcile live photo grants with all writes made by build 365 and the upcoming client; verify rendition linking on a new capture and after relaunch.
2. Close the photo-INSERT path boundary with authenticated negative tests.
3. Unify single, batch, and account deletion behavior; bound cleanup failure.
4. Bind queued captures to their original account and deduplicate restore states.
5. Verify with an isolated staging database and ordinary user credentials; service-role tests cannot prove client RLS compatibility.

### Following batch: delivery and public UX

6. Finish feed generation guards and activation queue serialization.
7. Apply export eligibility consistently and align homepage audience language.
8. Add follow-up creation idempotency, errors, and name validation.
9. Make push outcomes and sweeper failures observable; add lease ownership.
10. Run the real share-flow UI test and a physical-device offline burst/account-switch/deletion pass before closing the release checklist.

### Then: sustainable growth

11. Track successful first captures, reveal viewing, repeat groups, rendition coverage, orphan bytes, download bytes, and retained storage by cohort.
12. Update financial assumptions with those measurements, including inactive archives and paid usage.
13. Test supporter versus event-host willingness to pay, then finish R2 only when the measured benefit and complete migration plan justify it.

Do not mark a finding closed from a happy-path test or a PENDING entry alone. The specific failure scenario above should be covered, and backend changes must remain compatible with supported installed clients.
