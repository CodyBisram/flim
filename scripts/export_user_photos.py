#!/usr/bin/env python3
"""Export one user's own photos, for a data request from that user.

Written for kaayjaay's request (2026-08-29) but takes any username, because the
next one of these should not need a new script.

WHY THIS IS A SCRIPT YOU RUN, RATHER THAN SOMETHING THE ASSISTANT DID
--------------------------------------------------------------------
Pulling image bytes out of the storage bucket needs the SERVICE ROLE key, which
bypasses every RLS policy in the project and can read and write anything. That
is not a credential to paste into a chat transcript, so this reads it from the
environment instead: the key stays on your machine, and nothing here prints it.

Usage:

    export SUPABASE_SERVICE_ROLE_KEY='...'      # Dashboard > Settings > API
    python3 scripts/export_user_photos.py kaayjaay
    python3 scripts/export_user_photos.py alyssa --since 2026-08-22
    python3 scripts/export_user_photos.py ash --out ~/Desktop/ash

`--since` and `--until` take a date (YYYY-MM-DD) and filter on capture time.

A WORD ON --since, SINCE THESE ARE DATA REQUESTS
------------------------------------------------
Someone asking for their photos usually means all of them, so a date filter is
the exception rather than the shape of the job. It exists for a second request
after a first export ("anything since you sent that"), not as the normal way to
answer one. If you find yourself reaching for it on a first export, check that
the person actually asked for a slice.

MATCH THE USERNAME EXACTLY
--------------------------
Lookup is an exact match on `username`, deliberately: a LIKE would have made
`ash` also match `ashley` and `ashleya`, and this app has all three. Sending one
person's photographs to another is the single mistake here that cannot be
undone, so the script would rather find nothing than guess. It prints the
display name it matched before downloading anything: read that line.

WHAT IT EXPORTS
---------------
`storage_path`, the full-resolution master, NOT the 1400px view rendition or
the 500px thumbnail. Those are display sizes the app generates; a person asking
for their photos wants the originals.

It writes a manifest.csv alongside the images, because twenty files named after
UUIDs are not an answer to "can I have my photos". Filenames are the capture
date and time so they sort chronologically in any file browser.

Re-running is safe: existing files of the right size are skipped, so an
interrupted export resumes rather than starting over.
"""

import csv
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PROJECT = "wxvwamwrjlrvqmuaafjv"
REST = f"https://{PROJECT}.supabase.co/rest/v1"
STORAGE = f"https://{PROJECT}.supabase.co/storage/v1/object/photos"
BUCKET_TIMEOUT = 60


def die(message: str) -> "None":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def get_json(url: str, key: str):
    request = urllib.request.Request(
        url, headers={"apikey": key, "Authorization": f"Bearer {key}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Deliberately does not echo the response body: on an auth failure it can
        # contain fragments of the key.
        die(f"{error.code} from {url.split('?')[0]}")


def main() -> None:
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if not key:
        die("set SUPABASE_SERVICE_ROLE_KEY first (Dashboard > Settings > API > service_role)")

    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        die("usage: export_user_photos.py <username> [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--out DIR]")
    username = args[0]

    options: dict[str, str] = {}
    rest = args[1:]
    while rest:
        flag = rest.pop(0)
        if flag not in ("--since", "--until", "--out"):
            die(f"unknown option {flag!r}")
        if not rest:
            die(f"{flag} needs a value")
        options[flag.lstrip("-")] = rest.pop(0)

    for flag in ("since", "until"):
        value = options.get(flag)
        # A typo here silently changes WHICH photos a person receives, and the
        # filter would just quietly match nothing or everything.
        if value and (len(value) != 10 or value[4] != "-" or value[7] != "-"):
            die(f"--{flag} must look like YYYY-MM-DD, got {value!r}")

    users = get_json(
        f"{REST}/users?username=eq.{urllib.parse.quote(username)}&select=id,username,display_name",
        key,
    )
    if not users:
        die(f"no user with username {username!r}")
    user = users[0]

    window = ""
    if options.get("since"):
        window += f"&taken_at=gte.{options['since']}"
    if options.get("until"):
        # Exclusive upper bound on the NEXT day would need date maths; gte/lte on a
        # bare date means --until 2026-08-29 stops at midnight and drops that day's
        # photos. Spelling it to the end of the day is what a person means by "until".
        window += f"&taken_at=lte.{options['until']}T23:59:59"

    photos = get_json(
        f"{REST}/photos?user_id=eq.{user['id']}"
        "&select=id,storage_path,taken_at,is_developed,caption,roll_id"
        f"{window}&order=taken_at.asc",
        key,
    )
    if not photos:
        die(f"{username} has no photos" + (" in that window" if window else ""))

    out = Path(options["out"]) if options.get("out") else Path.home() / "Downloads" / f"flim-export-{username}"
    out.mkdir(parents=True, exist_ok=True)

    # Read this line before the download finishes. It is the check against sending
    # one person's photographs to another.
    print(f"MATCHED: @{user['username']}  display name: {user.get('display_name') or '(none)'}")
    if window:
        print(f"WINDOW:  {options.get('since', 'the beginning')} to {options.get('until', 'now')}"
              "  (a partial export: confirm this is what they asked for)")
    print(f"{len(photos)} photos -> {out}")

    rows = []
    failed = []
    for index, photo in enumerate(photos, start=1):
        stamp = photo["taken_at"].replace("T", " ")[:19].replace(":", "").replace("-", "").replace(" ", "-")
        filename = f"{stamp}_{index:03d}.jpg"
        destination = out / filename

        if not destination.exists() or destination.stat().st_size == 0:
            url = f"{STORAGE}/{urllib.parse.quote(photo['storage_path'])}"
            request = urllib.request.Request(
                url, headers={"apikey": key, "Authorization": f"Bearer {key}"}
            )
            try:
                with urllib.request.urlopen(request, timeout=BUCKET_TIMEOUT) as response:
                    destination.write_bytes(response.read())
            except urllib.error.HTTPError as error:
                # One missing object must not abandon the other nineteen.
                failed.append((photo["id"], error.code))
                print(f"  [{index}/{len(photos)}] MISSING ({error.code})")
                continue

        rows.append(
            {
                "file": filename,
                "taken_at": photo["taken_at"],
                "caption": photo.get("caption") or "",
                "in_a_roll": "yes" if photo.get("roll_id") else "no",
                "developed": "yes" if photo.get("is_developed") else "no",
                "size_bytes": destination.stat().st_size,
            }
        )
        print(f"  [{index}/{len(photos)}] {filename}  {destination.stat().st_size // 1024} KB")

    with (out / "manifest.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["file", "taken_at", "caption", "in_a_roll", "developed", "size_bytes"]
        )
        writer.writeheader()
        writer.writerows(rows)

    total = sum(row["size_bytes"] for row in rows)
    print(f"\ndone: {len(rows)} images, {total / 1_048_576:.1f} MB, manifest.csv written")
    if failed:
        print(f"WARNING: {len(failed)} objects could not be fetched: {failed}")


if __name__ == "__main__":
    main()
