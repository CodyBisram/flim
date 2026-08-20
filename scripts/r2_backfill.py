#!/usr/bin/env python3
"""Copy every photo object from Supabase Storage into R2, resumably.

NOT RUNNABLE until the owner creates the R2 bucket and an API token; see docs/R2_MIGRATION.md.
Copies master + thumb + feed for each photo, oldest first, then stamps photos.r2_migrated_at.
Idempotent: objects already in R2 are skipped, so it can be stopped and rerun freely, and readers
never notice because nothing reads from R2 until the stamp exists AND the client flag is on.

Run:
  SUPABASE_MGMT_TOKEN=sbp_... \
  R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
  .venv/bin/python scripts/r2_backfill.py [--limit N]

Requires: pip install boto3
"""
import io
import json
import os
import sys
import urllib.request

import boto3

REF = "wxvwamwrjlrvqmuaafjv"
BUCKET = "flim-photos"
MGMT = os.environ["SUPABASE_MGMT_TOKEN"]
LIMIT = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None

_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", "flim-r2-backfill/1.0")]
urllib.request.install_opener(_opener)

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
        return next(k["api_key"] for k in json.load(r) if k["name"] == "service_role")

KEY = service_key()

def download(path: str) -> bytes | None:
    req = urllib.request.Request(
        f"https://{REF}.supabase.co/storage/v1/object/photos/{path}",
        headers={"Authorization": f"Bearer {KEY}", "apikey": KEY})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()
    except urllib.error.HTTPError:
        return None

r2 = boto3.client("s3",
    endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
    aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"])

def in_r2(path: str) -> bool:
    try:
        r2.head_object(Bucket=BUCKET, Key=path)
        return True
    except Exception:
        return False

rows = sql(f"""
  select id, storage_path, thumb_path, feed_path from photos
  where r2_migrated_at is null order by taken_at
  {f'limit {LIMIT}' if LIMIT else ''}""")
print(f"{len(rows)} photos to migrate")
done = failed = 0
for row in rows:
    paths = [p for p in (row["storage_path"], row["thumb_path"], row["feed_path"]) if p]
    ok = True
    for path in paths:
        if in_r2(path):
            continue
        data = download(path)
        if data is None:
            print(f"  MISSING in Supabase: {path}")
            ok = False
            continue
        r2.put_object(Bucket=BUCKET, Key=path, Body=data,
                      ContentType="image/jpeg" if path.endswith(("jpg", "jpeg")) else "application/octet-stream")
    if ok:
        sql(f"update photos set r2_migrated_at = now() where id = '{row['id']}' and r2_migrated_at is null")
        done += 1
    else:
        failed += 1
print(f"done: {done} migrated, {failed} incomplete (rerun to retry)")
