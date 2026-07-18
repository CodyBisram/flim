# FLIM: Remote Push (APNs) setup

The app already sends **local** "your photo developed" notifications with no backend
(`NotificationService`). You only need this for **remote** push: notifying a roll-mate
when someone *else's* photo develops in a shared roll.

## What's here
- `device_tokens.sql`: token table + RLS, and the `push_sent` flags.
- The Edge Functions live in **`supabase/functions/`** (the CLI's canonical location):
  - `send-develop-push`: sends one notification per roll when it develops (not per photo), only to roll-mates who didn't contribute photos.
  - `send-social-push`: notifies a post owner on comments/reactions, and a roll
    photo's owner + thread on roll-photo comments.

## One-time setup

1. **Run the SQL** (Supabase → SQL Editor): `device_tokens.sql` (after `../schema.sql`).

2. **APNs key**: Apple Developer → Certificates, IDs & Profiles → Keys → create a key
   with *Apple Push Notifications service (APNs)* enabled. Download the `.p8`. Note the
   **Key ID** and your **Team ID**.

3. **Function secrets**:
   ```bash
   supabase secrets set \
     APNS_KEY_ID=XXXXXXXXXX \
     APNS_TEAM_ID=YYYYYYYYYY \
     APNS_BUNDLE_ID=com.flim.app \
     APNS_ENVIRONMENT=sandbox \
     APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
   ```
   (Use `APNS_ENVIRONMENT=production` for TestFlight/App Store builds.)

4. **Deploy + schedule**:
   ```bash
   supabase functions deploy send-develop-push --no-verify-jwt
   ```
   Then add a 1-minute schedule (Dashboard → Edge Functions → Schedules, or pg_cron).

## App side
1. Xcode → FLIM target → Signing & Capabilities → **+ Capability → Push Notifications**
   (adds the `aps-environment` entitlement).
2. After permission is granted, call `RemotePush.register()` (e.g. in
   `NotificationService.requestAuthorizationIfNeeded` once `isAuthorized` is true).
   The `FlimAppDelegate` then uploads the APNs token to `device_tokens`.

That's it: local notifications keep working regardless; remote push lights up once the
above is in place.

## Social push (comments + reactions)

`send-social-push/index.ts` notifies a post's **owner** when someone else comments or
reacts. Reactions are **batched per person** (one push listing that friend's emoji), the
Lapse way, not one notification per emoji.

Setup (in addition to the develop-push steps above, same APNs secrets):
1. Run the updated `device_tokens.sql` (adds `push_sent` to `post_comments` / `post_reactions`).
2. `supabase functions deploy send-social-push --no-verify-jwt`
3. Schedule it every 1 minute (Dashboard → Edge Functions → Schedules, or pg_cron).

## Report notifications (App Store Guideline 1.2)

`send-social-push` also notifies the **app owner** whenever a content report lands
(`photo_reports` / `user_reports`) so UGC can be actioned within 24h. Same poll +
`push_sent` flag pattern; the owner is named once via the `OWNER_EMAIL` constant in
the function (matches the `note = 'owner'` seed in `allowed_emails`).

Setup:
1. Run `../migrations/2026-07-10_report_notifications.sql` (adds `push_sent` to the
   two report tables). Its header carries a daily-check SQL backstop for when the
   owner has no registered device.
2. Redeploy: `supabase functions deploy send-social-push --no-verify-jwt`
   (already scheduled every 1 minute; no new schedule needed).
