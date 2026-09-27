#!/usr/bin/env python3
"""Sends the weekly outreach emails straight through Gmail's SMTP server.

    outreach_send.py --check                                  log in and out, send nothing
    outreach_send.py --send send.json --out result.json       send each email once
    outreach_send.py --send send.json --out result.json --dry  send every email to the owner

Why not the Gmail connector: it rewrites every link in a draft into an expiring
google.com/url redirect (found 2026-09-26, when the first batch's invite links broke a day after
sending). Mail handed to Gmail's SMTP server goes out exactly as written.

The address and an app password come from the environment (FLIM_GMAIL_ADDRESS,
FLIM_GMAIL_APP_PASSWORD, set by outreach-weekly.sh from ~/.config/flim-hooks.env), never from
the command line. Plain text only. Each email is sent once and never retried: a failure after
the server took the message may still have delivered it, so the run stops there and the caller
marks what follows as not sent. result.json is rewritten after every email, so a crash midway
still records what went. Standard library only, so it runs on the Pi as is.
"""
import argparse
import json
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from pathlib import Path

HOST, PORT = "smtp.gmail.com", 587
FROM_NAME = "Cody Bisram"


def credentials():
    address = os.environ.get("FLIM_GMAIL_ADDRESS", "").strip()
    password = os.environ.get("FLIM_GMAIL_APP_PASSWORD", "").replace(" ", "").strip()
    if not address or not password:
        sys.exit("no FLIM_GMAIL_ADDRESS or FLIM_GMAIL_APP_PASSWORD in the environment")
    return address, password


def connect(address, password):
    server = smtplib.SMTP(HOST, PORT, timeout=60)
    server.starttls(context=ssl.create_default_context())
    server.login(address, password)
    return server


def message(sender, to, subject, body):
    msg = EmailMessage()
    msg["From"] = formataddr((FROM_NAME, sender))
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=sender.split("@")[-1])
    msg.set_content(body)
    return msg


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true")
    p.add_argument("--send")
    p.add_argument("--out")
    p.add_argument("--dry", action="store_true")
    a = p.parse_args()
    address, password = credentials()

    if a.check:
        try:
            connect(address, password).quit()
        except Exception as error:
            sys.exit(f"Gmail SMTP login failed: {type(error).__name__}: {error}")
        print("GMAIL_OK")
        return

    if not a.send or not a.out:
        sys.exit("--send and --out are required")
    emails = json.loads(Path(a.send).read_text(encoding="utf-8"))
    results = []

    def record():
        Path(a.out).write_text(json.dumps({"results": results}), encoding="utf-8")

    record()
    try:
        server = connect(address, password)
    except Exception as error:
        for e in emails:
            results.append({"n": e["n"], "draft": "skipped", "sent": "skipped",
                            "error": f"login failed: {type(error).__name__}"})
        record()
        sys.exit(1)

    stopped = None
    for e in emails:
        if stopped:
            results.append({"n": e["n"], "draft": "skipped", "sent": "skipped",
                            "error": "not reached: an earlier send failed"})
            continue
        # A dry run sends each email to the owner instead, so what a recipient would get can be
        # read in the inbox; `draft` stays the field finalize reads for a dry run.
        to = address if a.dry else e["to"]
        try:
            server.send_message(message(address, to, e["subject"], e["body"]))
            results.append({"n": e["n"], "draft": "ok" if a.dry else "skipped",
                            "sent": "skipped" if a.dry else "ok", "error": ""})
        except Exception as error:
            stopped = error
            results.append({"n": e["n"], "draft": "fail" if a.dry else "skipped", "sent": "fail",
                            "error": f"{type(error).__name__}: {str(error)[:120]}"})
        record()
    record()
    try:
        server.quit()
    except Exception:
        pass
    sys.exit(1 if stopped else 0)


if __name__ == "__main__":
    main()
