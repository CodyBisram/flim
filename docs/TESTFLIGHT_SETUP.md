# FLIM — TestFlight CI/CD setup

Every push to `main` builds a signed Release archive and uploads it to TestFlight,
with no manual Xcode steps. Pull requests get a fast simulator build as a sanity check.

This file is the one-time setup. Budget ~15–20 minutes. The steps marked **(Apple)**
can only be done by the Apple Developer account holder — they need your Apple ID and
2FA, so nobody (and no script) can do them for you.

```
PR  ──▶ build for simulator (no signing, no secrets)
main ──▶ fastlane: match signing ▶ archive ▶ upload to TestFlight
```

---

## Prerequisites (already true)

- ✅ Active **paid** Apple Developer Program membership ($99/yr) on your Apple ID.
- ✅ Repo on GitHub (`CodyBisram/flim`), GitHub Actions available.
- ✅ App bundle id: **`com.flim.app`**.

---

## Step 1 — Register the App ID **(Apple)**

1. Go to <https://developer.apple.com/account/resources/identifiers/list>.
2. **+** → **App IDs** → **App**. Description: `FLIM`. Bundle ID: **Explicit** → `com.flim.app`.
3. Under **Capabilities**, tick **Push Notifications**. *(The app ships an
   `aps-environment` entitlement; if the App ID doesn't have Push enabled the signed
   build will fail. If you ever strip push from the app, you can skip this.)*
4. **Continue → Register.**

## Step 2 — Create the app record in App Store Connect **(Apple)**

1. Go to <https://appstoreconnect.apple.com/apps> → **+** → **New App**.
2. Platform **iOS**, Name **FLIM**, Primary language, Bundle ID **com.flim.app**,
   SKU `flim` (any unique string). Create.
   *(You don't need to fill in screenshots/metadata to use TestFlight.)*

## Step 3 — Create an App Store Connect API key **(Apple)**

This is how CI authenticates — no passwords, no 2FA prompts.

1. <https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys** tab.
2. **Generate API Key**. Name `FLIM CI`, Access **App Manager**. Generate.
3. **Download** the `AuthKey_XXXXXX.p8` — you only get one chance. Keep it safe.
4. Note the **Key ID** (next to the key) and the **Issuer ID** (top of the page).

## Step 4 — Find your Team ID **(Apple)**

<https://developer.apple.com/account> → **Membership details** → copy the 10-character
**Team ID** (looks like `A1B2C3D4E5`).

---

## Step 5 — Create the signing (match) repo

`fastlane match` keeps the distribution certificate + provisioning profile encrypted
in a **separate private git repo**, so you, your cousin, and CI all share one signing
identity (no "works on my machine" cert chaos).

✅ Already created for you: **<https://github.com/wiggapony0925/flim-certificates>** (private).

Pick a strong passphrase and remember it — it encrypts the certs. This becomes
`MATCH_PASSWORD`.

## Step 6 — Seed the signing assets (run once, locally)

From the repo root, with the `.p8` you downloaded in Step 3:

```bash
bundle install                      # installs fastlane from the Gemfile

export APPLE_TEAM_ID="A1B2C3D4E5"                       # Step 4
export ASC_KEY_ID="XXXXXXXXXX"                          # Step 3
export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx" # Step 3
export ASC_KEY_P8="$(base64 -i ~/Downloads/AuthKey_XXXXXX.p8)"   # the .p8, base64'd
export MATCH_PASSWORD="the-passphrase-you-chose"        # Step 5
export MATCH_GIT_URL="https://github.com/wiggapony0925/flim-certificates.git"

bundle exec fastlane certificates
```

This creates an Apple Distribution certificate + an App Store provisioning profile for
`com.flim.app` and pushes them (encrypted) to `flim-certificates`. You only ever rerun
this if the cert expires or you add a device/capability.

## Step 7 — Make a token so CI can read the match repo

CI needs read access to the private `flim-certificates` repo.

1. Create a fine-grained PAT: <https://github.com/settings/personal-access-tokens/new>
   — Resource owner **wiggapony0925**; Repository access: **only** `flim-certificates`;
   Permission: **Contents → Read-only**.
2. Build the basic-auth value:

```bash
# replace <gh-username> and <token>
printf '<gh-username>:<token>' | base64
```

That base64 string is `MATCH_GIT_BASIC_AUTHORIZATION`.

## Step 8 — Add the secrets to the `flim` repo

These power the `deploy` job. You need **admin** on `CodyBisram/flim` to set secrets.
Run from the repo root (each reads the value you already exported in Step 6, except the
last two):

```bash
gh secret set ASC_KEY_ID                    --repo CodyBisram/flim --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID                 --repo CodyBisram/flim --body "$ASC_ISSUER_ID"
gh secret set ASC_KEY_P8                     --repo CodyBisram/flim --body "$ASC_KEY_P8"
gh secret set APPLE_TEAM_ID                  --repo CodyBisram/flim --body "$APPLE_TEAM_ID"
gh secret set MATCH_PASSWORD                 --repo CodyBisram/flim --body "$MATCH_PASSWORD"
gh secret set MATCH_GIT_URL                  --repo CodyBisram/flim --body "$MATCH_GIT_URL"
gh secret set MATCH_GIT_BASIC_AUTHORIZATION  --repo CodyBisram/flim --body "<paste base64 from Step 7>"
```

Verify:

```bash
gh secret list --repo CodyBisram/flim
```

You should see all 7.

---

## Step 9 — Go live

Merge this branch's PR into `main`. The push triggers the `deploy` job, which builds,
signs, and uploads. In ~10–20 min the build shows up under your app in
**App Store Connect → TestFlight** (state "Processing" first, then ready to test).

To trigger a build without a code change: **Actions → iOS · TestFlight → Run workflow**.

---

## Give your cousin access

He owns the GitHub repo already. To let him manage the app on Apple's side without
paying for his own membership, invite him to **your** team:

- **App Store Connect** → <https://appstoreconnect.apple.com/access/users> → **+** →
  his email → role **App Manager** (can manage TestFlight, builds, testers) or **Admin**
  (everything except legal/banking). He accepts the email invite and signs in with his
  own Apple ID — no second $99 fee.
- The **Account Holder** role can't be shared; that stays you (the membership owner).

He'll also want to be a tester: add him under **TestFlight → Internal Testing** (internal
testers must be in Users and Access; up to 100, builds available immediately, no Apple review).

---

## Day-to-day

| You do | CI does |
|---|---|
| Open a PR | Simulator build (compile check) |
| Merge to `main` | Sign + upload a new TestFlight build, auto-incrementing the build number |
| Bump the app version | Edit `MARKETING_VERSION` in `project.yml` (e.g. `1.1`) |

Build numbers are set automatically to *(highest build on TestFlight) + 1* — you never
touch them. The marketing version (`1.0`, `1.1`, …) lives in `project.yml`.

---

## Cost note

The repo is private and macOS Actions minutes bill at **10×**. A build is ~10–15 wall
minutes ≈ 100–150 billed minutes. The free tier is 2,000 min/month, so ~13–20 builds.
If you outgrow it: deploy only on version tags, or move to Xcode Cloud (25 free hrs/mo).

---

## Troubleshooting

- **`No profiles for 'com.flim.app' were found` / cert errors in CI** — the match repo
  wasn't seeded (Step 6) or `MATCH_GIT_BASIC_AUTHORIZATION` is wrong. Re-run Step 6
  locally, recheck Step 7.
- **`Provisioning profile doesn't include the aps-environment entitlement`** — Push
  isn't enabled on the App ID (Step 1.3). Enable it, then re-run Step 6 so match
  regenerates the profile.
- **`There is no app with bundle identifier com.flim.app`** — the App Store Connect app
  record (Step 2) doesn't exist yet, or the API key lacks access.
- **`bundle exec fastlane` can't find Ruby/bundler locally** — install a modern Ruby
  (`brew install ruby` or use rbenv); the system Ruby 2.6 is too old for some gems.
- **Xcode version mismatch on the runner** — if `latest-stable` isn't Xcode 26.x yet,
  pin `xcode-version:` in `.github/workflows/ios-testflight.yml` to the exact version.
</content>
