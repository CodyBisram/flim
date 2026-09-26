# Feed "new" rework: plan for a Claude Code session (2026-09-26)

Hand this whole file to the session. Work on branch `claude/edit-flim-app-b7p5b6`.

**Budget note:** the session may have little usage left. Work in the phase order below.
Commit and push at the end of each phase, so a session that stops mid-way still leaves
working, shippable progress. Phase 1 alone fixes most of what the owner sees.

---

## The problem (the owner's report on 1.6.0)

- The header says "2 shots from 13 friends", which can't be right: 13 friends can't share 2 shots.
- The number changes as more pages load.
- The pills on grouped posts never clear. Sherry's day says "7 new" and Shanaya's says
  "4 new" after the owner has already scrolled past them. That contradicts the header too.

## Root causes (audited, cited)

1. **The header mixes two sources.** The shot count comes from the server:
   `feed_unseen_count()` minus reads the server hasn't heard about yet.
   The friend count is `max(local stillOpenAuthors, serverFriends - finished, 1)`
   (`Flim/Models/FeedUnit.swift:240`), so it follows the phone's own seen-marks.
   When the phone and the server disagree, shots comes out small and friends comes out large.
2. **The phone and the server drift apart.**
   - `FeedSeenStore.pullFromServer` runs only when an account activates (`FeedSeenStore.swift:109`).
     If it fails, it gives up without saying so (`:281`).
   - The server counts posts the feed never shows. `feed_unseen_count` doesn't filter
     `posts.hidden` or `blocks`, but the feed query does (`FeedService.swift:1061`, `:1106`).
     Those shots can never be marked seen.
3. **A shot only counts as seen when the pager lands on it** (`FeedUnitCard.maybeMarkReached`, `:591`).
   A 7-shot day needs seven swipes before its pill clears. Scrolling past the card, with every
   thumbnail visible in the film strip, marks only the one frame on screen.

## The decision (owner-approved direction)

- **Seen is per card, not per photo.** Once a card has been on screen (the existing visibility
  threshold), every shot in it counts as seen. The pill then only means "posted since you last
  looked at this day". If Sherry adds 3 shots later, her day moves back to the top (the sort is
  by `newestAt`) reading "3 new".
- **No "N shots from N friends" in the header. Show nothing there.** The feed is newest first,
  so everything unread sits together at the top, down to the caught-up line.
  Nothing jumps down the feed, and nothing loads every page.
- **Keep:**
  - the floating "New posts ↑" button
  - the caught-up line (its position is still fixed at load)
  - syncing seen-marks to the account (`post_seen`, `record_posts_seen`)
  - the backlog seed for people upgrading
  - the 7-day retention window
- **Accepted trade-off:** scrolling fast past a 14-shot day marks all 14 as seen.
  That's intended. The thumbnails were on screen.

---

## Phase 1: mark the whole card seen (highest value, do first)

Files: `Flim/Services/FeedSeenStore.swift`, `Flim/Views/Feed/FeedUnitCard.swift`.

1. Add `FeedSeenStore.markSeen(_ ids: [UUID])`, a batch version of `markSeen`.
   - First-seen date wins, as it does today.
   - Apply the cap once.
   - Call `schedulePersist` and `scheduleFlush` once each for the whole batch.
   - Keep the single-id `markSeen` as a one-element wrapper, or update its callers.
2. In `FeedUnitCard.maybeMarkReached()`, mark every id in `unit.items` instead of only
   `current.post.id`. Keep both guards, `isVisible` and `markingEnabled`. Those guards (and the
   visibility-not-`onAppear` rule) are what stop cards built below the fold from being marked.
3. `openOnFirstUnseen(markIfVisible:)`: when the card is visible, mark the whole unit there too.
   The reposition to the first unseen frame should stay. The card still opens on the frame the
   reader hasn't seen, and only then does everything count as seen.
4. **Newly arrived frames on a card already on screen.** When `unit.items` changes (the existing
   `.onChange(of: unit.items.map(\.post.id))`) and the card is visible, call `maybeMarkReached()`
   so the new frames are marked too. It's fine either way; just decide it on purpose.
5. Review the swipe `.onChange(of: selection)` marking and the `repositioningProgrammatically`
   flag. If swiping no longer adds anything once the whole card is marked on visibility,
   simplify it. Don't remove the flag unless you're sure nothing else needs it.
6. Tests (`FlimTests/FeedSeenStoreTests.swift`):
   - a batch mark keeps the first-seen date
   - it writes to disk once
   - it queues every id for sync
   - it drops the mark when signed out (`activeUserId == nil`)
7. Update the doc comments that describe per-frame marking: the `FeedSeenStore` type comment
   ("a group with two unseen shots reads '1 new'"), and the comments in `FeedUnitCard` around
   `:198` and `:591–612`.

Commit, then push.

## Phase 2: remove the header count and its math

Files: `Flim/Views/Feed/FeedView.swift`, `Flim/Models/FeedUnit.swift`,
`Flim/Services/TabSignals.swift`, `FlimTests/FeedUnitTests.swift`.

1. `FeedView.header`: remove the "·" separator and the ledger button
   (`if let ledger = remainingLedger ...`, roughly `:439–459`) and `ledgerLabel`.
   The header becomes: "Feed", then a Spacer, then the bell, Find friends and the avatar.
2. Delete what only the ledger used:
   - state: `serverLedger`, `serverLedgerAt`, `serverLedgerPending`, `jumpToUnseenSignal`,
     `jumpTargetId`, `jumpGeneration`
   - the `.onChange(of: jumpToUnseenSignal)` block (the up-to-40-page loop)
   - functions: `acceptServerCount`, `recountUnseen`, and wherever the code re-counts on
     `seenStore.flushGeneration`
   - the `serverLedgerPending.formUnion(...)` line in `seedFeedBacklogIfNeeded`.
     The seed still runs; `seedBacklog` can still return its ids, the call site just ignores them.
   - In `reload()`: the `countedAt` / `pendingAtCount` / `async let counted` lines.
     Keep `await seenStore.flushPending()` before loading.
3. `FeedUnitCard`: remove the `jumpGeneration` and `isJumpTarget` parameters and their `.onChange`.
   `catchUpGeneration` stays.
4. `FeedUnit`: delete `wasCounted`, `remainingLedger`, and the "The header count" comment block.
   Keep `loadedRemaining`, or replace it with something simpler, because the tab dot and the
   caught-up line still need a local "anything unseen?" answer:
   ```swift
   static func hasUnseen(units: [FeedUnit], currentUserId: UUID?, isSeen: (UUID) -> Bool) -> Bool
   ```
   It covers loaded units only, skips your own posts, and doesn't need the 7-day filter,
   because the query already stops at 7 days.
5. `caughtLine` (the copy on the caught-up block): drop the "N shots from N friends still above."
   branch. The line is always "Nothing new until someone shoots something."
6. **Tab dot.**
   - Inside the feed: `signals.feedHasUnread = TabSignals.feedDot(unseen: FeedUnit.hasUnseen(...), unreadActivity:)`.
     Update it after `reload()` and whenever marks change. Page one is the newest posts,
     so "nothing unseen on page one" is a good enough "nothing new".
   - `TabSignals.refresh` (launch and foreground) still needs a server answer, because the feed
     may not be loaded yet. Keep `feed.unseenCount()` there, treat it as yes/no
     (`shots > 0`), and do Phase 3 so it stops counting posts that never render.
     Change `feedDot`'s signature to take a Bool and update `TabSignals` tests if any exist.
7. Tests: delete the `remainingLedger` / `wasCounted` tests in `FeedUnitTests.swift`, and add
   tests for `hasUnseen`: own posts are ignored, a fully seen feed gives false, and a single
   unseen frame gives true.
8. `grep -rn "remainingLedger\|serverLedger\|jumpGeneration\|jumpToUnseen\|ledgerLabel" Flim FlimTests FlimUITests`
   must come back empty. Check `FlimUITests/FeedCommentsReturnUITests.swift` and
   `FeedPreviewDemoHost.swift` for references to the header count.

Commit, then push.

## Phase 3: server count matches what the feed shows (small migration)

Use `supabase-guardian` if it's available. Otherwise write the migration by hand. **Do not apply it
to production.** The owner applies it. Write the file, fold it into `supabase/schema.sql` under
the existing section, and say it's pending.

New migration `supabase/migrations/2026-09-26_feed_unseen_count_visible.sql`: the same function,
plus these two conditions:
```sql
  AND p.hidden = FALSE
  AND NOT EXISTS (SELECT 1 FROM public.blocks b
                  WHERE (b.blocker_id = auth.uid() AND b.blocked_id = p.user_id)
                     OR (b.blocker_id = p.user_id AND b.blocked_id = auth.uid()))
```
Before choosing one direction or both, check how `FeedService.blockedIds` is built (whether it
covers only people you blocked, or people who blocked you too) and match it exactly. The return
shape stays the same, so no client change is needed.

Optional, only if budget remains: make `pullFromServer` retry once on the next foreground if it
failed, instead of giving up for the whole session.

Commit, then push.

---

## Verification (per phase, before each push)

- Build and unit tests: use `sim-verifier` at TARGETED depth, or run the repo's usual
  `xcodebuild test` command for the `Flim` scheme with `FeedUnitTests`, `FeedSeenStoreTests`
  and `FeedSeenSeedTests`. If no Mac or simulator is available in the session, say so under
  NOT VERIFIED. Don't claim the build passed.
- Read the diff once more, looking for what would break: a card built below the fold must
  never mark anything (visibility only), and marking must stay gated on `ledgerSnapshotted`
  (`markingEnabled`).
- For the owner to check on a device after the build:
  1. Open the feed. The header shows no count.
  2. Scroll past a multi-shot day. Its "N new" pill is gone when you scroll back.
  3. A friend posts a new shot on a day you've already seen. That day moves to the top reading "1 new".
  4. The tab dot clears after scrolling through the new cards, and comes back when someone posts.

## Out of scope (don't touch)

- The 7-day window, per-author grouping, the caught-up line's position rules, how Spotlight
  strips are placed, the backlog seed decision (`FeedSeenSeed`).
- Anything in the camera, rolls or film-look code.
- `docs/PENDING.md`: add one short "done 2026-09-26" entry at the end if budget allows,
  otherwise leave it alone.

## Handoff format

Finish with the repo's completion contract (`.claude/rules/agent-completion.md`): STATUS,
CHANGED, VERIFIED, NOT VERIFIED, RISKS, HANDOFF. List which phases landed and which didn't.
