# Copy rules

Words that mean one thing each. Added 2026-08-28, after three different actions in the app had
all ended up called "Share".

## Post vs Share vs Shared roll

| Word | Means | Never means |
| --- | --- | --- |
| **Post** | Publish a shot to YOUR page, where the people who follow you see it. In-app. | Sending anything out of the app. |
| **Share** | Send something OUT of FLIM: a photo to the iOS share sheet, a roll invite, your code. | Publishing to your page. |
| **Shared roll** | A roll held in common with other people. An adjective about ownership. | Anything published. |

The test: **`Share` always ends with the iOS share sheet.** If the thing stays inside FLIM, the
word is `Post`. If a control carries `square.and.arrow.up`, it is a Share; if it publishes, it is
a Post and should not use that glyph.

### Why this way round

`Post` was already the app's own word in the place that matters most, the sort deck's publish
swipe ("Post to your page"), and the whole data model has always been posts: `Post`,
`PostDetailView`, `myPostedPhotoIds`, `post_shared`. Only the surface copy had drifted. Choosing
`Post` aligned the words to the code and to the primary flow, rather than inventing a new term.

**"Page", not "feed".** You post to your page; the feed is what you read. `UserPageView` is
already called a page. "Share to Feed" implied pushing into a communal feed, which is not the
model.

### The forms

- Verb: **Post to your page**. Short form on a pill: **Post**.
- Done state: **Posted to your page**, short form **Posted**, negative **Not posted**.
- Counts: **1 posted**, **6 posted**.
- Never: "Share to your page", "Share to Feed", "Shared", "Not shared", "publish to your feed".

`Publish` is fine in code and comments (`performSwipe(.publish)`, `publishError`); it is not a
word the reader sees.

## Where each one lives

**Post** — the sort deck's publish swipe, the pager's Post pill and its menu item, the pager
status row, `ShareToFeedSheet` (title and primary button), the Darkroom day meta line, the
profile's empty state, onboarding's second page.

**Share** — `SharePreviewSheet` (title, and "Share print / story / full frame / photo"), the
share glyph in every photo viewer, "Share invite" on a roll, "Share this code" on a profile.

**Shared roll** — `ConsequenceSheet`, onboarding, anywhere a roll's communal nature is the point.

## A note for whoever changes copy next

Two tests pin these strings on purpose (`DarkroomDayUnitTests.testMetaLineCountsPosted`,
`ShareToFeedSheetTests.testConsequenceLineWithNobodyTagged`). They failed when this rule landed,
which is what they are for. Update them deliberately rather than loosening them.

Also: **no em dashes** in any user-facing copy.
