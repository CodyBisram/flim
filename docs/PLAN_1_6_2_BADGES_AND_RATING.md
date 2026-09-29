# 1.6.2 plan: three silver badges and the rating prompt (2026-09-29)

Owner-approved direction, 2026-09-29: Recruiter, Feedback and Bug Catcher, all silver; a one-tap
way for the owner to award the two hand-given ones; Apple's rating prompt at good moments. Not
built yet. Copy below needs the owner's yes before it ships.

Ruled out on purpose: a badge for leaving an App Store review. Apple's guideline 5.6.3 forbids
rewarding reviews (a badge is a reward), and Apple never says which of your users reviewed, so it
could not be checked anyway.

---

## 1. The badges

All three sit on the existing ladder in `ProfileBadgeKind.tier`, at **silver** ("real effort, one
determined stretch"). No new style and no glow: the glow is reserved for the founding rung on
purpose (`ProfileBadgeTier.glow`), and a glow on hand-given pills would compete with it. What makes
a hand-given badge feel personal is the line under it instead (see "Given by Cody" below).

| id | Title | Emoji | Earned when | How it is given |
|---|---|---|---|---|
| `recruiter` | Recruiter | 🤝 | Three people you invited are still shooting a month after they joined | Automatic |
| `feedback` | Feedback | 💬 | Something you told us changed FLIM | The owner awards it |
| `bug_catcher` | Bug Catcher | 🐞 | You found a bug, and it got fixed | The owner awards it |

### Copy (for the owner's yes)

| Where | Recruiter | Feedback | Bug Catcher |
|---|---|---|---|
| Explanation, tapped on a profile | Three people you invited are still shooting a month later. | Something you told us changed FLIM. Given by Cody. | You found a bug, and it got fixed. Given by Cody. |
| How to earn, in the badge list | Invite people who stay: three still shooting a month after they join. | Send feedback from your profile. When it changes FLIM, Cody gives you this. | Report a bug from your profile. When it is fixed, Cody gives you this. |

"Given by Cody" uses the owner's name, not `AppInfo.appName`, on purpose: it is his thank-you.

### Recruiter, precisely

An invitee counts when all of these hold:
- they joined through your personal invite (the same attribution Brought Someone, Patron and
  Open Door use), not through a roll code or a campaign code;
- their account is at least 30 days old;
- they took at least one photo on or after their 30th day.

Three such invitees earn it. Like every automatic badge it ratchets: once earned it stays, even if
someone later stops shooting. Computed server-side with the other predicates, in the same place
Patron's is.

### Awarding Feedback and Bug Catcher

- **Database** (one migration, applied by the owner):
  - add the three ids to `earned_badges_badge_id_check`;
  - add `feedback` and `bug_catcher` to `earned_badges_grantable_check` and to `grant_badge`'s
    allow list (today only `founding_crew` and `founder`);
  - the Recruiter predicate.
- **Admin dashboard** (`web/admin.html`, Feedback panel): two buttons on every feedback entry,
  "Award Feedback" and "Award Bug Catcher". Each calls `grant_badge(author, id)` for the person who
  sent it, asks once to confirm, and then shows "Awarded" on that entry. A person who already holds
  the badge sees the button disabled. `grant_badge` is already owner-only (`is_owner()`).
  Remember: `web/` deploys by hand.
- **How the person finds out:** the way every badge works today, silently. The avatar dot and the
  "New badge to see" pill on their profile, and the reveal in the picker. No push, per the
  2026-09 decision in `send-social-push` (a push per badge was retired).

### App side

- Three new `ProfileBadgeKind` cases, with title, emoji, tier (silver), explanation and
  how-to-earn.
- The "Given by Cody" sentence shows only for `feedback` and `bug_catcher`.
- Older app versions drop badge ids they don't know (`ProfileBadgeKind(rawValue:)` returns nil in
  `fetchProfileBadges`), so a badge awarded before someone updates simply appears once they do.
- Tests: the tier of each, the copy against the house rules (no dashes, no exclamation marks),
  the Recruiter predicate on the staging database (`scripts/schema_bootstrap.sh --keep`), and that
  `grant_badge` still refuses every other id.

---

## 2. The rating prompt

Apple's own "Enjoying FLIM?" card (SwiftUI `@Environment(\.requestReview)`): stars in place, an
optional written review, no leaving the app. Apple decides whether it actually appears and shows it
at most three times a year per person; nobody learns who rated or what. It never appears in
TestFlight, so it can only be judged once it is on the App Store.

### When to ask

Right after something good, once the moment has settled (about a second after the screen is
still, never over a sheet, the camera or the sort deck):

1. **Your frame is chosen for Spotlight**, when you first open it after the push.
2. **A roll reveal finishes**, on its last frame.
3. **Your 10th post**, after it lands.
4. **Your fifth reaction received**, the next time you open the app.

### Guards (FLIM's own, on top of Apple's limit)

- Not in an account's first 7 days.
- At most once per app version, and at least 120 days between asks.
- Not within a day of anything failing in front of the person (an upload that queued, a comment
  that didn't send).
- Stored per account in UserDefaults (`reviewAsk.<userId>`: last asked, version, count).
- Logged as a `Usage` event (asked, and which moment), so it is visible which moments get used.
  Whether Apple showed the card, or what anyone gave, is never known.

### Tests

The guard decision as a pure function (first week, same version, 120 days, a recent failure);
the moment hooks by reading; the prompt itself only on the App Store build.

---

## Order of work

1. The migration (badges' ids, grantable list, Recruiter predicate), tried on the staging database,
   then applied by the owner.
2. The app: badge cases and copy, the rating prompt and its guards. Ships as 1.6.2.
3. The admin dashboard buttons, deployed by hand after the migration is live.
4. On device: award yourself Feedback from the dashboard, see the dot and the reveal, and read the
   "Given by Cody" line.
