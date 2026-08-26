---
name: babysit
description: Post-push verification loop — watches origin/main and CI, rebuilds and tests locally on every new push, periodically does a Release-config build. Reports breakage only, fixes nothing. Run as `/loop /babysit` during work sessions.
---

# FLIM post-push babysitter

One iteration of the verification loop. Designed to run repeatedly via `/loop /babysit`
(self-paced) while the owner is working; a single invocation is one check pass. Reports
only; never edits, never fixes, never pushes. A failure report names the commit, the
failing step, and the shortest useful excerpt, per the completion contract's rule
against pasting full logs.

## State

Keep the last-verified commit SHA in the session scratchpad directory as
`babysit-last-sha`. First iteration of a session: initialize it to current
`origin/main` and verify that revision once as a baseline.

## One iteration

1. `git fetch origin main`. If `origin/main` equals the recorded SHA, report nothing
   (a no-op tick) and end the iteration.
2. New commits exist:
   - **CI**: `gh run list --branch main --limit 3` and check the run for the new head.
     If still running, note it and check again next iteration rather than blocking.
     A failed run: fetch its log excerpt (`gh run view --log-failed`), report.
   - **Local Debug**: build and run FlimTests with the exact toolkit commands in
     `.claude/agents/sim-verifier.md` (same project, scheme, destination, derived-data
     path). Report failures with the failing test names and their assertion lines.
3. **Release check**, because local tests are Debug-only and the archive is Release
   (the `#if DEBUG` trap): if the new commits touch any line containing `#if DEBUG`,
   or if no Release build has happened in this session yet, also run the Release build
   command from the debug/release-gap notes (`-configuration Release`, build only, no
   tests). Report compile failures; this is the check that otherwise waits for
   TestFlight to fail.
4. On success: record the new SHA and stay quiet. One short line at most ("main at
   <short-sha> builds, 338 tests pass, CI green"). The loop's value is silence that
   means something.

## Loop pacing

When run under `/loop` self-paced: after a push, poll CI on a delay matched to the
workflow's real duration; when main is quiet, idle at 20 to 30 minutes. Never tighter
than 5 minutes; this is a babysitter, not a watchdog.
