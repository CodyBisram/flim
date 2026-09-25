An independent audit of 1.6.0 (e697693) just came back: two reviewers, one server and admin, one iOS client, read-only, from a separate cloud session. The owner liked your approach and it was judged on its own merits, not against any earlier prompt. Verdict: sound design, a narrow public exception done right, clean account-switch and push routing, one blocker on the admin page, three server issues to fix before the first week is published, two client bugs.

How to work this list:
- Verify each finding against the code before you touch anything. If one is wrong, say why in one line and skip it. You have pushed back well before; do it again where it is earned.
- Fix in the order below, one commit per numbered item or per logical group, suite green before each, in the repo's commit voice.
- The migration header says NOT YET APPLIED. Items 2 to 5 should land in that same migration if it is still unapplied, or in a new dated migration if it has been applied. Tell me which.
- Section C is design critique, not bugs. Weigh each point, decide, and tell me what you changed and what you are leaving and why. Do not do all of it by reflex.
- End with the completion contract from .claude/rules/agent-completion.md.

## A. Before the first Monday (blocker and server)

1. **The admin panel cannot show any Spotlight frame.** `web/vercel.json:30` sets `img-src 'self' data:`, and `web/admin.html:~821` (`frameNode`) sets `img.src` to a Supabase signed URL. That host is only in `connect-src`, so every card renders a broken image, and the "Cannot load" text never shows because the URL signed fine. No admin card has ever loaded an image, so this path has never worked. Fix: add `https://wxvwamwrjlrvqmuaafjv.supabase.co` to `img-src`, or fetch to a blob, add `blob:`, and revoke object URLs on each render. Deploy with `cd web && vercel --prod --yes` and verify the served header.

2. **Captions can change after a frame is chosen or published, and the change goes public.** `2026-09-25_spotlight.sql:223-259` locks tags while an entry is live or chosen. Nothing locks `posts.caption`, the one column clients may update, and the widened posts policy serves it to every signed-in user. The owner approves a harmless caption, then the photographer edits it to abuse or to an @mention. Fix: a `BEFORE UPDATE OF caption ON posts` trigger with the same predicate as `refuse_tag_in_spotlight`. The client should say why the edit was refused, the way it does for tags.

3. **Two reports can hide a published frame for everyone, followers included.** `auto_hide_reported` (schema.sql ~1584) hides a photo and its posts at two distinct reporters. The report insert checks only `reporter_id`, and `spotlight_published` hands out `photo_id`. Before Spotlight a stranger could not reach the post. Now any two signed-in accounts, or one person with two, can take a published frame down for its own audience. Fix: exempt a published, unremoved Spotlight frame from auto-hide and put it in the owner's reports queue instead, or count only reporters for whom `post_visible_to` is true.

4. **An unpublished week never leaves the queue.** `list_spotlight_queue` (~624-628) returns every unpublished week, and the Monday alert (~1400-1406) counts them forever. Withdraw works only in the current week (~379), and tags stay refused on a chosen entry indefinitely (~247). A skipped week keeps a live Publish button, and publishing it months later pushes a week the photographer could no longer take back. Fix: an owner `close_spotlight_week` (a skipped or closed timestamp), and have choose and publish refuse weeks more than about 14 days past close. Exclude closed weeks from the queue, the alert and the tag lock.

5. **Smaller server and admin items.**
   - `web/admin.html:~994`: Remove in the Waiting view is permanent (there is no un-remove RPC, and choose treats removed as not_found, ~746), but its confirm does not say so. The Published view's confirm at ~920 does. Add the same sentence.
   - `web/admin.html:~983`: `blocked` leaves out `r.blocked_with_owner`, and `choose_spotlight_entry` (~739-760) does not refuse it, so the owner can choose and publish a frame he cannot see. Add it to both.
   - Publish (~856-859) does not re-check covered or `photos.hidden` before granting the badge. Add `post_is_covered` to the count and to the badge loop.
   - Before applying, diff the migration's full copy of `_ratchet_badges` (~910-1367) and both CHECK lists (~887-902) against production's `pg_get_functiondef` and the live constraint definitions. A badge or event applied after this copy was taken would be silently reverted. Report the diff.

## B. Client bugs

6. **An unseen strip can drop in above the reader after paging.** `Flim/Models/Spotlight.swift:~402-425` (`SpotlightSlot.slot`) lifts an unseen strip to `.aboveCaughtUpBlock` when its position is past the seam. `FeedView.swift:~1036-1045` re-runs placement on grow-only passes, and a `.hidden` slot is not anchored, so it gets re-placed. The paging path at `FeedView.swift:~890` calls `snapshotLedger(growOnly: true)`. Scenario: fresh posts at the top put the caught-up block after unit 2; a week published six days ago is older than the ten loaded units, so its slot is hidden; the next page loads, and the strip is inserted above the viewport. The orphan re-placement at `FeedView.swift:~323` has the same shape. The existing test only covers `seam == .top`. Fix: pass `unseen: false` on grow-only passes so the lift happens only at a full snapshot, and add a test with the seam after a unit.

7. **A failed put-up can show as up after an undo.** `FeedService+Spotlight.swift:~289-293` and `~331-339`. Put up A (slow commit), swap to B (its previous is the optimistic A), A fails while B is unsettled (no notice, no re-read), then undo B. The menu shows A as up, the server holds nothing, and no notice ever appeared. Fix: at the end of `revertSpotlight`, call `refreshOwnSpotlightEntry()` when `spotlightWrites.isSettled`, or have the late-failure path set a flag the next settle consumes with a refresh and the notice. See C2 first; it may make this moot.

8. **Smaller client items.**
   - `Spotlight.swift:~171-186`: `SpotlightWeekLabel` builds and formats in `Calendar.current`, so on an Islamic, Hebrew or Persian calendar "2026-09-14" becomes month 9 of that calendar. Use `Calendar(identifier: .gregorian)` with `timeZone = .current`. Same class as the open DarkroomZoomRows row.
   - `Spotlight.swift:~176, ~280`: a new `DateFormatter` per label call, inside view bodies (the strip, each sheet row, up to 52 shelf cards). Cache static formatters.
   - `FeedService+Spotlight.swift:~367`: "Take it down" calls `flushAndWait()`, which commits any staged action. A post deleted just before loses its Undo. Flush only a Spotlight put-up, or wait on the Spotlight queue alone.
   - `MainTabView.swift:~255, ~487`: the `.spotlightWeek` route presents a sheet even when one is already up (Activity, or FeedView's own Spotlight sheet). SwiftUI refuses the second presentation and `spotlightSheet` stays set. Dismiss first, or route through FeedView's sheet.
   - `FeedService+Spotlight.swift:~84`, `SpotlightViews.swift:~62`: strip frames are signed only at reload. With the feed open over an hour, an uncached frame stays a placeholder. Re-sign on foreground, or when a visible frame's URL is past its TTL.
   - `SpotlightViews.swift:~295`: `withAnimation(.snappy) { proxy.scrollTo }` ignores Reduce Motion.

## C. Design critique: your call, tell me what you decide

1. **Discoverability.** The only entry is a post's overflow menu, and the only place that teaches it is a sheet reached from a strip that exists only after a week is published. At 77 people the first week may get no put-ups at all. Consider one quiet line after posting, in the Post confirmation or the Darkroom day meta, once per account.
2. **The undo capsule may be overbuilt.** A put-up can be taken down any time until close, so the five-second window protects nothing, and it is the whole reason for `RevisionedWriteQueue`, revisions and settle state, about 150 lines, and item 7. A direct call with an in-flight guard may be enough. If you keep it, say what it protects.
3. **Strip placement may be overbuilt for a weekly event.** Placement, slot, seam interplay and grow-only re-placement produced item 6. An alternative: pin an unseen strip to the top on the first reload after publish, then place it by date. If you keep the current machinery, item 6's fix is the minimum.
4. **Tell photographers strangers can react.** The first-time sheet says frames are shown to everyone with their caption but never that strangers can react, so the first reactions from strangers will surprise people. Say it before the put-up.
5. **Consent between close and publish.** Photographers cannot withdraw after 04:00 Monday, yet nothing is public until the owner publishes. Consider allowing withdraw until the week is published.
6. **"Removed" does three jobs:** owner veto, photographer take-out, and post-publish takedown, all one-way. A misclick needs SQL. Consider an owner-only undo for owner removals.
7. **Small copy:** "Your badge stays" appears twice (menu subtitle and dialog); once is enough. Gold for one team pick sits level with "one year"; consider the tier.
8. **Scale.** About 2,300 client lines and 1,400 SQL lines for a few frames a week. `list_spotlight_queue` and `list_spotlight_published_admin` return the same 19 columns; one function with a mode flag would do. The admin loads every unpublished week with no limit and signs every path on each render. No action needed now beyond item 4; note it.

## What the audit found clean (do not touch)

Only two predicates widened (the posts policy and the storage read), and the comment and tag policies state their own visibility rather than inherit it. No other post, tag, comment or grid data leaks to strangers. All six admin RPCs check `is_owner()` in the body; no anon grants; every definer sets `search_path`. The week key is right at Monday 03:59 and both DST changes. The push is ledger-keyed on (kind, week, user), fails closed, and its route matches `PushDestination`. The schema fold matches the migration. On the client, every write after an await has both an epoch and a generation guard, all Spotlight state resets on account change, UserDefaults keys are per account, the f14316d UndoCenter change drops a revert only after the account really moved, the demo host is DEBUG-only, both targets are at 1.6.0, the strip never enters `feed.feed`, and the new copy follows COPY.md.

## Verify on device after the fixes

1. The admin Spotlight panel renders thumbnails.
2. Editing the caption on a chosen frame is refused, with a reason.
3. As a non-follower, open a published frame: photo and reactions, no comments, no tags, no grid.
4. Fresh posts at the top, a published week older than the loaded units, more pages: scroll to the bottom and confirm nothing jumps.
5. Put up A at 100% loss (Network Link Conditioner), swap to B, restore the network, undo: the menu matches the server.
