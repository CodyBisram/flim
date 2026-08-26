---
name: backlog-burn
description: One bounded iteration of mechanical cleanup — tests for untested pure logic, doc drift, provably dead code — on a branch, verified, never pushed. Run as `/loop /backlog-burn` for a burn session. Never features, never product judgment.
---

# FLIM backlog burn

One iteration: pick ONE bounded mechanical item, do it, verify it, commit it to the burn
branch, stop. Designed for `/loop /backlog-burn`; each iteration stands alone and the
loop ends when no safe candidates remain.

This loop exists precisely because it cuts against the repo's conventions (owner-ratified
changes, on-device testing) unless scoped hard. The scope rules below are the whole
skill; when in doubt about whether an item qualifies, it does not.

## In scope

- Tests for existing untested PURE logic (the FeedUnit/RollImminence style: pure
  functions, fixed calendars, no UI, no network).
- Doc drift: statements in docs/ or README contradicted by the current code. Fix the
  doc, never the code.
- Comment drift: comments describing behavior the code no longer has.
- Provably dead code: unreferenced private symbols, verified by grep across the whole
  repo AND a successful build after removal. When uncertain, skip.

## Out of scope, permanently

- Features, UI, copy, anything user-visible.
- The look pipeline (InstantFilmProcessor, LUTs, FilmStock, fit_lut.py).
- Supabase schema, RLS, functions, migrations, anything under supabase/.
- Anything listed as deliberately parked in the owner's deferred-work decisions:
  parked means decided, not forgotten.
- Refactors of working code. Moving code is not cleanup.
- Dependency or toolchain changes.

## Mechanics

1. Branch: all work lands on `backlog-burn-YYYY-MM-DD`, created from current main if it
   does not exist. NEVER commit to main, NEVER push any branch. The owner reviews the
   branch and decides what merges; that is the whole review gate.
2. Ledger: `docs/BACKLOG.md` holds the candidate list. Each iteration: if the ledger has
   no unclaimed candidates, spend the iteration scanning for new ones (untested pure
   types, doc drift, dead symbols) and writing them down instead of changing code. Mark
   each item's status: `candidate`, `done <short-sha>`, or `skipped: <reason>`.
3. One item per iteration, smallest first. An item that grows beyond its description
   mid-work gets reverted and marked `skipped: bigger than it looked`.
4. Verify before every commit: full build plus FlimTests via the sim-verifier toolkit
   commands. A test-only item must FAIL before the fix exists or PASS for new coverage;
   a dead-code item must build clean after removal.
5. Commits: one per item, one plain line in the repo's voice, no tool or assistant
   attribution of any kind.
6. Report per iteration using the agent-completion contract (STATUS / CHANGED /
   VERIFIED / NOT VERIFIED / RISKS / HANDOFF).

## Stop conditions

Stop the loop (do not idle) when: the ledger has no candidates after a scan iteration,
verification fails twice on the same item, or anything requires a judgment call the
scope rules do not answer. A stopped loop reports why; it never widens its own scope.
