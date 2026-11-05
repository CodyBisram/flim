#!/usr/bin/env python3
"""A signed-in test account on FLIM Dev, so FLIM Beta's screens can be driven end to end in the
simulator without a mailed code.

It uses the App Review address (review@flim-app.com), the one account the app signs in with a
password (AuthService.signInWithPassword). This is FLIM Dev only; production's review account is
untouched. The password is made here and kept in ~/.flim-v2-review-pass (never printed).

The account joins the made-up people `seed_v2_dev.py` made (run that first): four friends, one
asking, one asked. It gets posts, kept prints, prints waiting to be sorted, reactions and a thread from friends, membership of both seeded rolls with its own
shots in them, and two rolls of its own (one opened, one sealed) to leave, delete and invite into.

Everything it makes is listed in ~/.flim-v2-tester.json; `--reset` removes exactly that.

Usage:
  python3 -I scripts/seed_v2_tester.py
  python3 -I scripts/seed_v2_tester.py --reset
"""
import argparse
import datetime as dt
import json
import os
import random
import secrets
import string
import sys
import urllib.parse
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import seed_v2_dev as seed  # noqa: E402

EMAIL = "review@flim-app.com"
USERNAME = "tester"
MANIFEST = Path.home() / ".flim-v2-tester.json"
PASSWORD_FILE = Path.home() / ".flim-v2-review-pass"


def save(m):
    MANIFEST.write_text(json.dumps(m, indent=1))
    os.chmod(MANIFEST, 0o600)


def make(args):
    if MANIFEST.exists():
        sys.exit(f"{MANIFEST} exists: run --reset first.")
    dev = seed.Dev(seed.key(".flim-v2-service-key"))
    people = {u["username"]: u["id"] for u in dev.select(
        "users", "select=id,username&username=in.(nadia,gem,dev.k,noor,mari,theo)")}
    if len(people) < 6:
        sys.exit("run scripts/seed_v2_dev.py first (the made-up people are missing)")
    friends = [people[u] for u in ("nadia", "gem", "dev.k", "noor")]
    now = dt.datetime.now(dt.timezone.utc)
    rng = random.Random(11)
    m = {"user": None, "photos": [], "posts": [], "rolls": [], "paths": [], "memberships": []}

    password = secrets.token_urlsafe(24)
    PASSWORD_FILE.write_text(password)
    os.chmod(PASSWORD_FILE, 0o600)
    dev.insert("allowed_emails", [{"email": EMAIL, "note": "v2 tester, remove with seed_v2_tester.py --reset"}])
    made = seed.request(seed.DEV, dev.k, "POST", "/auth/v1/admin/users",
                        {"email": EMAIL, "password": password, "email_confirm": True})
    uid = made["id"]
    m["user"] = uid
    save(m)
    code = "".join(rng.choice(string.ascii_uppercase + string.digits) for _ in range(6))
    dev.insert("users", [{"id": uid, "email": EMAIL, "username": USERNAME, "display_name": "Tester",
                          "invite_code": code}])
    for f in friends:
        dev.insert("follows", [{"follower_id": uid, "following_id": f, "push_sent": True},
                               {"follower_id": f, "following_id": uid, "push_sent": True}])
    dev.insert("follows", [{"follower_id": people["mari"], "following_id": uid, "push_sent": True},
                           {"follower_id": uid, "following_id": people["theo"], "push_sent": True}])

    images = sorted((seed.REPO / "pairs").glob("*_lapse.jpg"))
    prepared = [(seed.resized(p, 1400), seed.resized(p, 500)) for p in images]
    # Shared manifest shape with seed.new_photo/post (they append to "photos"/"posts"/"paths").
    def photo(taken, **kw):
        feed, thumb = rng.choice(prepared)
        return seed.new_photo(dev, m, uid, feed, thumb, taken, **kw)

    # Posted, this month and last (so there is a finished month to box).
    posts = []
    for i in range(14):
        taken = now - dt.timedelta(days=rng.uniform(0, 40), hours=rng.uniform(0, 4))
        pid = photo(taken)
        posts.append(seed.post(dev, m, uid, pid, taken, rng.choice(seed.CAPTIONS)))
    # Kept, not posted.
    for _ in range(8):
        photo(now - dt.timedelta(days=rng.uniform(0, 30)))
    # Waiting to be sorted (a personal shot develops at once, as in the app).
    for i in range(8):
        photo(now - dt.timedelta(hours=rng.uniform(2, 30)), sorted_=False)
    save(m)

    # Friends react and write on the newest posts.
    newest = dev.select("posts", f"select=id&user_id=eq.{uid}&order=taken_at.desc&limit=6")
    for i, p in enumerate(newest):
        for f in rng.sample(friends, k=rng.randint(1, 4)):
            dev.insert("post_reactions", [{"post_id": p["id"], "user_id": f, "emoji": rng.choice(seed.EMOJIS),
                                           "push_sent": True}])
        if i < 3:
            dev.insert("post_comments", [{"post_id": p["id"], "user_id": rng.choice(friends),
                                          "body": rng.choice(seed.COMMENTS), "push_sent": True}])

    # The seeded rolls, joined, with shots of its own.
    for roll in dev.select("rolls", "select=id,name,reveal_at&name=in.(%22Lake%20weekend%22,%22Friday%20dinner%22)"):
        dev.insert("roll_members", [{"roll_id": roll["id"], "user_id": uid}])
        m["memberships"].append(roll["id"])
        reveal = dt.datetime.fromisoformat(roll["reveal_at"])
        for _ in range(3):
            photo(reveal - dt.timedelta(hours=rng.uniform(14, 30)), roll_id=roll["id"], develops=reveal)
    # Two of its own: one opened (to delete), one sealed (to invite into and shoot).
    for name, reveal in [("Tester's opened roll", now - dt.timedelta(hours=6)),
                         ("Tester's sealed roll", now + dt.timedelta(days=2))]:
        rid = str(uuid.uuid4())
        code = "".join(rng.choice(string.ascii_uppercase + string.digits) for _ in range(6))
        dev.insert("rolls", [{"id": rid, "name": name, "invite_code": code, "created_by": uid,
                              "created_at": seed.iso(reveal - dt.timedelta(hours=30)), "reveal_at": seed.iso(reveal)}])
        m["rolls"].append(rid)
        dev.insert("roll_members", [{"roll_id": rid, "user_id": u} for u in [uid] + friends[:2]])
        for who in [uid, uid, friends[0], friends[1]]:
            feed, thumb = rng.choice(prepared)
            # Friends' shots go in their own folders, as the path lock requires.
            taken = reveal - dt.timedelta(hours=rng.uniform(8, 20))
            seed.new_photo(dev, m, who, feed, thumb, taken, roll_id=rid, develops=reveal)
        save(m)
    save(m)
    print(f"tester ready: {len(m['posts'])} posts, {len(m['photos'])} photos, "
          f"{len(m['rolls'])} own rolls, joined {len(m['memberships'])}. Password in {PASSWORD_FILE}.")


def reset(_args):
    if not MANIFEST.exists():
        sys.exit("nothing to reset")
    dev = seed.Dev(seed.key(".flim-v2-service-key"))
    m = json.loads(MANIFEST.read_text())
    for rid in m["rolls"]:
        dev.delete("rolls", f"id=eq.{rid}")
    uid = m["user"]
    if uid:
        for rid in m["memberships"]:
            dev.delete("roll_members", f"roll_id=eq.{rid}&user_id=eq.{uid}")
    for i in range(0, len(m["posts"]), 50):
        dev.delete("posts", "id=in.(" + ",".join(m["posts"][i:i + 50]) + ")")
    for i in range(0, len(m["photos"]), 50):
        dev.delete("photos", "id=in.(" + ",".join(m["photos"][i:i + 50]) + ")")
    if uid:
        dev.delete("users", f"id=eq.{uid}")
        try:
            seed.request(seed.DEV, dev.k, "DELETE", f"/auth/v1/admin/users/{uid}")
        except SystemExit as e:
            print(f"note: {e}")
    dev.delete("allowed_emails", "email=eq." + urllib.parse.quote(EMAIL))
    if m["paths"]:
        dev.remove(m["paths"])
    MANIFEST.unlink()
    PASSWORD_FILE.unlink(missing_ok=True)
    print("tester removed")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--reset", action="store_true")
    a = ap.parse_args()
    (reset if a.reset else make)(a)
