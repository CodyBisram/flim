---
name: social-drafts
description: Draft a weekly batch of Instagram and X posts for FLIM from what actually shipped, as a markdown file the owner reviews. Never posts anything.
---

# FLIM social drafts

Produce one markdown file of DRAFT posts for FLIM's Instagram and X accounts, grounded in
what actually happened in this repo since the last batch. The owner reviews, edits, and
posts by hand (or via a scheduler). This skill never publishes, never calls a social API,
and never opens anything outward-facing.

## Where drafts go

`social/drafts/YYYY-MM-DD.md`, dated the day the batch is written. Look at the most recent
file in `social/drafts/` to find where the last batch left off; cover the commits and
changes since then (`git log --since=...`). First batch ever: cover the last two weeks.

## What to draw from

- `git log` since the last batch. Commit messages in this repo are written with care and
  are often usable material almost verbatim.
- `docs/` for feature context when a commit alone is too terse.
- Nothing else. No invented metrics, no invented user quotes, no trends, no news-jacking.

## The one hard content rule

FLIM has a shipped App Store build and an unreleased train on main. A feature that is not
in the released build is framed as in progress ("building", "coming"), never as available.
When unsure which side a feature is on, frame it as in progress. Never reference version
numbers, build numbers, internal codenames, incidents, security work, or anything about
infrastructure costs or limits.

## Voice

FLIM's copy voice, which is also the app's design ethos:

- No em dashes, ever. Use a period, comma, or "to".
- Short declarative sentences. Plain words. No hype, no exclamation marks, no emoji
  strings, no "we're SO excited".
- No hashtag piles. At most one or two, only when they genuinely index the content.
- No growth-hack CTAs. FLIM is invite-only by design; never beg for downloads or follows,
  never run "tag a friend" mechanics. "Nobody is suggested to you, and nobody is ranked"
  is the brand; the copy must live by it.
- The app is written FLIM, in caps.
- X is the build-in-public channel: what got built, why, what it felt like to get right.
  Specific beats general. A concrete detail (the 04:00 day boundary, film strips per
  night) beats any adjective.
- Instagram is the visual channel: the film look is the product demo. Captions stay
  short; the photograph does the talking.

## Format of a batch

```markdown
# FLIM social drafts, week of <date>

Covers <short summary of the period's real work>.

## X

### 1. <working title>
> <post text, ready to paste>

Why now: <one line tying it to what shipped>

(3 or 4 posts. At most one thread, marked post-by-post.)

## Instagram

### 1. <working title>
Asset: <precise description of the image or short clip to capture, e.g. "simulator
screenshot of the Darkroom month grid, dark room, seeded demo content">
> <caption, ready to paste>

Why now: <one line>

(2 or 3 concepts.)

## Skipped on purpose
<anything topical that was deliberately left out, and why, so the owner is not left
wondering>
```

## Asset rules

- Assets are described, not generated. Screenshots come from the simulator with seeded
  demo content (`-seedDemo`), never from real accounts or real users' photographs.
- Never include an invite code, a real handle other than FLIM's own, or a user-visible
  piece of anyone's content.

## If run as a scheduled routine

Commit the single new draft file to a branch named `social-drafts-YYYY-MM-DD` and open a
PR titled "Social drafts, week of <date>" so the owner reviews it like anything else. The
commit message is one plain line, e.g. `Social drafts for the week of Sep 1.`; the
co-author trailer the tooling appends is fine. Touch nothing outside `social/drafts/`.
