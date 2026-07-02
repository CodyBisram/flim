# FLIM — Remote Push (APNs) setup

The app already sends **local** "your photo developed" notifications with no backend
(`NotificationService`). You only need this for **remote** push — notifying a roll-mate
when someone *else's* photo develops in a shared roll.

## What's here
- `device_tokens.sql` — token table + RLS, and a `push_sent` flag on `photos`.
- `send-develop-push/index.ts` — scheduled Edge Function that pushes to roll-mates
  (excluding the photo owner) when a roll photo develops.

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

That's it — local notifications keep working regardless; remote push lights up once the
above is in place.

## Social push (comments + reactions)

`send-social-push/index.ts` notifies a post's **owner** when someone else comments or
reacts. Reactions are **batched per person** (one push listing that friend's emoji), the
Lapse way — not one notification per emoji.

Setup (in addition to the develop-push steps above — same APNs secrets):
1. Run the updated `device_tokens.sql` (adds `push_sent` to `post_comments` / `post_reactions`).
2. `supabase functions deploy send-social-push --no-verify-jwt`
3. Schedule it every 1 minute (Dashboard → Edge Functions → Schedules, or pg_cron).
