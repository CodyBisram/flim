#!/usr/bin/env python3
"""Generate Flim/Resources/emoji-keywords.txt from Unicode CLDR annotations.

This is the same data Apple derives Messages' emoji search from, which is the bar the picker is
held to: every emoji findable by the words people actually type, not only by its formal Unicode
name. The hand-curated aliases in EmojiCatalog.swift stay on top of this as the vernacular layer
(CLDR has no entry for "deadline"); this file is the floor under them.

Output format, one line per emoji:  <emoji-with-VS16-stripped>\t<kw1>|<kw2>|...
Keys are stripped of variation selectors so the Swift side can look up by the same skeleton
regardless of which presentation form the catalog generated.

Run:  .venv/bin/python scripts/gen_emoji_keywords.py
Then rebuild; the file ships in the app bundle.
"""
import json
import re
import urllib.request

BASE = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json"
SOURCES = [
    f"{BASE}/cldr-annotations-full/annotations/en/annotations.json",
    f"{BASE}/cldr-annotations-derived-full/annotationsDerived/en/annotations.json",
]

# Words that would match half the catalog and mean nothing alone.
STOP = {
    "a", "an", "and", "as", "at", "be", "but", "by", "for", "from", "in", "is", "it", "its",
    "of", "on", "or", "the", "to", "with", "without",
}

def words(phrase: str):
    for w in re.split(r"[^a-z0-9]+", phrase.lower()):
        if len(w) >= 2 and w not in STOP:
            yield w

def skeleton(emoji: str) -> str:
    return "".join(ch for ch in emoji if ord(ch) != 0xFE0F)

out: dict[str, list[str]] = {}
for url in SOURCES:
    with urllib.request.urlopen(url, timeout=60) as r:
        data = json.load(r)
    # The base file nests under "annotations", the derived file under "annotationsDerived".
    root = data.get("annotations") or data.get("annotationsDerived")
    annotations = root["annotations"]
    for emoji, entry in annotations.items():
        key = skeleton(emoji)
        seen = set(out.get(key, []))
        merged = out.setdefault(key, [])
        # "default" is the keyword list; "tts" is the spoken name. Both carry search value and
        # they overlap heavily, so dedupe across them.
        for phrase in entry.get("default", []) + entry.get("tts", []):
            for w in words(phrase):
                if w not in seen:
                    seen.add(w)
                    merged.append(w)

lines = [f"{k}\t{'|'.join(v)}" for k, v in sorted(out.items()) if v]
path = "Flim/Resources/emoji-keywords.txt"
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(f"{len(lines)} emoji, {sum(len(v) for v in out.values())} keywords -> {path}")
