# Roll invite links (flim-app.com/join/CODE)

## What works today (no signing changes)
- Invites share a real **https link**: `https://flim-app.com/join/YCQFE6` (tappable in Messages).
- It opens **flim-app.com/join**, a branded page showing the code + an **"Open FLIM"** button
  (custom-scheme deep link into the app's join flow).
- The app already parses both URL shapes (`com.lapse.app://join/…` and `https://flim-app.com/join/…`).
- The AASA file is live at `/.well-known/apple-app-site-association` (served as JSON).

## The upgrade: link opens the app DIRECTLY (universal links)

✅ **All steps are done as of 2026-08-04.** The Associated Domains capability is enabled on the
`com.flim.app` App ID (confirmed in the developer portal), and every signed release build since
`a14b9ac` has exported successfully, which it could not do if the profile lacked the capability.

Steps, in order (10 min, needs whoever runs match):
1. **Developer portal** → Identifiers → `com.flim.app` → enable **Associated Domains** → Save.
   **DONE** (confirmed in the portal, 2026-08-04).
2. **Regenerate the match profiles** so they pick up the capability:
   `bundle exec fastlane match appstore --force` (and `development --force` if used locally).
   **DONE.** Evidenced by green signed builds since `a14b9ac`; a profile without the
   capability fails export.
   Once done, `/join/*` links will open FLIM directly on install.
3. ~~Flip the associated-domains entitlement~~ **DONE** (commit a14b9ac). Declared in
   `project.yml` under the Flim target's `entitlements.properties`. Xcodegen generates
   `Flim/Flim.entitlements` from it, so editing that file directly gets overwritten.
4. Push → build → install. iOS fetches the AASA on install; `/join/*` links then open FLIM
   directly, no landing page stop.

**Verified already live (2026-08-01):** the AASA responds `200` with
`content-type: application/json` and no redirect, declaring `DCU7GHRVUQ.com.flim.app` for
`/join/*`. `FlimApp.swift` parses the https shape. So the server and client halves are ready
and only the signing capability is outstanding.

Nothing else changes. The landing page stays as the fallback for people without the app.
