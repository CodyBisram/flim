#!/usr/bin/env python3
"""Keeps an App Store review watch alive when its chain of runs breaks.

Run hourly by .github/workflows/asc-watch-backstop.yml, which every asc-watch run switches on.
The watch (scripts/asc_watch.py) is a chain of runs, each dispatching the next before the 6h job
limit; on 2026-10-05 one dispatched run was never picked up by a runner, failed, and the chain
ended without the "live" push. This reads asc-watch's own run history, which is the only state the
watch has: every run's inputs (version, deadline, hours, last state, stop) are in its run name.

  a run queued or in progress           the watch is alive: nothing to do
  newest run succeeded or was cancelled the watch ended on purpose (final state, time limit,
                                        hand-off already seen, or the owner cancelled it):
                                        switch this backstop off
  newest run failed, before deadline    start the next run from that run's inputs; after
                                        GIVE_UP_AFTER failures in a row, start a stop run instead,
                                        which tells the owner and ends the watch
  newest run failed, deadline passed    one stop run, so the owner hears the watch ended; a stop
                                        run that itself failed is left alone

Environment: GH_TOKEN (actions: write), GITHUB_REPOSITORY.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

WATCH_WORKFLOW = "asc-watch.yml"
SELF_WORKFLOW = "asc-watch-backstop.yml"
ALIVE = {"queued", "in_progress", "requested", "waiting", "pending"}
FAILED = {"failure", "timed_out", "startup_failure"}
GIVE_UP_AFTER = 3
FIELDS = ("version", "deadline", "hours", "last", "stop")


def parse_title(title):
    """The inputs asc-watch.yml writes into its run name, or None for a run from before that."""
    if not title or "deadline=" not in title:
        return None
    found = dict(re.findall(r"\b(version|deadline|hours|last|stop)=(\S*)", title))
    return {key: found.get(key, "") for key in FIELDS}


def created_epoch(run):
    return int(datetime.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00")).timestamp())


def deadline_of(run, inputs):
    if inputs["deadline"].isdigit():
        return int(inputs["deadline"])
    try:
        hours = float(inputs["hours"] or 72)
    except ValueError:
        hours = 72.0
    return created_epoch(run) + int(hours * 3600)


def decide(runs, now):
    """What to do, from asc-watch's runs newest first: ("wait" | "off" | "resume" | "stop", detail)."""
    if any(r.get("status") in ALIVE for r in runs):
        return "wait", "a watch run is queued or in progress"
    if not runs:
        return "off", "no watch has ever run"
    newest = runs[0]
    conclusion = newest.get("conclusion")
    if conclusion not in FAILED:
        return "off", f"the newest run ended {conclusion}: the watch is over"
    inputs = parse_title(newest.get("display_title", ""))
    if inputs is None:
        return "off", "the newest run predates run-name inputs; nothing to resume from"
    deadline = deadline_of(newest, inputs)
    plan = {"version": inputs["version"], "deadline": str(deadline), "last_state": inputs["last"]}
    if now >= deadline - 60:
        if inputs["stop"] == "true":
            return "off", "the deadline has passed and the last stop run failed too"
        return "stop", {**plan, "reason": "The last run failed and the time limit has now passed."}
    failures = 0
    for run in runs:
        if run.get("conclusion") not in FAILED:
            break
        failures += 1
    if failures >= GIVE_UP_AFTER:
        return "stop", {**plan, "reason": f"Its last {failures} runs failed."}
    return "resume", plan


def gh(*args):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    return result.stdout


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    runs = json.loads(gh("api", f"repos/{repo}/actions/workflows/{WATCH_WORKFLOW}/runs?per_page=30"))["workflow_runs"]
    runs.sort(key=lambda r: (r["created_at"], r["id"]), reverse=True)
    action, detail = decide(runs, int(time.time()))
    print(f"{action}: {detail}")
    if action == "off":
        gh("workflow", "disable", SELF_WORKFLOW, "--repo", repo)
        print("backstop switched off; the next asc-watch run switches it back on")
    elif action in ("resume", "stop"):
        fields = ["-f", f"version={detail['version']}", "-f", f"deadline={detail['deadline']}",
                  "-f", f"last_state={detail['last_state']}"]
        if action == "stop":
            fields += ["-f", "stop=true", "-f", f"stop_reason={detail['reason']}"]
        gh("workflow", "run", WATCH_WORKFLOW, "--repo", repo, *fields)
        print(f"dispatched {WATCH_WORKFLOW}: {' '.join(fields[1::2])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
