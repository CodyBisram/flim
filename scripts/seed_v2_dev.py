#!/usr/bin/env python3
"""Seed FLIM Dev (FLIM Beta's server) with something real to test v2 against.

What it does, and nothing else:
  1. READS the owner's own recent posts from production (GET only; this script refuses any other
     method against production) and copies their feed and thumbnail renditions, captions and
     dates onto the owner's FLIM Dev account. Nobody else's data leaves production.
  2. Makes six made-up people on FLIM Dev (emails at test.invalid), with photos from the repo's
     own sample images: four are friends with the owner, one has asked, one the owner has asked.
  3. Gives them posts over the last ten days, reactions and a comment thread on the owner's
     prints, a roll that developed yesterday and one still developing.

Everything it makes is written to ~/.flim-v2-seed.json, and `--reset` removes exactly that.
Runs on the owner's Mac (macOS `sips` resizes the sample images).

Keys, read from files, never printed:
  ~/.flim-service-key       production service key (read only here)
  ~/.flim-v2-service-key    FLIM Dev service key (Dashboard > FLIM Dev > Settings > API keys)

Usage:
  python3 -I scripts/seed_v2_dev.py              # seed (copies up to 60 of your posts)
  python3 -I scripts/seed_v2_dev.py --posts 120  # copy more
  python3 -I scripts/seed_v2_dev.py --no-prod    # made-up people only
  python3 -I scripts/seed_v2_dev.py --reset      # remove everything a seed made
"""
import argparse
import datetime as dt
import json
import os
import random
import re
import string
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

PROD_REF = "wxvwamwrjlrvqmuaafjv"
DEV_REF = "kwhgbrdznaogkdyqitvi"
assert PROD_REF != DEV_REF
PROD = f"https://{PROD_REF}.supabase.co"
DEV = f"https://{DEV_REF}.supabase.co"
OWNER_PROD_ID = "f43287d4-f239-415b-af45-650bbee62e83"
MANIFEST = Path.home() / ".flim-v2-seed.json"
REPO = Path(__file__).resolve().parent.parent
PATH_SHAPE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]+\.(jpe?g|heic|png)$")

PEOPLE = [
    # username, display name, relation to the owner
    ("nadia", "Nadia", "friend"),
    ("gem", "Gem", "friend"),
    ("dev.k", "Dev", "friend"),
    ("noor", "Noor", "friend"),
    ("mari", "Mari", "asked_owner"),     # follows the owner; the owner has not followed back
    ("theo", "Theo", "owner_asked"),     # the owner follows them; they have not followed back
]
CAPTIONS = ["the walk back", "first light", "kitchen, late", "rooftop", "found this", "sunday",
            "after the rain", "train window", "too much flash", "", "", "", "the good table", "home"]
COMMENTS = ["this one!!", "where is this", "the light here", "need this framed", "ok wow", "when was this"]
REPLIES = ["last weekend", "right by the station", "you were there lol"]
EMOJIS = ["❤️", "🔥", "😂", "😍", "🙌"]


def key(name: str) -> str:
    p = Path.home() / name
    if not p.exists():
        sys.exit(f"missing {p}. See the top of this script.")
    return p.read_text().strip()


def request(base: str, k: str, method: str, path: str, body=None, headers=None, raw=False):
    if base == PROD and method != "GET":
        raise SystemExit("refusing a write to production")
    h = {"apikey": k, "Authorization": f"Bearer {k}"}
    data = None
    if body is not None and not isinstance(body, (bytes, bytearray)):
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    elif body is not None:
        data = body
    h.update(headers or {})
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise SystemExit(f"{method} {path.split('?')[0]} failed: {e.code} {detail}")
    if raw:
        return out
    return json.loads(out) if out else None


class Dev:
    def __init__(self, k):
        self.k = k

    def insert(self, table, rows):
        if rows:
            request(DEV, self.k, "POST", f"/rest/v1/{table}", rows, {"Prefer": "return=minimal"})

    def select(self, table, query):
        return request(DEV, self.k, "GET", f"/rest/v1/{table}?{query}")

    def delete(self, table, query):
        request(DEV, self.k, "DELETE", f"/rest/v1/{table}?{query}", headers={"Prefer": "return=minimal"})

    def upload(self, path, data):
        assert PATH_SHAPE.match(path), path
        request(DEV, self.k, "POST", f"/storage/v1/object/photos/{path}", data,
                {"Content-Type": "image/jpeg", "x-upsert": "true"})

    def remove(self, paths):
        for i in range(0, len(paths), 100):
            request(DEV, self.k, "DELETE", "/storage/v1/object/photos", {"prefixes": paths[i:i + 100]})


def resized(src: Path, long_edge: int) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "out.jpg"
        subprocess.run(["sips", "-Z", str(long_edge), "-s", "format", "jpeg", "-s", "formatOptions", "80",
                        str(src), "--out", str(out)], check=True, capture_output=True)
        return out.read_bytes()


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).isoformat()


def new_photo(dev, manifest, user_id, image: bytes, thumb: bytes, taken: dt.datetime, roll_id=None,
              develops=None, caption=None, sorted_=True):
    pid = str(uuid.uuid4())
    feed_path = f"{user_id}/{pid}_feed.jpg"
    thumb_path = f"{user_id}/{pid}_thumb.jpg"
    dev.upload(feed_path, image)
    dev.upload(thumb_path, thumb)
    manifest["paths"] += [feed_path, thumb_path]
    dev.insert("photos", [{
        "id": pid, "user_id": user_id, "roll_id": roll_id, "storage_path": feed_path, "feed_path": feed_path,
        "thumb_path": thumb_path, "taken_at": iso(taken), "develops_at": iso(develops or taken),
        "is_developed": (develops or taken) <= dt.datetime.now(dt.timezone.utc),
        # As the app (PhotoService: isSorted = rollId != nil): a roll shot never enters the sort
        # deck; a personal one is unsorted until sorted. Pass sorted_=False for the deck.
        "is_sorted": True if roll_id else sorted_,
        "caption": caption, "push_sent": True,
    }])
    manifest["photos"].append(pid)
    return pid


def post(dev, manifest, user_id, photo_id, taken, caption, created=None):
    post_id = str(uuid.uuid4())
    dev.insert("posts", [{"id": post_id, "user_id": user_id, "photo_id": photo_id,
                          "storage_path": f"{user_id}/{photo_id}_feed.jpg", "taken_at": iso(taken),
                          "created_at": iso(created or taken), "caption": caption or None, "push_sent": True}])
    manifest["posts"].append(post_id)
    return post_id


def seed(args):
    dev = Dev(key(".flim-v2-service-key"))
    if MANIFEST.exists():
        sys.exit(f"{MANIFEST} exists: a seed is already in place. Run --reset first.")
    owner = dev.select("users", "select=id,username&username=eq." + urllib.parse.quote(args.dev_user))
    if not owner:
        sys.exit(f"no FLIM Dev account named {args.dev_user}; sign in to FLIM Beta once first")
    owner_id = owner[0]["id"]
    manifest = {"owner": owner_id, "users": [], "photos": [], "posts": [], "rolls": [], "paths": []}
    now = dt.datetime.now(dt.timezone.utc)
    rng = random.Random(7)

    try:
        # 1. The owner's own posts, from production (reads only).
        if not args.no_prod:
            pk = key(".flim-service-key")
            rows = request(PROD, pk, "GET",
                           f"/rest/v1/posts?select=photo_id,taken_at,created_at,caption,feed_path,thumb_path"
                           f"&user_id=eq.{OWNER_PROD_ID}&hidden=eq.false"
                           f"&order=taken_at.desc&limit={args.posts}")
            copied = 0
            for r in rows:
                fp, tp = r.get("feed_path"), r.get("thumb_path")
                if not fp or not PATH_SHAPE.match(fp) or not fp.startswith(OWNER_PROD_ID + "/"):
                    continue
                feed = request(PROD, pk, "GET", f"/storage/v1/object/photos/{fp}", raw=True)
                thumb = feed
                if tp and PATH_SHAPE.match(tp) and tp.startswith(OWNER_PROD_ID + "/"):
                    thumb = request(PROD, pk, "GET", f"/storage/v1/object/photos/{tp}", raw=True)
                taken = dt.datetime.fromisoformat(r["taken_at"])
                pid = new_photo(dev, manifest, owner_id, feed, thumb, taken)
                post(dev, manifest, owner_id, pid, taken, r.get("caption"),
                     dt.datetime.fromisoformat(r["created_at"]) if r.get("created_at") else taken)
                copied += 1
            print(f"copied {copied} of your posts")
            save(manifest)

        # 2. Six made-up people.
        images = sorted((REPO / "pairs").glob("*_lapse.jpg"))
        if not images:
            sys.exit("no sample images in pairs/")
        prepared = [(resized(p, 1400), resized(p, 500)) for p in images]
        people = {}
        for username, display, relation in PEOPLE:
            email = f"{username.replace('.', '')}.seed@test.invalid"
            dev.insert("allowed_emails", [{"email": email, "note": "v2 seed, remove with --reset"}])
            made = request(DEV, dev.k, "POST", "/auth/v1/admin/users", {"email": email, "email_confirm": True})
            uid = made["id"]
            manifest["users"].append({"id": uid, "email": email})
            save(manifest)
            code = "".join(rng.choice(string.ascii_uppercase + string.digits) for _ in range(6))
            dev.insert("users", [{"id": uid, "email": email, "username": username, "display_name": display,
                                  "invite_code": code}])
            people[username] = uid
            if relation in ("friend", "asked_owner"):
                dev.insert("follows", [{"follower_id": uid, "following_id": owner_id, "push_sent": True}])
            if relation in ("friend", "owner_asked"):
                dev.insert("follows", [{"follower_id": owner_id, "following_id": uid, "push_sent": True}])
        # The friends know each other too.
        friends = [people[u] for u, _, rel in PEOPLE if rel == "friend"]
        dev.insert("follows", [{"follower_id": a, "following_id": b, "push_sent": True}
                               for a in friends for b in friends if a != b])

        # 3. Their posts over the last ten days, in bursts of an evening.
        for username, uid in people.items():
            for _ in range(rng.randint(3, 6)):
                taken = now - dt.timedelta(days=rng.uniform(0, 10), hours=rng.uniform(0, 3))
                feed, thumb = rng.choice(prepared)
                pid = new_photo(dev, manifest, uid, feed, thumb, taken)
                post(dev, manifest, uid, pid, taken, rng.choice(CAPTIONS))
        save(manifest)

        # Reactions and a thread on the owner's newest prints.
        owner_posts = dev.select("posts", f"select=id&user_id=eq.{owner_id}&order=taken_at.desc&limit=10")
        for i, p in enumerate(owner_posts):
            for uid in rng.sample(friends, k=rng.randint(1, len(friends))):
                dev.insert("post_reactions", [{"post_id": p["id"], "user_id": uid, "emoji": rng.choice(EMOJIS),
                                               "push_sent": True}])
            if i < 4:
                cid = str(uuid.uuid4())
                author = rng.choice(friends)
                dev.insert("post_comments", [{"id": cid, "post_id": p["id"], "user_id": author,
                                              "body": rng.choice(COMMENTS), "push_sent": True}])
                if i < 2:
                    dev.insert("post_comments", [{"post_id": p["id"], "user_id": owner_id, "parent_id": cid,
                                                  "body": rng.choice(REPLIES), "push_sent": True}])

        # A roll that developed yesterday, and one still developing.
        for name, reveal, members, shots in [("Lake weekend", now - dt.timedelta(hours=20), friends[:3], 12),
                                             ("Friday dinner", now + dt.timedelta(hours=20), friends[1:3], 5)]:
            rid = str(uuid.uuid4())
            code = "".join(rng.choice(string.ascii_uppercase + string.digits) for _ in range(6))
            dev.insert("rolls", [{"id": rid, "name": name, "invite_code": code, "created_by": owner_id,
                                  "created_at": iso(reveal - dt.timedelta(hours=40)), "reveal_at": iso(reveal)}])
            manifest["rolls"].append(rid)
            everyone = [owner_id] + members
            dev.insert("roll_members", [{"roll_id": rid, "user_id": u} for u in everyone])
            roll_photos = []
            for _ in range(shots):
                uid = rng.choice(everyone)
                taken = reveal - dt.timedelta(hours=rng.uniform(14, 38))
                feed, thumb = rng.choice(prepared)
                roll_photos.append(new_photo(dev, manifest, uid, feed, thumb, taken, roll_id=rid, develops=reveal))
            if reveal <= now:
                for ph in roll_photos[:5]:
                    dev.insert("photo_reactions", [{"photo_id": ph, "user_id": rng.choice(everyone),
                                                    "emoji": rng.choice(EMOJIS), "push_sent": True}])
                dev.insert("photo_comments", [{"photo_id": roll_photos[0], "user_id": members[0],
                                               "body": "best one of the weekend", "push_sent": True}])
            save(manifest)
    finally:
        save(manifest)
    print(f"seeded: {len(manifest['users'])} people, {len(manifest['posts'])} posts, "
          f"{len(manifest['rolls'])} rolls. Remove with --reset.")


def save(manifest):
    MANIFEST.write_text(json.dumps(manifest, indent=1))
    os.chmod(MANIFEST, 0o600)


def reset(_args):
    if not MANIFEST.exists():
        sys.exit("nothing to reset")
    dev = Dev(key(".flim-v2-service-key"))
    m = json.loads(MANIFEST.read_text())
    for rid in m["rolls"]:
        dev.delete("rolls", f"id=eq.{rid}")
    for i in range(0, len(m["posts"]), 50):
        dev.delete("posts", "id=in.(" + ",".join(m["posts"][i:i + 50]) + ")")
    for i in range(0, len(m["photos"]), 50):
        dev.delete("photos", "id=in.(" + ",".join(m["photos"][i:i + 50]) + ")")
    for u in m["users"]:
        dev.delete("users", f"id=eq.{u['id']}")
        try:
            request(DEV, dev.k, "DELETE", f"/auth/v1/admin/users/{u['id']}")
        except SystemExit as e:
            print(f"note: {e}")
        dev.delete("allowed_emails", "email=eq." + urllib.parse.quote(u["email"]))
    if m["paths"]:
        dev.remove(m["paths"])
    MANIFEST.unlink()
    print(f"removed {len(m['users'])} people, {len(m['posts'])} posts, {len(m['photos'])} photos, "
          f"{len(m['rolls'])} rolls")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--no-prod", action="store_true", help="skip copying your production posts")
    ap.add_argument("--posts", type=int, default=60)
    ap.add_argument("--dev-user", default="cody", help="your FLIM Dev username")
    a = ap.parse_args()
    (reset if a.reset else seed)(a)
