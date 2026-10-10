#!/usr/bin/env python3
"""Watches one App Store version's review state and pushes the owner (FLIM's notify-owner
function) each time it changes: Waiting for Review, In Review, approved, live, or rejected.

Run by .github/workflows/asc-watch.yml. A GitHub job lives at most 6 hours, so a watch longer
than that runs as a chain: each run polls until shortly before its limit, then dispatches the
next run with the same deadline and the last state it saw. Stops at release, at a rejection,
or at the deadline.

A chain can break without anything here failing: on 2026-10-05 a handed-off run was never picked
up by a runner and the watch simply ended. .github/workflows/asc-watch-backstop.yml
(scripts/asc_watch_backstop.py) is the repair: every hour while a watch is active it looks for a
live run and, if the newest one failed instead of finishing, starts the next one from that run's
own inputs (version, deadline, last state, carried in its run name). So this script exits
NONZERO whenever the watch is not finished and could not carry on, a failed final push
included, and zero only when the watch ended on purpose or handed off.

Environment: the ASC_* variables of asc_status.py, OWNER_NOTIFY_URL, OWNER_NOTIFY_SECRET,
GH_TOKEN and GITHUB_REPOSITORY (for the next link), and the inputs WATCH_HOURS, WATCH_DEADLINE,
WATCH_LAST_STATE, WATCH_VERSION, and WATCH_STOP (set by the backstop when it gives up: send the
owner WATCH_STOP_REASON and end the chain).
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

from asc_status import fetch_versions

POLL_SECONDS = 20 * 60
RUN_BUDGET_SECONDS = 5 * 3600 + 30 * 60   # hand off to the next run well inside the 6h job limit
NOTIFY_ATTEMPTS = 4
NOTIFY_BACKOFF_SECONDS = (10, 30, 90)
POLL_ERRORS_TOLERATED = 3                  # consecutive failed reads before the run gives up

WORDS = {
    "PREPARE_FOR_SUBMISSION": "is being prepared",
    "READY_FOR_REVIEW": "is ready for review",
    "WAITING_FOR_REVIEW": "is waiting for review",
    "IN_REVIEW": "is in review. Apple picked it up",
    "PENDING_DEVELOPER_RELEASE": "is approved and waiting for you to release it",
    "PENDING_APPLE_RELEASE": "is approved and waiting for Apple to release it",
    "PROCESSING_FOR_DISTRIBUTION": "is approved and processing for the App Store",
    "READY_FOR_DISTRIBUTION": "is live on the App Store. Time to turn on the update nudge",
    "ACCEPTED": "is approved",
    "REJECTED": "was rejected. Check App Store Connect",
    "METADATA_REJECTED": "had its metadata rejected. Check App Store Connect",
    "INVALID_BINARY": "has an invalid binary. Check App Store Connect",
    "DEVELOPER_REJECTED": "was pulled from review",
}
DONE = {"READY_FOR_DISTRIBUTION", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "DEVELOPER_REJECTED"}


def notify(title, body):
    """Pushes the owner, retrying with backoff. True once it lands, False if every attempt failed."""
    request = urllib.request.Request(
        os.environ["OWNER_NOTIFY_URL"], method="POST",
        data=json.dumps({"title": title, "body": body}).encode(),
        headers={"content-type": "application/json",
                 "x-owner-notify-secret": os.environ["OWNER_NOTIFY_SECRET"]})
    for attempt in range(1, NOTIFY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                print(f"notified: {response.read().decode()[:200]}")
                return True
        except Exception as error:   # retried; the caller decides what a final failure means
            print(f"notify attempt {attempt} failed: {error}")
            if attempt < NOTIFY_ATTEMPTS:
                time.sleep(NOTIFY_BACKOFF_SECONDS[min(attempt - 1, len(NOTIFY_BACKOFF_SECONDS) - 1)])
    print("::error::could not notify the owner")
    return False


def current(version):
    rows = fetch_versions()
    if version:
        rows = [r for r in rows if r["version"] == version]
    return rows[0] if rows else None


def hand_off(deadline, last_state, version):
    subprocess.run(
        ["gh", "workflow", "run", "asc-watch.yml", "--repo", os.environ["GITHUB_REPOSITORY"],
         "-f", f"deadline={deadline}", "-f", f"last_state={last_state}", "-f", f"version={version}"],
        check=True)
    print(f"handed off: deadline={deadline} last_state={last_state} version={version}")


def main():
    started = time.time()
    deadline = int(os.environ.get("WATCH_DEADLINE") or 0) or int(
        started + float(os.environ.get("WATCH_HOURS") or 72) * 3600)
    last = os.environ.get("WATCH_LAST_STATE", "").strip()
    version = os.environ.get("WATCH_VERSION", "").strip()

    if os.environ.get("WATCH_STOP", "").strip() == "true":
        reason = os.environ.get("WATCH_STOP_REASON", "").strip() or "The watch kept failing."
        label = f"FLIM {version}" if version else "The App Store watch"
        ok = notify(label, f"Stopped watching. {reason} Check App Store Connect yourself.")
        return 0 if ok else 1

    poll_errors = 0
    while True:
        try:
            row = current(version)
        except (Exception, SystemExit) as error:   # asc_status exits on an HTTP error
            poll_errors += 1
            print(f"read failed ({poll_errors} in a row): {error}")
            if poll_errors >= POLL_ERRORS_TOLERATED:
                print("::error::App Store Connect unreadable; the backstop resumes the watch")
                return 1
            time.sleep(60 * poll_errors)
            continue
        poll_errors = 0
        if row is None:
            print(f"::error::no App Store version {version or ''} found")
            return 1
        version = row["version"]
        state = row["state"]
        print(f"{time.strftime('%H:%M:%S', time.gmtime())}Z {version} build={row['build']} state={state}")
        if state != last:
            words = WORDS.get(state, f"is now {state}")
            if not last:
                told = notify(f"Watching FLIM {version}", f"It {words}. You'll get a push each time that changes.")
            else:
                told = notify(f"FLIM {version}", f"Build {row['build'] or '?'} {words}.")
            if told:
                last = state
            elif state in DONE:
                # The one push the whole watch exists for. Failing the run hands it to the
                # backstop, which starts a run from this run's last_state, so the change is seen
                # again and the push tried again.
                print(f"::error::{version} reached {state} and the owner could not be told")
                return 1
            # Otherwise `last` stays, so the next poll tries this push again.
        if state in DONE:
            print("done: final state")
            return 0
        if time.time() + POLL_SECONDS > deadline:
            # Failing the run when this push fails lets the backstop try once more (a resume run
            # before the deadline, a stop run after it) instead of reading success and switching off.
            told = notify(f"FLIM {version}", f"Stopped watching after the time limit. Still {WORDS.get(state, state)}.")
            return 0 if told else 1
        if time.time() + POLL_SECONDS - started > RUN_BUDGET_SECONDS:
            hand_off(deadline, last, version)
            return 0
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
