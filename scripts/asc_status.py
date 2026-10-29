#!/usr/bin/env python3
"""Read-only App Store Connect status for FLIM: each recent version, its build and review state.

Credentials come from the environment, the same three the TestFlight pipeline uses:
ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 (the .p8 PEM, or a base64 blob of it) or ASC_KEY_PATH
(a .p8 file). `--beta` reads FLIM Beta's TestFlight builds and tester groups instead. It only ever GETs, and never prints the key or the token. Run by the
`App Store status` workflow (.github/workflows/asc-status.yml), or locally with those variables.
"""
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

BUNDLE_ID = "com.flim.app"
BETA_BUNDLE_ID = "com.flim.app.beta"
API = "https://api.appstoreconnect.apple.com"


def private_key():
    raw = os.environ.get("ASC_KEY_P8", "").strip()
    if raw:
        return raw if "BEGIN" in raw else base64.b64decode(raw).decode()
    path = os.environ.get("ASC_KEY_PATH", "").strip()
    if path:
        return pathlib.Path(path).expanduser().read_text()
    sys.exit("set ASC_KEY_P8 or ASC_KEY_PATH")


def token():
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID"):
        if not os.environ.get(name, "").strip():
            sys.exit(f"set {name}")
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 600,
         "aud": "appstoreconnect-v1"},
        private_key(), algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def get(path, bearer):
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code} on {path.split('?')[0]}: {error.read().decode()[:300]}")


def soft_get(path, bearer):
    """`get` for a read the key may not be allowed: None instead of stopping the report."""
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        print(f"(HTTP {error.code} on {path.split('?')[0]})")
        return None


def fetch_versions():
    """The app's four most recent App Store versions, newest first:
    [{"version", "build", "state", "created"}]."""
    bearer = token()
    # The filter is not an exact match: since FLIM Beta (com.flim.app.beta) exists it returns both
    # apps, and taking the first one watched the beta, which has no App Store versions at all
    # ("no App Store version 1.6.3 found", 2026-10-27). Only the app whose bundle id IS ours.
    apps = [app for app in get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name,bundleId",
                               bearer)["data"]
            if app.get("attributes", {}).get("bundleId") == BUNDLE_ID]
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    versions = get(f"/v1/apps/{apps[0]['id']}/appStoreVersions?limit=4"
                   "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,createdDate,build"
                   "&include=build&fields[builds]=version", bearer)
    builds = {b["id"]: b["attributes"].get("version")
              for b in versions.get("included", []) if b["type"] == "builds"}
    rows = []
    for version in versions["data"]:
        attrs = version["attributes"]
        link = (version.get("relationships", {}).get("build") or {}).get("data")
        rows.append({
            "version": attrs["versionString"],
            "build": builds.get(link["id"]) if link else None,
            "state": attrs.get("appVersionState") or attrs.get("appStoreState"),
            "created": attrs.get("createdDate") or "",
        })
    return sorted(rows, key=lambda r: r["created"], reverse=True)


def beta_report():
    """FLIM Beta's TestFlight side: its latest builds (processing and internal/external testing
    state) and its tester groups (counts only, never who). FLIM Beta has no App Store versions."""
    bearer = token()
    apps = [app for app in get(f"/v1/apps?filter[bundleId]={BETA_BUNDLE_ID}&fields[apps]=name,bundleId",
                               bearer)["data"]
            if app.get("attributes", {}).get("bundleId") == BETA_BUNDLE_ID]
    if not apps:
        sys.exit(f"no app with bundle id {BETA_BUNDLE_ID}")
    app_id = apps[0]["id"]
    builds = get(f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"
                 "&fields[builds]=version,processingState,uploadedDate,expired,buildBetaDetail"
                 "&include=buildBetaDetail"
                 "&fields[buildBetaDetails]=internalBuildState,externalBuildState", bearer)
    details = {d["id"]: d["attributes"] for d in builds.get("included", [])
               if d["type"] == "buildBetaDetails"}
    if not builds["data"]:
        print("ASC_BETA no builds")
    for build in builds["data"]:
        attrs = build["attributes"]
        link = (build.get("relationships", {}).get("buildBetaDetail") or {}).get("data")
        detail = details.get(link["id"], {}) if link else {}
        in_groups = soft_get(f"/v1/builds/{build['id']}/betaGroups?fields[betaGroups]=name", bearer)
        groups = [g["attributes"].get("name") for g in in_groups["data"]] if in_groups else "?"
        print(f"ASC_BETA build={attrs.get('version')} processing={attrs.get('processingState')} "
              f"internal={detail.get('internalBuildState')} external={detail.get('externalBuildState')} "
              f"expired={attrs.get('expired')} uploaded={attrs.get('uploadedDate')} "
              f"groups={groups or '-'}")
    listed = soft_get(f"/v1/apps/{app_id}/betaGroups?limit=50"
                      "&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds", bearer)
    if listed is None:
        return
    groups = listed["data"]
    if not groups:
        print("ASC_BETA_GROUP none")
    for group in groups:
        attrs = group["attributes"]
        members = soft_get(f"/v1/betaGroups/{group['id']}/betaTesters?limit=200&fields[betaTesters]=state",
                           bearer)
        testers = len(members["data"]) if members else "?"
        states = sorted({m["attributes"].get("state") for m in members["data"]}) if members else "?"
        print(f"ASC_BETA_GROUP {attrs.get('name')} internal={attrs.get('isInternalGroup')} "
              f"all_builds={attrs.get('hasAccessToAllBuilds')} testers={testers} states={states}")


def main():
    if "--beta" in sys.argv:
        beta_report()
        return
    for row in fetch_versions():
        print(f"ASC_STATUS {row['version']} build={row['build'] or '-'} state={row['state']}")


if __name__ == "__main__":
    main()
