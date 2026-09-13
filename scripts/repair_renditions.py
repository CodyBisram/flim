#!/usr/bin/env python3
"""Backfill missing photo renditions server-side.

A photo with no thumb or feed rendition falls back to its full master EVERYWHERE it renders, on
every view, forever: a grid cell that should cost ~80kB costs ~1.25MB. Renditions are uploaded
after the photo row exists, with two retries three seconds apart, so a kill, a background, or a
dropout loses them for good, and the app's own opportunistic repair only reaches photos their
owner looks at again on a healthy connection. This closes the rest from the server side, and
since 2026-09-13 runs nightly inside .github/workflows/nightly-numbers.yml (49 photos across 12
people had piled up in three weeks before that).

Per photo missing either rendition and older than an hour (younger ones may still be mid-upload):
  1. If an object already exists at the deterministic path (the row patch was lost, not the
     upload), just patch the column.
  2. Otherwise download the master, resize with Lanczos to the app's exact spec
     (thumb 500px long edge JPEG q80, feed 1400px q79), upload, patch.
  3. A row whose master does not exist either is reported as NO MASTER and left alone; that is
     a blank frame nothing can rebuild, and deleting a row is the owner's call.
Only ever fills NULL columns and never overwrites an existing object: rerunning is a no-op.

Run:  FLIM_SERVICE_KEY=... .venv/bin/python scripts/repair_renditions.py [--dry-run]
(locally, `source ~/.claude/flim-r2-watch.env` provides the key; CI has it as a secret)
"""
import io
import json
import os
import sys
import urllib.request
import urllib.error
from PIL import Image, ImageOps

REF = "wxvwamwrjlrvqmuaafjv"
KEY = os.environ["FLIM_SERVICE_KEY"]
SPECS = {"thumb": (500, 80), "feed": (1400, 79)}
DRY = "--dry-run" in sys.argv
REST = f"https://{REF}.supabase.co/rest/v1"
STORE = f"https://{REF}.supabase.co/storage/v1/object"
AUTH = {"Authorization": f"Bearer {KEY}", "apikey": KEY}

def rest(method: str, path: str, body=None, prefer=None):
    headers = dict(AUTH, **{"Content-Type": "application/json"})
    if prefer:
        headers["Prefer"] = prefer
    req = urllib.request.Request(f"{REST}/{path}", data=json.dumps(body).encode() if body is not None else None,
                                 headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None

def storage(method: str, path: str, data=None, content_type=None):
    headers = dict(AUTH)
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(f"{STORE}/photos/{path}", data=data, headers=headers, method=method)
    return urllib.request.urlopen(req, timeout=120)

def exists(path: str) -> bool:
    try:
        storage("HEAD", path).close()
        return True
    except urllib.error.HTTPError:
        return False

def download(path: str) -> bytes:
    with storage("GET", path) as r:
        return r.read()

def make_rendition(master: bytes, long_edge: int, quality: int) -> bytes:
    img = ImageOps.exif_transpose(Image.open(io.BytesIO(master))).convert("RGB")
    w, h = img.size
    scale = long_edge / max(w, h)
    if scale < 1:
        img = img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=quality)
    return out.getvalue()

import datetime
import urllib.parse
cutoff = urllib.parse.quote((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).isoformat())
rows = rest("GET", "photos?select=id,user_id,storage_path,thumb_path,feed_path"
                   f"&or=(thumb_path.is.null,feed_path.is.null)&taken_at=lt.{cutoff}&order=taken_at")

print(f"{len(rows)} photos need repair{' (dry run)' if DRY else ''}")
patched = uploaded = adopted = failed = 0
no_master = []
for row in rows:
    pid = row["id"].lower()
    uid = row["user_id"].lower()
    updates = {}
    if not exists(row["storage_path"]):
        no_master.append(row["id"])
        print(f"  NO MASTER {row['storage_path']}")
        continue
    for kind in ("thumb", "feed"):
        if row[f"{kind}_path"] is not None:
            continue
        target = f"{uid}/{pid}_{kind}.jpg"
        try:
            if exists(target):
                updates[f"{kind}_path"] = target      # orphaned object: adopt it
                adopted += 1
                continue
            if DRY:
                print(f"  would build {target}")
                continue
            long_edge, quality = SPECS[kind]
            master = download(row["storage_path"])
            data = make_rendition(master, long_edge, quality)
            storage("POST", target, data=data, content_type="image/jpeg").close()
            updates[f"{kind}_path"] = target
            uploaded += 1
        except Exception as e:
            print(f"  FAILED {target}: {e}")
            failed += 1
    if updates and not DRY:
        conds = "&".join(f"{k}=is.null" for k in updates)   # never clobber a concurrent repair
        rest("PATCH", f"photos?id=eq.{row['id']}&{conds}", updates, prefer="return=minimal")
        patched += 1

print(f"done: {patched} rows patched, {uploaded} renditions built, {adopted} orphans adopted, "
      f"{failed} failures, {len(no_master)} with no master")
sys.exit(1 if failed or no_master else 0)
