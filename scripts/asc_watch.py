#!/usr/bin/env python3
"""Watches one App Store version's review state and pushes the owner (FLIM's notify-owner
function) each time it changes: Waiting for Review, In Review, approved, live, or rejected.

Run by .github/workflows/asc-watch.yml. A GitHub job lives at most 6 hours, so a watch longer
than that runs as a chain: each run polls until shortly before its limit, then dispatches the
next run with the same deadline and the last state it saw. Stops at release, at a rejection,
or at the deadline.

Environment: the ASC_* variables of asc_status.py, OWNER_NOTIFY_URL, OWNER_NOTIFY_SECRET,
GH_TOKEN and GITHUB_REPOSITORY (for the next link), and the inputs WATCH_HOURS, WATCH_DEADLINE,
WATCH_LAST_STATE, WATCH_VERSION.
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
    request = urllib.request.Request(
        os.environ["OWNER_NOTIFY_URL"], method="POST",
        data=json.dumps({"title": title, "body": body}).encode(),
        headers={"content-type": "application/json",
                 "x-owner-notify-secret": os.environ["OWNER_NOTIFY_SECRET"]})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            print(f"notified: {response.read().decode()[:200]}")
    except Exception as error:   # a failed push must not end the watch
        print(f"notify failed: {error}")


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

    while True:
        row = current(version)
        if row is None:
            sys.exit(f"no App Store version {version or ''} found")
        version = row["version"]
        state = row["state"]
        print(f"{time.strftime('%H:%M:%S', time.gmtime())}Z {version} build={row['build']} state={state}")
        if state != last:
            words = WORDS.get(state, f"is now {state}")
            if not last:
                notify(f"Watching FLIM {version}", f"It {words}. You'll get a push each time that changes.")
            else:
                notify(f"FLIM {version}", f"Build {row['build'] or '?'} {words}.")
            last = state
        if state in DONE:
            print("done: final state")
            return
        if time.time() + POLL_SECONDS > deadline:
            notify(f"FLIM {version}", f"Stopped watching after the time limit. Still {WORDS.get(state, state)}.")
            return
        if time.time() + POLL_SECONDS - started > RUN_BUDGET_SECONDS:
            hand_off(deadline, last, version)
            return
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
