# Reading a FLIM crash

Crashes land in the Supabase table `crash_diagnostics`, uploaded by `CrashReporter` from Apple's
MetricKit. They arrive as **raw binary offsets**, not function names, so a row is unreadable until
you resolve it against the dSYM of the exact build that produced it.

This is the whole procedure, and it needs no Apple Developer account.

---

## 1. Find the crash

```sql
select occurred_at, app_version, app_build, os_version, device_model, kind, detail
from crash_diagnostics
order by occurred_at desc nulls last
limit 20;
```

Read `occurred_at`, not `created_at`. **`created_at` is when the row was uploaded**, and MetricKit
only hands diagnostics over on a *later* app launch, so several rows sharing a `created_at` are one
flush at app start rather than several crashes at that instant. Mistaking one for the other makes
three crashes look like six.

`detail` gives the cause, e.g. `exception 6 · code 1 · signal 5`. That combination is
`EXC_BREAKPOINT`/SIGTRAP: a deliberate Swift runtime trap. A force-unwrapped nil, an array index
out of range, a failed precondition, or a concurrency assertion. It is never a memory fault.

## 2. Get the matching dSYM

Every CI build uploads one as a workflow artifact named `dsym-<commit-sha>`.

```bash
gh run list --workflow=ios-testflight.yml --limit 20
gh api repos/<owner>/<repo>/actions/runs/<run-id>/artifacts   # find the dsym- artifact
gh run download <run-id> -n dsym-<sha>
unzip Flim.app.dSYM.zip
```

Match on `app_build` from the row. Every build has its own dSYM and only the exact one resolves;
one commit apart gives wrong line numbers or nothing at all.

**Retention is 90 days.** GitHub hard-caps public repositories at 90 regardless of the
`retention-days` value in the workflow (private repos allow 400). Since MetricKit delivers on a
later launch, reports routinely arrive long after the build that made them, so a crash older than
the artifact is unreadable again from here. Apple keeps its own copy for as long as the build
exists in App Store Connect, so Xcode Organizer remains the fallback.

## 3. Identify which binary crashed

The stack in `call_stack_tree` is JSON. Each frame is a `binaryUUID` plus an
`offsetIntoBinaryTextSegment`. Check the UUIDs of what you downloaded:

```bash
dwarfdump --uuid Flim.app.dSYM
dwarfdump --uuid RollActivityWidget.appex.dSYM
```

Do not assume the app binary crashed. The first crash triaged this way turned out to be in the
**Live Activity widget extension**, not the app, and assuming otherwise cost a day of looking in
the wrong place.

## 4. Symbolicate

```bash
atos -o Flim.app.dSYM/Contents/Resources/DWARF/Flim \
     -arch arm64 -l 0x100000000 0x<0x100000000 + offset>
```

The `__TEXT` segment's `vmaddr` is `0x100000000` (confirm with `otool -l`). So a frame at offset
`26188` is address `0x10000664c`. Passing the bare offset with `-l 0` returns the address back
unchanged, which looks like a failure and is really the wrong load address.

Frames are ordered root-first: the **deepest** subframe is where it crashed.

## 5. Read it

You get `file.swift:line`. Worked example, the first real one:

```
+26188  →  closure #1 in closure #1 in RollRevealLiveActivity.body.getter
           (RollRevealLiveActivity.swift:31)
```

Line 31 was `Text(timerInterval: Date()...revealAt, countsDown: true)`. `Date()...revealAt` builds
a `ClosedRange`, which **traps when its lower bound exceeds its upper bound**, so the widget
crashed every time a roll's reveal passed while its Live Activity was still on the lock screen.
Six of the seven crashes on record were that one bug.

---

## What this cannot tell you

- **Crashes from builds older than the artifact retention.** Use Xcode Organizer, which needs
  App Store Connect access.
- **Crashes that never arrive.** MetricKit delivers on a later launch, so someone who crashes and
  never reopens the app never reports at all. Delivery is also tied to the user's analytics
  sharing setting. Treat the table as a sample, never as a census.
- **System framework frames.** Those need Apple's symbols, which Organizer has and you do not.
