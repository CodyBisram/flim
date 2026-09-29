#!/usr/bin/env python3
"""Read-only App Store Connect status for FLIM: each recent version, its build and review state.

Credentials come from the environment, the same three the TestFlight pipeline uses:
ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 (the .p8 PEM, or a base64 blob of it) or ASC_KEY_PATH
(a .p8 file). It only ever GETs, and never prints the key or the token. Run by the
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


def main():
    bearer = token()
    apps = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name", bearer)["data"]
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    versions = get(f"/v1/apps/{apps[0]['id']}/appStoreVersions?limit=4"
                   "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,build"
                   "&include=build&fields[builds]=version", bearer)
    builds = {b["id"]: b["attributes"].get("version")
              for b in versions.get("included", []) if b["type"] == "builds"}
    for version in versions["data"]:
        attrs = version["attributes"]
        link = (version.get("relationships", {}).get("build") or {}).get("data")
        build = builds.get(link["id"]) if link else None
        state = attrs.get("appVersionState") or attrs.get("appStoreState")
        print(f"ASC_STATUS {attrs['versionString']} build={build or '-'} state={state}")


if __name__ == "__main__":
    main()
