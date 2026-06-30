#!/usr/bin/env bash
#
# One-time TestFlight CI setup for FLIM.
#
# Run AFTER you've done the Apple-side steps in docs/TESTFLIGHT_SETUP.md:
#   1. Registered the App ID com.flim.app (with Push Notifications)
#   2. Created the FLIM app record in App Store Connect
#   3. Generated an App Store Connect API key (.p8 downloaded)
#   4. Noted your Team ID
#
# This script then seeds fastlane match and sets the 7 GitHub Actions secrets.
# Secrets are read with hidden prompts and never printed or echoed.
#
# Usage:  ./scripts/setup-testflight.sh
#
set -euo pipefail

REPO="CodyBisram/flim"
MATCH_REPO_URL="https://github.com/wiggapony0925/flim-certificates.git"
cd "$(dirname "$0")/.."

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ask()  { local p="$1" v; read -r -p "$p: " v; printf '%s' "$v"; }
asks() { local p="$1" v; read -r -s -p "$p: " v; printf '\n' >&2; printf '%s' "$v"; }

bold "FLIM · TestFlight setup"
echo "Make sure you've finished the Apple-side steps in docs/TESTFLIGHT_SETUP.md first."
echo

# --- prerequisites --------------------------------------------------------
command -v gh   >/dev/null || { echo "✗ gh (GitHub CLI) not found"; exit 1; }
command -v bundle >/dev/null || { echo "✗ bundler not found — run: gem install bundler"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ Not logged into gh — run: gh auth login"; exit 1; }
GH_USER="$(gh api user --jq '.login')"
echo "✓ gh authenticated as $GH_USER"
echo

# --- collect values -------------------------------------------------------
bold "Enter your values (from docs/TESTFLIGHT_SETUP.md steps 3-4):"
APPLE_TEAM_ID="$(ask 'Apple Team ID (10 chars, e.g. A1B2C3D4E5)')"
ASC_KEY_ID="$(ask 'App Store Connect Key ID')"
ASC_ISSUER_ID="$(ask 'App Store Connect Issuer ID')"
P8_PATH="$(ask 'Path to the .p8 file (e.g. ~/Downloads/AuthKey_XXXX.p8)')"
P8_PATH="${P8_PATH/#\~/$HOME}"
[ -f "$P8_PATH" ] || { echo "✗ No file at: $P8_PATH"; exit 1; }
MATCH_PASSWORD="$(asks 'Choose a match passphrase (encrypts the certs — remember it)')"
echo
bold "GitHub PAT for CI to read the certs repo:"
echo "Create one at https://github.com/settings/personal-access-tokens/new"
echo "  → owner $GH_USER · repo flim-certificates only · Contents: Read-only"
CERTS_PAT="$(asks 'Paste the PAT')"

export APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID MATCH_PASSWORD
export ASC_KEY_P8="$(base64 -i "$P8_PATH" | tr -d '\n')"
export MATCH_GIT_URL="$MATCH_REPO_URL"
MATCH_GIT_BASIC_AUTHORIZATION="$(printf '%s:%s' "$GH_USER" "$CERTS_PAT" | base64 | tr -d '\n')"

# --- seed signing assets --------------------------------------------------
echo
bold "Installing fastlane + seeding signing certificates (match)…"
bundle install
bundle exec fastlane certificates
echo "✓ Distribution cert + App Store profile pushed to flim-certificates"

# --- set GitHub secrets ---------------------------------------------------
echo
bold "Setting GitHub Actions secrets on $REPO…"
gh secret set ASC_KEY_ID                    --repo "$REPO" --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID                 --repo "$REPO" --body "$ASC_ISSUER_ID"
gh secret set ASC_KEY_P8                     --repo "$REPO" --body "$ASC_KEY_P8"
gh secret set APPLE_TEAM_ID                  --repo "$REPO" --body "$APPLE_TEAM_ID"
gh secret set MATCH_PASSWORD                 --repo "$REPO" --body "$MATCH_PASSWORD"
gh secret set MATCH_GIT_URL                  --repo "$REPO" --body "$MATCH_GIT_URL"
gh secret set MATCH_GIT_BASIC_AUTHORIZATION  --repo "$REPO" --body "$MATCH_GIT_BASIC_AUTHORIZATION"

echo
bold "✅ Done. Secrets set:"
gh secret list --repo "$REPO"
echo
echo "Next: merge PR #1 into main → first TestFlight build goes up automatically."
echo "  gh pr merge 1 --repo $REPO --squash"
