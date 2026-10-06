#!/usr/bin/env python3
"""Runs one send-one-shot-push campaign for a scheduled workflow and tells the owner how it went.

Used by .github/workflows/founding-full.yml and spotlight-weekly.yml. The function claims each
person in its ledger BEFORE it pushes them, so a person whose push failed is claimed for good and
no rerun will reach them. That is the ledger's chosen direction, and it is why this script never
treats "nothing was sent" as quiet: whenever a run claimed someone it did not reach, or the
function did not answer cleanly enough to know, the owner gets a FLIM push (notify-owner) and the
job fails. The owner does not read GitHub email, so the push is the alarm.

Outcomes, read from the function's JSON reply (`claimed`, `sent`, `failed`, `ledger`; an older
deployment without `claimed` is read as sent + failed):

  answered, failed == 0     report (when anything was claimed, or with --always-report); exit 0
  answered, failed > 0      push the owner the counts; exit 1. With --partial-ok (a recurring
                            campaign, where a dead phone or two is normal and next week's claim
                            starts fresh) a run that reached SOMEONE is reported with its
                            not-reached count and exits 0; reaching nobody still fails.
  error reply, claimed: 0   the function says nobody was claimed; push only with
                            --notify-on-clean-error (a half-hourly caller would repeat it); exit 1
  anything else             unknown whether anyone was claimed; push the owner; exit 1

Writes sent, failed and claimed to $GITHUB_OUTPUT for later steps. A push to the owner is tried
three times; if it never lands the job fails, so a lost alarm is at least a red run.

Environment: ONE_SHOT_PUSH_SECRET, OWNER_NOTIFY_SECRET, FUNCTIONS_URL (".../functions/v1").
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

NOTIFY_ATTEMPTS = 3
NOTIFY_BACKOFF_SECONDS = (5, 20)
CALL_TIMEOUT_SECONDS = 400   # a campaign pushes people one by one; the platform cuts it off first


def notify(title, body):
    """Pushes the owner. True once it lands; False after every attempt failed."""
    request = urllib.request.Request(
        f"{os.environ['FUNCTIONS_URL']}/notify-owner", method="POST",
        data=json.dumps({"title": title, "body": body}).encode(),
        headers={"content-type": "application/json",
                 "x-owner-notify-secret": os.environ["OWNER_NOTIFY_SECRET"]})
    for attempt in range(1, NOTIFY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                print(f"notified owner: {response.read().decode()[:200]}")
                return True
        except Exception as error:   # retried below; the caller fails the job if all fail
            print(f"notify attempt {attempt} failed: {error}")
            if attempt < NOTIFY_ATTEMPTS:
                time.sleep(NOTIFY_BACKOFF_SECONDS[min(attempt - 1, len(NOTIFY_BACKOFF_SECONDS) - 1)])
    print("::error::could not notify the owner")
    return False


def call(campaign, send):
    """(HTTP status or None, parsed JSON reply or None, raw text)."""
    url = f"{os.environ['FUNCTIONS_URL']}/send-one-shot-push?campaign={campaign}"
    if send:
        url += "&send=true"
    request = urllib.request.Request(url, headers={"x-one-shot-secret": os.environ["ONE_SHOT_PUSH_SECRET"]})
    try:
        with urllib.request.urlopen(request, timeout=CALL_TIMEOUT_SECONDS) as response:
            status, text = response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        status, text = error.code, error.read().decode(errors="replace")
    except Exception as error:   # no answer at all: a timeout may have landed mid-run
        return None, None, str(error)
    try:
        reply = json.loads(text)
    except ValueError:
        reply = None
    return status, reply if isinstance(reply, dict) else None, text


def output(**values):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def people(n):
    return "1 person" if n == 1 else f"{n} people"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--campaign", required=True)
    parser.add_argument("--label", required=True, help="the campaign's name in the owner's push")
    parser.add_argument("--dry-run", action="store_true", help="resolve and print; send and notify nothing")
    parser.add_argument("--success-title", help="title of the report when it went out")
    parser.add_argument("--success-body", help="body of that report; {sent}, {people}, {variant} are filled in")
    parser.add_argument("--always-report", action="store_true", help="report even when nobody was claimed")
    parser.add_argument("--notify-on-clean-error", action="store_true",
                        help="push the owner even when the function says nobody was claimed")
    parser.add_argument("--after-failure", default="",
                        help="a sentence added to the push when people were claimed and not reached")
    parser.add_argument("--partial-ok", action="store_true",
                        help="a run that reached someone is a success, its misses counted in the report")
    args = parser.parse_args()

    status, reply, text = call(args.campaign, send=not args.dry_run)
    print(f"HTTP {status}: {text[:4000]}")

    if args.dry_run:
        if status != 200 or reply is None:
            print("::error::dry run failed")
            return 1
        print(f"dry run: would send to {reply.get('wouldSend')}")
        return 0

    answered = status is not None and 200 <= status < 300 and reply is not None and reply.get("dryRun") is False
    if answered:
        sent = int(reply.get("sent", 0))
        failed = int(reply.get("failed", 0))
        claimed = int(reply["claimed"]) if "claimed" in reply else sent + failed
        ledger = reply.get("ledger", args.campaign)
        output(sent=sent, failed=failed, claimed=claimed)
        print(f"ledger={ledger} claimed={claimed} sent={sent} failed={failed} skipped={reply.get('skipped', '?')}")
        if failed > 0 and not (args.partial_ok and sent > 0):
            ok = notify(f"{args.label}: {failed} not reached",
                        f"Claimed {people(claimed)}, reached {sent}. The other {failed} got nothing and will not "
                        f"be retried: their claims under {ledger} have no sent_at. {args.after_failure}".strip())
            print(f"::error::{failed} claimed but not delivered" + ("" if ok else ", and the owner was not told"))
            return 1
        if claimed > 0 or args.always_report:
            copy = (reply.get("copy") or [{}])[0]
            variant = copy.get("variant", "?")
            title = args.success_title or f"{args.label} sent"
            body = (args.success_body or "Went to {people}.").format(sent=sent, people=people(sent), variant=variant)
            if failed > 0:
                body += f" {failed} couldn't be reached."
            if claimed == 0:
                title, body = f"{args.label}: nobody new", "Nobody new to send to this time."
            return 0 if notify(title, body) else 1
        print("nothing claimed, nothing sent")
        return 0

    output(sent=0, failed=0, claimed=reply.get("claimed", "unknown") if reply else "unknown")
    if reply is not None and reply.get("claimed") == 0:
        print(f"::error::{args.campaign} failed before claiming anyone: {reply.get('error')}")
        if args.notify_on_clean_error:
            notify(f"{args.label} did not go out",
                   f"It failed before contacting anyone ({str(reply.get('error'))[:120]}). Nobody was claimed, "
                   "so it is safe to run again.")
        return 1
    print(f"::error::{args.campaign} gave no clean answer; some people may be claimed and not reached")
    notify(f"{args.label} may have failed",
           f"The push function answered {status or 'nothing'}, so some people may be claimed without a push. "
           f"Check one_shot_push rows starting {args.campaign}.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
