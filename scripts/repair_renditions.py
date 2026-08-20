#!/usr/bin/env python3
"""Backfill missing photo renditions server-side.

A photo with no thumb or feed rendition falls back to its full master EVERYWHERE it renders, on
every view, forever: a grid cell that should cost ~80kB costs ~1.25MB. Renditions are uploaded
after the photo row exists, with two retries three seconds apart, so a kill, a background, or a
dropout loses them for good, and the app's own opportunistic repair only reaches photos their
owner looks at again on a healthy connection. This closes the rest from the server side.

Per photo missing either rendition:
  1. If an object already exists at the deterministic path (the row patch was lost, not the
     upload), just patch the column.
  2. Otherwise download the master, resize with Lanczos to the app's exact spec
     (thumb 500px long edge JPEG q80, feed 1400px q79), upload, patch.
Only ever fills NULL columns and never overwrites an existing object: rerunning is a no-op.

Run:  SUPABASE_MGMT_TOKEN=sbp_... .venv/bin/python scripts/repair_renditions.py [--dry-run]
"""
import io
import json
import os
import sys
import urllib.request
import urllib.error

from PIL import Image, ImageOps

# api.supabase.com sits behind Cloudflare, which rejects Python's default User-Agent outright
# (403, error code 1010). Any real-looking agent passes.
_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", "flim-repair/1.0")]
urllib.request.install_opener(_opener)

REF = "wxvwamwrjlrvqmuaafjv"
MGMT = os.environ["SUPABASE_MGMT_TOKEN"]
SPECS = {"thumb": (500, 80), "feed": (1400, 79)}
DRY = "--dry-run" in sys.argv

def sql(query: str):
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": query}).encode(),
        headers={"Authorization": f"Bearer {MGMT}", "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

def service_key() -> str:
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/api-keys",
        headers={"Authorization": f"Bearer {MGMT}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        keys = json.load(r)
    return next(k["api_key"] for k in keys if k["name"] == "service_role")

KEY = service_key()
STORE = f"https://{REF}.supabase.co/storage/v1/object"

def storage(method: str, path: str, data=None, content_type=None):
    headers = {"Authorization": f"Bearer {KEY}", "apikey": KEY}
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

rows = sql("""
  select id, user_id, storage_path, thumb_path, feed_path
  from photos where thumb_path is null or feed_path is null
  order by taken_at""")

print(f"{len(rows)} photos need repair{' (dry run)' if DRY else ''}")
patched = uploaded = adopted = failed = 0
for row in rows:
    pid = row["id"].lower()
    uid = row["user_id"].lower()
    updates = {}
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
        sets = ", ".join(f"{k} = '{v}'" for k, v in updates.items())
        conds = " and ".join(f"{k} is null" for k in updates)   # never clobber a concurrent repair
        sql(f"update photos set {sets} where id = '{row['id']}' and {conds}")
        patched += 1

print(f"done: {patched} rows patched, {uploaded} renditions built, {adopted} orphans adopted, {failed} failures")
