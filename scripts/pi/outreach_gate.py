#!/usr/bin/env python3
"""The weekly outreach job's mechanical gate (scripts/pi/outreach-weekly.sh).

The model writes the batch and judges its own notes first (the gate in
.claude/skills/creator-shortlist/SKILL.md). This file re-checks every rule a program can check,
independently, and anything that fails is held, never sent. It cannot make a note good; it can
only stop a note that breaks a written rule. Standard library only, so it runs on the Pi as is.

  gate       plan.json + the batch file -> gate.json (pass, or held with reasons)
  assemble   gate.json + codes.json     -> send.json (the exact emails, codes filled in)
  finalize   gate.json + result.json    -> rewrites each entry's Status line in the batch file
  leakcheck  codes on stdin             -> exit 1 if the batch file carries any of them
"""
import argparse
import html
import json
import re
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

SUBJECT = "An invite to FLIM"
SIGN_OFF = "Cody, who makes FLIM"
INVITE_LINE = "Here's yours if you want it: https://flim-app.com/i/{code} (code {code})."
MAX_SENDS = 10
MAX_WORDS = 89  # "under 90 words"

# Phrases that read as written by a model, or as a pitch. Matched case-insensitively on the
# note with curly quotes straightened. Keep in step with the list in SKILL.md.
BANNED = [
    "hope this finds you", "hope you're well", "hope you are well", "hope all is well",
    "i came across", "came across your", "stumbled upon", "wanted to reach out", "reaching out",
    "reach out", "resonat", "delve", "tapestry", "testament", "in today's world",
    "in today's digital", "in a world where", "game-changer", "game changer", "game-changing",
    "excited to", "thrilled", "seamless", "journey", "elevate", "unlock", "leverage",
    "revolutionary", "innovative", "cutting-edge", "cutting edge", "passionate",
    "love to connect", "quick question", "touch base", "circle back", "hear your thoughts",
    "at the intersection", "landscape", "realm", "embark", "vibrant", "curated", "authentic",
    "genuinely", "truly", "deeply", "amazing", "incredible", "awesome", "partnership",
    "collab", "sponsor", "affiliate", "promo code", "discount", "your audience", "your followers",
    "your community", "share it with", "post about", "write about it", "review it", "feature it",
    "spotlight", "contact sheet", "as an ai", "i'm an ai", "dear ",
]
# "not just X but Y" and "not only X but also Y", within one sentence.
NOT_JUST = re.compile(r"\bnot (just|only|merely|simply)\b[^.?]*\bbut\b", re.I)
# A rhetorical triad of single words: "simple, slow, and honest".
TRIAD = re.compile(r"\b[A-Za-z]+, [A-Za-z]+,? and [A-Za-z]+\b")
# Claims about FLIM: counts, users, press, awards.
CLAIMS = re.compile(
    r"\b\d[\d,.]*\+?\s*(k\s+)?(users|people|members|downloads|installs|signups|sign-ups|"
    r"photographers|creators|accounts|countries|stars)\b"
    r"|\b(thousands|hundreds|millions) of\b|\bfeatured (in|on|by)\b|\bas seen\b|\baward"
    r"|\bpress\b|\bnumber one\b|#1\b|\btop[- ]rated\b|\b5[- ]star",
    re.I,
)
CONTRACTION = re.compile(r"\b[A-Za-z]+'(s|re|ve|d|ll|m|t)\b")
EMAIL = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
DASHES = "".join(chr(c) for c in (0x2012, 0x2013, 0x2014, 0x2015, 0x2212))  # figure, en, em, bar, minus
EM_DASH, EN_DASH = chr(0x2014), chr(0x2013)


def straighten(s):
    return s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')


def has_emoji(s):
    for ch in s:
        cp = ord(ch)
        if (0x1F000 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF or 0x2B00 <= cp <= 0x2BFF
                or cp in (0xFE0F, 0x200D, 0x2122, 0x00A9, 0x00AE)
                or unicodedata.category(ch) == "So"):
            return True
    return False


def sentences(note):
    parts = re.split(r"(?<=[.?])\s+(?=[A-Z\"'(])", note.strip())
    return [p for p in parts if p.strip()]


def norm_email_text(text):
    """Page or file text with the usual obfuscations undone, lowercased."""
    t = html.unescape(text)
    # Cloudflare email protection: data-cfemail="<hex>", first byte is the XOR key.
    for hexs in re.findall(r'data-cfemail="([0-9a-fA-F]+)"', t):
        try:
            b = bytes.fromhex(hexs)
            t += " " + "".join(chr(x ^ b[0]) for x in b[1:])
        except ValueError:
            pass
    t = urllib.parse.unquote(t) if "%40" in t else t
    t = t.lower()
    t = re.sub(r"\s*(\[at\]|\(at\)|\{at\}|<at>| at )\s*", "@", t)
    t = re.sub(r"\s*(\[dot\]|\(dot\)|\{dot\}| dot )\s*", ".", t)
    return t


def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(3_000_000).decode("utf-8", "replace")


def earlier_text(outreach_dir, today_file):
    out = []
    for p in sorted(Path(outreach_dir).glob("*.md")):
        if p.resolve() != Path(today_file).resolve():
            out.append(p.read_text(encoding="utf-8"))
    return "\n".join(out)


def check_note(e):
    reasons = []
    note = straighten((e.get("note") or "").strip())
    first = (e.get("first_name") or "").strip()
    name = (e.get("name") or "").strip()
    if not note:
        return ["no note"]
    if any(d in note for d in DASHES) or " - " in note or "--" in note:
        reasons.append("an em or en dash, or a hyphen used as one")
    if "!" in note:
        reasons.append("an exclamation mark")
    if has_emoji(note):
        reasons.append("an emoji or symbol")
    if re.search(r"https?://|www\.|flim-app\.com", note, re.I):
        reasons.append("a link inside the note (the job adds the invite line itself)")
    if SIGN_OFF.lower() in note.lower() or re.search(r"\bCody\b", note):
        reasons.append("a sign-off inside the note (the job adds it)")
    if re.match(r"(hi|hello|hey|dear)\b", note, re.I):
        reasons.append("a greeting inside the note (the job adds 'Hi <first name>,')")
    words = len(note.split())
    if words > MAX_WORDS:
        reasons.append(f"{words} words, over 89")
    n = len(sentences(note))
    if n not in (4, 5):
        reasons.append(f"{n} sentences, not 4 or 5")
    low = note.lower()
    for b in BANNED:
        if b in low:
            reasons.append(f"banned phrase '{b.strip()}'")
    if NOT_JUST.search(note):
        reasons.append("a 'not just X but Y' construction")
    if TRIAD.search(note):
        reasons.append("a three-word flourish")
    if CLAIMS.search(note):
        reasons.append("a claim about numbers, users, press or awards")
    if not re.search(r"\bI\b|\bI'", note):
        reasons.append("not written in the first person")
    if not CONTRACTION.search(note):
        reasons.append("no contractions anywhere, which reads stiff")
    if not re.fullmatch(r"[A-Z][A-Za-z'\-]{0,29}", first):
        reasons.append("first name missing or not a plain first name")
    elif first.lower() not in name.lower():
        reasons.append("first name does not appear in the listed name")
    return reasons


def cmd_gate(a):
    plan = json.loads(Path(a.plan).read_text(encoding="utf-8"))
    today = Path(a.file).read_text(encoding="utf-8")
    today_norm = norm_email_text(today)
    earlier = earlier_text(Path(a.file).parent, a.file)
    earlier_norm = norm_email_text(earlier)
    seen_emails = set()
    out, passing = [], 0
    for e in plan.get("entries", []):
        reasons = []
        name = (e.get("name") or "").strip()
        email = (e.get("email") or "").strip().lower()
        if str(e.get("model_gate", "")).lower() != "pass":
            reasons.append("held by the written gate: " + (e.get("held_reason") or "no reason given"))
        if not EMAIL.match(email):
            reasons.append("no plain published email address")
        elif email in seen_emails:
            reasons.append("same address twice in this batch")
        seen_emails.add(email)
        if email and email in earlier_norm:
            reasons.append("address already appears in an earlier outreach file")
        if name and name.lower() in earlier.lower():
            reasons.append("name already appears in an earlier outreach file")
        if email and email not in today_norm:
            reasons.append("address is not recorded in this batch's Contact line")
        for key, label in (("email_source_url", "the page that publishes the address"),
                           ("thing_url", "the linked thing the first sentence names")):
            u = (e.get(key) or "").strip()
            if not u.startswith("http"):
                reasons.append(f"no link to {label}")
            elif u not in today:
                reasons.append(f"{label} is not linked in the batch file")
        reasons += check_note(e)
        if not reasons and email and not a.no_fetch:
            try:
                page = norm_email_text(fetch(e["email_source_url"]))
                if email not in page:
                    reasons.append("address not found on the page cited as publishing it")
            except Exception as ex:  # noqa: BLE001 - any fetch failure is a hold, never a send
                reasons.append(f"could not re-read the page that publishes the address ({type(ex).__name__})")
        if not reasons and passing >= MAX_SENDS:
            reasons.append("over the weekly cap of 10")
        ok = not reasons
        passing += ok
        out.append({"n": e.get("n"), "name": name, "first_name": (e.get("first_name") or "").strip(),
                    "email": email, "note": straighten((e.get("note") or "").strip()),
                    "pass": ok, "reasons": reasons})
    Path(a.out).write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"gate: {passing} pass, {len(out) - passing} held")


def cmd_assemble(a):
    gate = json.loads(Path(a.gate).read_text(encoding="utf-8"))
    codes = json.loads(Path(a.codes).read_text(encoding="utf-8")) if a.codes else {}
    send = []
    for g in gate:
        if not g["pass"]:
            continue
        code = "XXXXXX" if a.dry else codes.get(str(g["n"]))
        if not code or not re.fullmatch(r"[A-Z0-9]{6}", code):
            continue
        body = "\n\n".join([f"Hi {g['first_name']},", g["note"], INVITE_LINE.format(code=code), SIGN_OFF])
        subject = ("DRY RUN, not sent: " + SUBJECT) if a.dry else SUBJECT
        send.append({"n": g["n"], "to": g["email"], "subject": subject, "body": body})
    Path(a.out).write_text(json.dumps(send, indent=1), encoding="utf-8")
    print(len(send))


def set_status(text, n, status):
    lines = text.split("\n")
    head = re.compile(rf"^## {re.escape(str(n))}\. ")
    inside = False
    for i, line in enumerate(lines):
        if head.match(line):
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside and line.startswith("- Status:"):
            lines[i] = f"- Status: {status}"
            return "\n".join(lines), True
    return text, False


def cmd_finalize(a):
    gate = json.loads(Path(a.gate).read_text(encoding="utf-8"))
    # No result file means the send step ran but its reply could not be read: some of these may
    # have gone. Those entries are marked unconfirmed, never held, so nobody is contacted twice.
    result, have_result = {}, bool(a.result and Path(a.result).exists())
    if have_result:
        for r in json.loads(Path(a.result).read_text(encoding="utf-8")).get("results", []):
            result[str(r.get("n"))] = r
    text = Path(a.file).read_text(encoding="utf-8")
    sent = held = 0
    for g in gate:
        r = result.get(str(g["n"]), {})
        if not g["pass"]:
            status = "held: " + "; ".join(g["reasons"])
            held += 1
        elif a.dry:
            if r.get("draft") == "ok":
                status = f"dry run {a.date}: passed the gate, Gmail draft made, not sent"
                sent += 1
            else:
                status = "held: dry run, the Gmail draft was not made (" + (r.get("error") or "no result") + ")"
                held += 1
        elif a.sendstep and not have_result:
            status = f"unconfirmed: the send step on {a.date} gave no readable result; check Gmail Sent before contacting"
            held += 1
        elif r.get("sent") == "ok":
            status = f"contacted {a.date} by email"
            sent += 1
        elif r.get("draft") == "ok":
            status = "held: a Gmail draft exists but the send failed (" + (r.get("error") or "no result") + "); not retried"
            held += 1
        else:
            status = "held: not sent (" + (r.get("error") or "the send step did not reach this entry") + ")"
            held += 1
        text, _ = set_status(text, g["n"], status)
    # The committed file carries no em or en dash, whoever wrote it.
    text = text.replace(" " + EM_DASH + " ", ", ").replace(EM_DASH, ", ").replace(EN_DASH, "-")
    Path(a.file).write_text(text, encoding="utf-8")
    print(f"{sent} {held}")


def cmd_leakcheck(a):
    text = Path(a.file).read_text(encoding="utf-8")
    bad = "flim-app.com/i/" in text
    for code in sys.stdin.read().split():
        if re.fullmatch(r"[A-Z0-9]{6}", code) and re.search(rf"(?<![A-Za-z0-9]){code}(?![A-Za-z0-9])", text):
            bad = True
    sys.exit(1 if bad else 0)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gate"); g.add_argument("--plan", required=True); g.add_argument("--file", required=True)
    g.add_argument("--out", required=True); g.add_argument("--no-fetch", action="store_true")
    s = sub.add_parser("assemble"); s.add_argument("--gate", required=True); s.add_argument("--codes")
    s.add_argument("--out", required=True); s.add_argument("--dry", action="store_true")
    f = sub.add_parser("finalize"); f.add_argument("--gate", required=True); f.add_argument("--result")
    f.add_argument("--file", required=True); f.add_argument("--date", required=True); f.add_argument("--dry", action="store_true")
    f.add_argument("--sendstep", action="store_true", help="the send step ran, so a missing result means unconfirmed")
    k = sub.add_parser("leakcheck"); k.add_argument("--file", required=True)
    a = p.parse_args()
    {"gate": cmd_gate, "assemble": cmd_assemble, "finalize": cmd_finalize, "leakcheck": cmd_leakcheck}[a.cmd](a)


if __name__ == "__main__":
    main()
