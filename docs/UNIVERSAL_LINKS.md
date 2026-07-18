# Roll invite links (flim-app.com/join/CODE)

## What works today (no signing changes)
- Invites share a real **https link**: `https://flim-app.com/join/YCQFE6` (tappable in Messages).
- It opens **flim-app.com/join**, a branded page showing the code + an **"Open FLIM"** button
  (custom-scheme deep link into the app's join flow).
- The app already parses both URL shapes (`com.lapse.app://join/…` and `https://flim-app.com/join/…`).
- The AASA file is live at `/.well-known/apple-app-site-association` (served as JSON).

## The upgrade: link opens the app DIRECTLY (universal links)
One missing piece: the **Associated Domains** entitlement. Not added yet on purpose:
the match provisioning profile doesn't include the capability, so adding the entitlement
now would fail the next TestFlight build's signing.

Steps, in order (10 min, needs whoever runs match):
1. **Developer portal** → Identifiers → `com.flim.app` → enable **Associated Domains** → Save.
2. **Regenerate the match profiles** so they pick up the capability:
   `bundle exec fastlane match appstore --force` (and `development --force` if used locally).
3. **Flip the associated-domains entitlement** in `Flim/Flim.entitlements` (+ project.yml):
   ```xml
   <key>com.apple.developer.associated-domains</key>
   <array><string>applinks:flim-app.com</string></array>
   ```
4. Push → build → install. iOS fetches the AASA on install; `/join/*` links then open FLIM
   directly, no landing page stop.

Nothing else changes. The landing page stays as the fallback for people without the app.
