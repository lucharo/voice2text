#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]==2.10.1"]
# ///
"""The App Store Connect calls .github/workflows/testflight.yml needs. Reads ASC_KEY_PATH, ASC_KEY_ID and
ASC_ISSUER_ID from the environment.

    uv run tools/asc.py next-build         print one above the latest uploaded build number
    uv run tools/asc.py profiles <dir>     install the profiles ExportOptions-manual.plist names into <dir>
    uv run tools/asc.py wait <build>       wait until Apple has finished processing a build, fail if it refused it

`wait` exists because an upload that succeeds can still fail Apple's processing, and such a build may never
appear in the build list, so running out of time here means the build was refused or Apple is slow.
"""
import base64
import json
import os
import plistlib
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6831059370"  # "v2t" in App Store Connect
EXPORT_OPTIONS = Path(__file__).with_name("ExportOptions-manual.plist")
WAIT_MINUTES = 30  # Apple: processing takes up to 30 minutes
POLL_SECONDS = 30


def get(path: str, **params: str) -> list[dict]:
    token = jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "aud": "appstoreconnect-v1", "exp": int(time.time()) + 600},
        Path(os.environ["ASC_KEY_PATH"]).read_text(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["data"]


def next_build() -> None:
    latest = get("builds", **{"filter[app]": APP_ID, "sort": "-uploadedDate", "limit": "1"})
    print(int(latest[0]["attributes"]["version"]) + 1)


def install_profiles(directory: Path) -> None:
    names = plistlib.loads(EXPORT_OPTIONS.read_bytes())["provisioningProfiles"].values()
    directory.mkdir(parents=True, exist_ok=True)
    for name in names:
        found = get("profiles", **{"filter[name]": name, "filter[profileState]": "ACTIVE"})
        if len(found) != 1:
            sys.exit(f'expected one active profile named "{name}", found {len(found)}')
        attributes = found[0]["attributes"]
        path = directory / f"{attributes['uuid']}.mobileprovision"
        path.write_bytes(base64.b64decode(attributes["profileContent"]))
        print(f'{name}: {path.name}, expires {attributes["expirationDate"]}')


def wait_for_build(build: str) -> None:
    deadline = time.monotonic() + WAIT_MINUTES * 60
    state = "not listed yet"
    while time.monotonic() < deadline:
        try:
            found = get("builds", **{"filter[app]": APP_ID, "filter[version]": build})
        except OSError as error:  # a blip here must not fail a build that uploaded
            print(f"build {build}: {error}, retrying", flush=True)
            time.sleep(POLL_SECONDS)
            continue
        if found:
            state = found[0]["attributes"]["processingState"]
            if state == "VALID":
                print(f"build {build} is processed and ready for TestFlight")
                return
            if state != "PROCESSING":
                sys.exit(f"Apple refused build {build}: {state}")
        print(f"build {build}: {state}", flush=True)
        time.sleep(POLL_SECONDS)
    sys.exit(f"build {build} is still '{state}' after {WAIT_MINUTES} minutes: refused by Apple, or Apple is slow")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["next-build"]:
            next_build()
        case ["profiles", directory]:
            install_profiles(Path(directory))
        case ["wait", build]:
            wait_for_build(build)
        case _:
            sys.exit(__doc__)
