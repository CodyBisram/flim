# FLIM follow-up audit — September 11, 2026, evening

## Scope and verdict

Reviewed HEAD `3efea93` against `83df50b`, the baseline of `REPOSITORY_AUDIT_2026-09-11.md`. Six commits changed 31 files, with approximately 980 insertions and 155 deletions. Backend/storage, client reliability, and product/UX agents reviewed independently; the primary reviewer cross-checked the key findings. The review resumed after a usage-limit interruption; HEAD remained unchanged.

This was a source review. No application code, database, accounts, or deployments were modified. Tests were inspected, not executed. This report is the only new artifact from this pass. PENDING records production deployment and verification, but this audit did not independently inspect live grants, function logs, storage, or App Store binaries.

**The repository is materially safer than at the previous audit.** The rendition-grant regression and foreign-photo-path insertion hole are fixed in the current schema. Single-photo deletion now uses the safer batch implementation. Raw capture jobs retain their original account generation. Several specific UI races are also closed.

**It is not yet accurate to mark the entire delivery batch complete.** Activation flushing is only partly implemented, social-push retry handling introduces two concrete regressions, and alternate retry/refresh paths still cross asynchronous boundaries without retaining their original identity. The next batch should finish those flows, rather than add more broad features.

Release distinction remains essential: PENDING still identifies App Store 1.5.2 as build 365 and places native fixes in the 1.5.3 train. Server fixes affect installed clients immediately; committed Swift fixes are not evidence that App Store users have received them.

## Verified improvements

| Previous finding | Current source status |
|---|---|
| 1. Rendition UPDATE permissions broken | **Closed for the identified writes.** The hotfix grants `is_sorted`, `thumb_path`, `feed_path`, `burst_group`, and `is_developed`; existing installed-client writes are compatible again. |
| 2. Photo INSERT can reference another owner's files | **Closed for the reported bypass.** Inserted/changed photo paths must belong to the photo owner's folder. |
| 3. Single deletion removes files first | **Closed.** `deletePhoto` delegates to row-first `deletePhotos`. |
| 4. Account deletion ignores failed row deletion/loops forever | **Closed for those two failure paths.** Row deletion must succeed; folder cleanup is bounded and stops on removal failure. The multi-step account operation is still not atomic. |
| 5. Raw queued captures adopt the next account | **Closed for raw admission/restore.** Epoch captured before waiting, checked after processing and disk restore, and passed to upload. Failed-upload retry remains a separate open path below. |
| 6. Raw/processed recovery overlap | **Open.** No single per-photo recovery state or reconciliation was added. |
| 7. Old feed hydration overwrites refreshed feed | **That exact case is closed.** Final hydration checks generation; earlier refresh setup still races. |
| 8. Export rules inconsistent | **Updated rule implemented across normal surfaces.** Own photos may be exported; members may save all photos from their roll; foreign feed/chapter export remains restricted. Do not reapply the superseded own-photos-only rule to shared rolls. |
| 9. Push delivery/leases | **Partial.** Recipient outcomes and token-owned release added; retry-state, deduplication, expiry and persistence issues remain. |
| 10. Activation queue | **Not closed.** New scoped keys exist, but the actual flush still writes the old key. |
| 11. Direct reveal-time UPDATE | **Closed.** Direct roll UPDATE is now cover-only. INSERT-time timing remains a separate hardening item. |
| 12. Follow-up creation/UX | **Partial.** Stable request IDs, server retry lookup, preserved fetch results, and visible errors added. Quota and card-action races remain. |
| 13. Sweeper cap | **Improved.** Alert record and inspected 500-object batch recovery added. Alert delivery is still best effort. |
| 14. Schema replay | **Open, with another conflicting function return type added.** |
| 15. Homepage privacy promise | **Closed for the reported copy mismatch.** Homepage now describes member access to pages. |
| 16. Generated follow-up name overflow/length | **Closed.** Checked arithmetic and bounded generated names. Manual form input still needs validation. |
| 17. Same-emoji stale rollback | **The reported add/remove/add failure case is closed.** Revision and account checks added. |
| 18. Retry repeats expired signed URL | **Closed for a stable asset.** Retry now signs again; its URL override is not safely tied to asset identity. |
| 19. Shared invite limits/waitlist false success | **Unchanged.** Keep on the public-admission backlog. |

Hotfix evidence: `supabase/migrations/2026-09-11_photo_grants_hotfix.sql:15–46`. PENDING reports 17 of 26 recent photos missing renditions before the fix, a relink pass, and five remaining rows whose renditions had not uploaded. Those are historical deployment notes, not fresh measurements from this review.

## Findings to address next

### A. High priority — Failed-upload retry still has an account-switch leak

**Evidence:** `Flim/Services/PhotoService.swift:1216–1240, 1341–1374`; default upload epoch at line 349.

The raw queue was fixed, but `retryFailedUploads` snapshots A's pending records, awaits confirmation/cleanup, and then calls `captureAndUpload` without passing the original epoch. If B signs in during that wait, the upload adopts B's current epoch. A's upload path ordinarily fails authorization, but the failure can then append A's image bytes into B's visible failed-upload state.

The restore path also checks epoch at 1357, awaits removal of confirmed entries at 1364, then appends remaining entries at 1374 without a final check. A queue containing both confirmed and still-pending records exposes this window.

**Next action:** Bind retry and restore operations to both owner and generation at entry, pass that generation through every upload, and guard each final UI mutation. Preserve the previous account's durable files for that account.

**Acceptance:** Suspend manual retry during confirmation, switch A → B, resume. Repeat with a mixed confirmed/pending restore paused during cleanup. B must not display or retry A's photos, and A must retain its recovery path.

### B. P2 — Activation flushing reads and writes different queues

**Evidence:** `Flim/Services/Activation.swift:79–100, 114–131`; `Flim/ContentView.swift:132`.

`pending()` reads `activation.pending.<owner>`, while the successful flush writes its shortened list to the old `activation.pending` key. The owner-scoped queue never drains, so failed-once events resend on every flush. Server deduplication prevents duplicate milestone rows, but requests keep recurring.

The declared lock, flushing flag, and per-entry removal helper are unused. Pre-sign-in entries under `.none` are never moved or drained after account assignment; legacy unscoped entries are also not migrated. `log` records the owner for failure persistence but does not bind the asynchronous send to that owner's session.

**Next action:** Finish one serialized queue implementation: migrate old data, define neutral-event attribution, send under the correct account, and remove acknowledged entries from the same queue read. Update PENDING's claim that flushing is serialized and removes entries individually; the code currently does neither.

**Acceptance:** Actually flush with a controllable transport. Verify dequeue, failure retention, enqueue-during-flush, duplicate flush calls, neutral-to-account attribution, legacy upgrade, and account switching. Current tests only enqueue/read.

### C. P2 — Social retry state survives into later function invocations

**Evidence:** `supabase/functions/send-social-push/index.ts:272–276, 313`.

`pendingRetry` is a module-global set. Sources are added on failure but never removed or cleared. In a reused function instance, a source remains unsettled after a later successful delivery or after exhausting its three attempts. Its source row stays unsent and continues being scanned.

**Next action:** Make retry state local to one invocation and pass it through processing. Merely clearing shared state at request start is insufficient if requests can overlap.

**Acceptance:** Reuse the same runtime for two invocations: fail the first delivery, succeed the second. The second must settle the source. Repeat with the third attempt becoming terminal.

### D. P2 — Partial tag delivery can notify successful recipients twice in one run

**Evidence:** `send-social-push/index.ts:797–802, 839–854`.

New-post processing uses `post:<postID>` delivery identity. If one tagged recipient fails, it leaves all tag rows unsent. The later-tag block then immediately fetches those same rows, without requiring the parent post's initial delivery to be complete, and sends with a different `tag:<tagID>` identity. Recipients who already succeeded can receive another notification in that same run.

**Next action:** Give the same tag event one stable delivery identity across both routes, or keep the later-tag route from handling an unsettled initial post.

**Acceptance:** Publish with two tagged recipients; one succeeds and one fails. The successful recipient receives one notification total, including later runs, while only the failed recipient retries.

### E. P2 — A freshly signed image override survives changes to the image path

**Evidence:** `Flim/Views/Darkroom/PhotoGridCell.swift:408, 417–426, 445`; rendition upgrade in `PhotoPagerView.swift:1258–1271`.

Retry stores `resignedURL` in view state and always prefers it over the supplied URL. A new `.task(id:)` runs when the cache key changes, but the override is not cleared or associated with the old path. Retry also has no identity check after signing.

When a mounted image changes from thumbnail to feed rendition, it can fetch the old thumbnail URL and cache those bytes under the new feed path. A reused view with a different photo has the same wrong-asset risk. This can create persistent low-quality cached images even though the correct file exists remotely.

**Next action:** Store the override with its asset identity; disregard it when the path changes. Check identity after signing and before setting state. Keep URL identity and cache identity consistent throughout download and decode.

**Acceptance:** Pause retry signing, upgrade the mounted cell from thumbnail to feed path, then finish signing. Only the feed bytes may be stored under the feed key. Repeat with a different photo.

### F. P2 — Overlapping refresh setup can borrow the newest generation

**Evidence:** `Flim/Services/FeedService.swift:828–851, 866–868`.

`loadFeed` increments generation but does not retain its own value across following/block-list awaits. Old refresh A can pause there, B can complete, and A can resume, reset pagination, then call `loadMoreFeed`. The child captures B's current generation and passes the newly added final guard.

The unconditional loading-flag defers also let an old request clear a newer request's flag. The previous hydration fix is correct; it does not cover setup and cleanup.

**Next action:** Carry one request identity from refresh entry through setup, pagination, errors, and cleanup. Only the operation that owns current state may modify it.

**Acceptance:** Pause A's following lookup, complete B, resume A. B's author set, feed, cursor and loading state must remain authoritative.

### G. P2 — Follow-up quota is checked before its serialization lock

**Evidence:** `supabase/migrations/2026-09-12_audit2_server.sql:80–90`.

The count of five follow-ups per day is checked before acquiring the per-user advisory lock. Multiple distinct request IDs can all see four rolls, then acquire the lock in turn and exceed the cap. Deleting created rolls also removes them from the count.

The same-request retry lookup under the lock is a real improvement. It is the quota check that still races.

**Next action:** Check a durable quota record inside the lock after resolving idempotent retries. Decide explicitly whether deleting a roll should refund quota; it currently happens implicitly.

**Acceptance:** At four creations, issue several concurrent calls with distinct IDs. Only one additional creation may consume the remaining allowance. Retrying the same successful request must return its original roll.

### H. P2 — Lease tokens fix release ownership, not execution past expiry

**Evidence:** `2026-09-12_audit2_server.sql:139–173`; `send-develop-push/index.ts:249, 339–359`; social ledger operations at `296–313`.

A late run can no longer release its successor's lease. However, it can still continue sending after 240 seconds while another run acquires the expired lease. Recipient processing is read → send → upsert, without an atomic job claim or lease renewal.

Ledger read/write errors are also ignored. A failed read can resend completed work; a failed persistence step can erase the evidence needed for deduplication or recovery. Three attempts are a bounded policy, not proof of delivery.

**Next action:** Renew or stop before losing the lease, or atomically claim delivery jobs. Require successful state persistence before marking source completion. Document remaining unkeyed paths, including digest and some social/admin notifications.

**Acceptance:** Advance beyond lease expiry with the first sender suspended. A second run must not concurrently deliver the same recipient job. Inject ledger read/write failures and verify retry state remains recoverable.

## Smaller but concrete remaining issues

- **Invitation rollback restores stale unrelated cards.** `RollService.swift:143–150` restores the whole prior array when one dismissal fails. If another invitation was successfully joined/dismissed during that wait, it reappears. Restore only the failed item, preserving newer state.
- **Join and Dismiss can race on one card.** `RollsView.swift:589–631` guards/disables Join, but Dismiss does not honor the same busy state. A person can decline while a join is already committing. Serialize both actions per invitation.
- **Typed join failures are mapped as raw backend strings.** `RollService.swift:176–191` has already converted the backend error to `RollError`; `RollsView.swift:599` feeds its description into a mapper expecting `roll_developed`. Switch on the typed error and distinguish developed/full/not-found from connectivity.
- **Manual overlong names still reach generic server failure.** `CreateRollView.swift:82` checks nonempty only. Generated names are fixed; validate user-entered length too.
- **Schema replay remains unsafe.** Existing `invite_preview` return-shape and duplicate-policy issues remain. `schema.sql:6410–6411` also recreates `acquire_push_lock` as boolean before the final UUID-returning definition at 7120. Reapplying to the final schema can fail before later corrective DROP statements. Maintain a current bootstrap and test supported upgrade paths in isolation.
- **Roll INSERT still accepts client-supplied reveal timing.** The new UPDATE grant closes direct editing, but the creator INSERT policy and reveal trigger (`schema.sql:543, 567–578`) do not impose the same timing restrictions on initial values. Validate intended creation rules as well as updates.
- **Sweeper alerts are not guaranteed delivery.** The cap now creates a recoverable operational task, but the social sender marks an ops alert sent even if all APNs sends fail. Its response still says “Owner alerted” and returns 200. Distinguish alert recorded from alert delivered; expose a reliable failure signal.
- **Published post rendition references can lag photo repair.** `pin_post_paths` copies paths on post INSERT/UPDATE (`schema.sql:6579–6594`); the hotfix relinks photos, not all dependent posts. A post created before its photo renditions land can retain null paths until a later post update. Audit photo/post path mismatches after repairs and keep references synchronized or derive them at read time. This is a performance follow-up, not a claim that every post is currently affected.

## Unchanged work worth retaining

The raw and processed capture stores still overlap across a crash. Restore can schedule raw replay while the same photo appears in failed-upload recovery. Stable IDs limit duplicate server rows but do not prevent duplicate work. Raw JPEG and sidecar persistence is still two separate writes; the raw save result is still ignored while the shot waits. Finish a single per-photo recovery state before claiming crash-proof capture.

Other unchanged concerns: shared media/signed-URL cache account isolation; repair attempts exhausted before source bytes become available; per-size rather than per-asset download coalescing; missing analysis fields in persisted retry sidecars; full profile-post fetch without pagination; onboarding accessibility; moderation operations; campaign-preview throttling and waitlist requests returning success without being stored at the limit.

These have different urgency. Recovery and account boundaries deserve tests now. Profile pagination and larger accessibility layout changes can be scheduled separately. Public moderation and honest admission failures remain relevant even at 60+ users.

## Product, exports, and money

The changed export rule is intentional: members can save their shared roll. The eligibility helper and ordinary roll surfaces now reflect it. Foreign chapter contact-sheet export is hidden. A suspected foreign-chapter pager bypass was checked and rejected: although its rack flag is true, the mapper explicitly clears `rollId`, so the foreign-photo eligibility test fails. Do not put that suspected bug into the implementation queue.

There is a narrower product-model question around another participant's photo reposted to the viewer's own chapter: chapter mapping assigns the profile owner as photographer. Establish the intended consent/export semantics before treating those recaps as wholly owned. This does not block the explicit shared-roll policy.

The repeat-group loop is now implemented; polish its error and concurrency behavior before inventing another retention feature. Measure first durable capture, first reveal watched, second participating roll, and failures by app build and inviter group. Fix activation delivery before relying on its funnel counts for conversion decisions.

The rendition hotfix should reduce unnecessary master fallback. Verify that with fresh measurements of photo/post path coverage and downloaded bytes; a repaired grant alone does not prove every old row or cached image is repaired. The new signed-URL override bug is particularly relevant to perceived quality.

R2 and monetization code were not materially advanced in this diff. Keep the prior financial model: fixed Supabase cost plus cumulative retained photos, inactive archives, requests/delivery, support, and migration overlap. No updated production totals or provider pricing were collected here. Do not infer savings or a payer break-even count from these commits alone.

An event-host purchase remains worth testing because the owner explicitly wants shared-roll downloads. Define event duration, participant limits, archive allowance, downgrade behavior, and export permissions. An annual supporter plan remains a secondary option. Neither requires reducing the current image quality or promising unlimited lifetime storage.

## Recommended next batch and verification

1. **Account/recovery:** fix manual retry and mixed restore account guards; reconcile duplicate raw/processed recovery.
2. **Delivery state:** complete activation flushing; localize social retry state; unify post/tag delivery identity.
3. **Mounted UI identity:** bind retry URLs to paths; propagate refresh generation from the first await through cleanup.
4. **Server concurrency:** move follow-up quota inside the lock; handle lease expiry and ledger failures.
5. **UX and operations:** item-scoped invitation rollback, one busy state for both actions, typed errors, reliable ops alerts, and schema bootstrap verification.

Use controlled suspension/failure tests of the actual services and handlers. The new tests demonstrate naming and eligibility helpers, plus account-keyed enqueue behavior; they do not exercise actual queue flushing, warm-runtime push retries, partial-tag delivery, image identity changes, or concurrent follow-up creation. A green helper suite or an HTTP 200 cron run would not close those findings.

For release sign-off, record the exact supported client build, migration state, and test outcome. Keep server deployment verification separate from App Store rollout. The evidence now supports saying the main permission/deletion fixes landed in source; it does not yet support saying every audit item is complete.
