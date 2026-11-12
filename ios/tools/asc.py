#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]==2.10.1"]
# ///
"""The App Store Connect calls .github/workflows/testflight.yml and appstore.yml need. Reads ASC_KEY_PATH,
ASC_KEY_ID and ASC_ISSUER_ID from the environment.

    uv run tools/asc.py next-build         print one above the latest uploaded build number
    uv run tools/asc.py profiles <dir>     install the profiles ExportOptions-manual.plist names into <dir>
    uv run tools/asc.py wait <build>       wait until Apple has finished processing a build, fail if it refused it
    uv run tools/asc.py status             print App Store versions, review submissions and recent builds' states
    uv run tools/asc.py release <tag> [--whats-new <file>] [--dry-run]
                                           submit a TestFlight build for App Store review (see `release` below)

`wait` exists because an upload that succeeds can still fail Apple's processing, and such a build may never
appear in the build list, so running out of time here means the build was refused or Apple is slow.

`release ios-v1.1` submits the newest processed build of version 1.1; `release ios-v1.1-104` submits build 104,
which must be version 1.1. It reuses the App Store version, the build link and any draft or rejected submission
it finds, so a rerun after a failure picks up where the last one stopped, and a rerun after a successful
submission changes nothing. `--dry-run` makes only GET calls: it prints each change it would make, then checks
the listing and exits 1 if something a review needs is missing.
"""
import base64
import json
import os
import plistlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6831059370"  # "v2t" in App Store Connect
EXPORT_OPTIONS = Path(__file__).with_name("ExportOptions-manual.plist")
WAIT_MINUTES = 30  # Apple: processing takes up to 30 minutes
POLL_SECONDS = 30
RETRYABLE = {408, 429, 500, 502, 503, 504}  # HTTP statuses that mean "try again shortly"
TAG = re.compile(r"ios-v(?P<version>\d+\.\d+(?:\.\d+)?)(?:-(?P<build>\d+))?")

# appVersionState values. A version in EDITABLE takes a new build and listing changes; one in SUBMITTED is with
# Apple or past review, so a rerun leaves it alone.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
            "INVALID_BINARY"}
SUBMITTED = {"WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
             "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION", "WAITING_FOR_EXPORT_COMPLIANCE"}
RELEASED = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}
# Screenshot sets App Review accepts for an app that runs on iPhone and iPad (TARGETED_DEVICE_FAMILY "1,2").
IPHONE_SETS = {"APP_IPHONE_69", "APP_IPHONE_67", "APP_IPHONE_65"}
IPAD_SETS = {"APP_IPAD_PRO_3GEN_129", "APP_IPAD_PRO_129"}
# Age rating fields that stay empty on a complete declaration: overrides, the kids band, an optional link. The
# last two were empty when 1.1 was submitted on 12 Nov 2026 (the run printed "age rating (unanswered:
# socialMediaAgeRestricted, gracRatingClassificationNumber)") and Apple accepted the submission anyway (#132).
OPTIONAL_RATING_FIELDS = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
                          "developerAgeRatingInfoUrl", "socialMediaAgeRestricted", "gracRatingClassificationNumber"}


class ApiError(Exception):
    def __init__(self, method: str, path: str, status: int, body: str):
        self.status = status
        try:
            errors = json.loads(body).get("errors", [])
        except ValueError:
            errors = []
        lines = [f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in errors] or [body[:500]]
        for e in errors:  # a refused review submission lists every missing item here
            for detail in (e.get("meta") or {}).get("associatedErrors", {}).values():
                lines += [f"  - {d.get('code')}: {d.get('detail') or d.get('title')}" for d in detail]
        self.detail = lines[0] if errors else f"HTTP {status}"
        super().__init__(f"{method} {path}: HTTP {status}\n" + "\n".join(lines))


def call(method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
    token = jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "aud": "appstoreconnect-v1", "exp": int(time.time()) + 600},
        Path(os.environ["ASC_KEY_PATH"]).read_text(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )
    version = "v2" if path.startswith("v2/") else "v1"
    path = path.removeprefix("v2/")
    url = f"{API}/{version}/{path}" + (f"?{urllib.parse.urlencode(params)}" if params else "")
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise ApiError(method, path, error.code, error.read().decode(errors="replace")) from None
    return json.loads(raw) if raw else {}


def get(path: str, **params: str):
    return call("GET", path, params)["data"]


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
        except (OSError, ApiError) as error:  # a blip here must not fail a build that uploaded
            if isinstance(error, ApiError) and error.status not in RETRYABLE:
                raise
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


def status() -> None:
    """Read-only: App Store versions, review submissions, and the external TestFlight state of recent builds."""
    for version in get(f"apps/{APP_ID}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "10"}):
        attributes = version["attributes"]
        print(f"App Store version {attributes['versionString']}: {state_of(version)}, "
              f"release {attributes.get('releaseType')}, created {attributes.get('createdDate')}")
    for submission in get("reviewSubmissions", **{"filter[app]": APP_ID, "limit": "10"}):
        attributes = submission["attributes"]
        print(f"review submission {submission['id']}: {attributes['state']}, submitted {attributes.get('submittedDate')}")
    builds = call("GET", "builds", {"filter[app]": APP_ID, "sort": "-uploadedDate", "limit": "200",
                                    "include": "buildBetaDetail,betaAppReviewSubmission,preReleaseVersion"})
    included = {(i["type"], i["id"]): i["attributes"] for i in builds.get("included", [])}

    def related(build: dict, name: str) -> dict:
        data = build["relationships"].get(name, {}).get("data")
        return included.get((data["type"], data["id"]), {}) if data else {}

    for index, build in enumerate(builds["data"]):
        review = related(build, "betaAppReviewSubmission").get("betaReviewState")
        if index >= 3 and not review:  # the newest three, and any build ever sent to external beta review
            continue
        print(f"build {related(build, 'preReleaseVersion').get('version')} ({build['attributes']['version']}): "
              f"{build['attributes']['processingState']}, external "
              f"{related(build, 'buildBetaDetail').get('externalBuildState')}, beta review "
              f"{review}")
    for group in get("betaGroups", **{"filter[app]": APP_ID}):
        testers = get(f"betaGroups/{group['id']}/betaTesters")
        kind = "internal" if group["attributes"].get("isInternalGroup") else "external"
        print(f"{kind} TestFlight group {group['attributes']['name']}: "
              f"{', '.join(t['attributes'].get('state') or '?' for t in testers) or 'no testers'}")


# --- release -------------------------------------------------------------------------------------------------


def state_of(version: dict) -> str:
    attributes = version["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState") or "UNKNOWN"


class Release:
    def __init__(self, tag: str, whats_new: str, dry_run: bool):
        match = TAG.fullmatch(tag)
        if not match:
            sys.exit(f"tag {tag!r} is not ios-v<version> or ios-v<version>-<build>, e.g. ios-v1.0 or ios-v1.0-104")
        self.version_string = match["version"]
        self.build_number = match["build"]
        self.whats_new = whats_new.strip()
        self.dry_run = dry_run

    def write(self, method: str, path: str, body: dict, what: str) -> dict:
        if self.dry_run:
            print(f"  would {what} ({method} {path})")
            return {}
        print(f"  {what}")
        return call(method, path, body=body)

    def pick_build(self) -> dict:
        params = {"filter[app]": APP_ID, "filter[preReleaseVersion.version]": self.version_string,
                  "sort": "-uploadedDate", "limit": "1"}
        if self.build_number:
            params["filter[version]"] = self.build_number
        else:
            params |= {"filter[processingState]": "VALID", "filter[expired]": "false"}
        found = get("builds", **params)
        if not found:
            wanted = f"build {self.build_number} of version" if self.build_number else "processed build of version"
            sys.exit(f"no {wanted} {self.version_string} on App Store Connect. A merge to main uploads one "
                     f"(testflight.yml); the version comes from MARKETING_VERSION in ios/project.yml.")
        build = found[0]
        attributes = build["attributes"]
        if attributes["processingState"] != "VALID" or attributes.get("expired"):
            sys.exit(f"build {attributes['version']} is {attributes['processingState']}"
                     f"{', expired' if attributes.get('expired') else ''}: Apple cannot review it")
        print(f"build {attributes['version']} of {self.version_string}, uploaded {attributes['uploadedDate']}")
        return build

    def app_store_version(self, versions: list[dict]) -> dict | None:
        """Find this version string, or rename the one editable version Apple keeps (it makes 1.0 with the app)."""
        mine = [v for v in versions if v["attributes"]["versionString"] == self.version_string]
        if mine:
            return mine[0]
        editable = [v for v in versions if state_of(v) in EDITABLE]
        if editable:
            version = editable[0]
            old = version["attributes"]["versionString"]
            self.write("PATCH", f"appStoreVersions/{version['id']}", {"data": {
                "type": "appStoreVersions", "id": version["id"],
                "attributes": {"versionString": self.version_string}}},
                f"rename the draft App Store version {old} to {self.version_string}")
            version["attributes"]["versionString"] = self.version_string
            return version
        created = self.write("POST", "appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": self.version_string, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
            f"create App Store version {self.version_string}")
        return created.get("data")

    def check_key(self) -> None:
        """Stop before anything else when the key's role cannot create an App Store version. The API has no call
        that names a key's role, so this reads the app's price, which needs the same role: the upload key in the
        testflight environment got FORBIDDEN_ERROR on both on 12 Nov (#132)."""
        try:
            get(f"apps/{APP_ID}/appPriceSchedule")
        except ApiError as error:
            if error.status != 403:
                return  # not a question of the key's role: check_app reports it with the rest of the listing
            sys.exit(f"the App Store Connect key {os.environ.get('ASC_KEY_ID')} cannot create an App Store version "
                     f"(App Store Connect refuses it the app's price: {error.detail.split(':')[0]}); release with "
                     f"an App Manager or Admin key, which appstore.yml reads from ASC_RELEASE_KEY_ID and "
                     f"ASC_RELEASE_KEY_P8")

    def run(self) -> None:
        self.check_key()
        versions = get(f"apps/{APP_ID}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "50"})
        first_release = not any(state_of(v) in RELEASED for v in versions)
        done = [v for v in versions if v["attributes"]["versionString"] == self.version_string
                and (state_of(v) in SUBMITTED or state_of(v) in RELEASED)]
        if done:  # a rerun after success: the build may have expired since, and that no longer matters
            self.already_submitted(done[0])
            return

        missing = []
        if not first_release and not self.whats_new:
            message = ("an update needs \"What's New\" text: tag with a message, e.g. "
                       f"git tag -a ios-v{self.version_string} -m \"Fixes the mic key after a call\"")
            if not self.dry_run:  # before any change, so a bad tag leaves nothing half done
                sys.exit(message)
            missing.append("What's New: the tag's message, which a dry run does not have")
        build = self.pick_build()
        version = self.app_store_version(versions)

        if version is None:  # dry run, and the version does not exist yet
            print("  (dry run: the version's own listing is checked once the real run creates it)")
            self.report(missing + self.check_app())
            return

        state = state_of(version)
        attached = get(f"appStoreVersions/{version['id']}/build") if version.get("id") else None
        print(f"App Store version {self.version_string}: {state}, build "
              f"{attached['attributes']['version'] if attached else 'none'}")
        if state not in EDITABLE:
            sys.exit(f"version {self.version_string} is {state}, which this script does not know how to handle")

        if version["attributes"].get("releaseType") != "AFTER_APPROVAL":
            self.write("PATCH", f"appStoreVersions/{version['id']}", {"data": {
                "type": "appStoreVersions", "id": version["id"], "attributes": {"releaseType": "AFTER_APPROVAL"}}},
                "release automatically once Apple approves")
        if not attached or attached["id"] != build["id"]:
            self.write("PATCH", f"appStoreVersions/{version['id']}/relationships/build",
                       {"data": {"type": "builds", "id": build["id"]}},
                       f"attach build {build['attributes']['version']}")

        localizations = get(f"appStoreVersions/{version['id']}/appStoreVersionLocalizations")
        if first_release:
            print("  first release: Apple shows no \"What's New\" for it, so none is set")
        elif self.whats_new:
            for localization in localizations:
                if (localization["attributes"].get("whatsNew") or "").strip() != self.whats_new:
                    self.write("PATCH", f"appStoreVersionLocalizations/{localization['id']}", {"data": {
                        "type": "appStoreVersionLocalizations", "id": localization["id"],
                        "attributes": {"whatsNew": self.whats_new}}},
                        f"set What's New ({localization['attributes']['locale']})")

        missing += self.check_listing(version, localizations)
        if missing and not self.dry_run:  # Apple's check at the submission below is the authoritative one
            print("this listing looks incomplete; Apple will say what it needs:\n  - " + "\n  - ".join(missing))
        self.submit(version)
        if self.dry_run:
            self.report(missing)

    def already_submitted(self, version: dict) -> None:
        state = state_of(version)
        attached = get(f"appStoreVersions/{version['id']}/build")
        number = attached["attributes"]["version"] if attached else None
        if self.build_number and number != self.build_number:
            sys.exit(f"version {self.version_string} is already {state} with build {number}, not "
                     f"{self.build_number}; cancel that in App Store Connect first, or tag a new version")
        print(f"nothing to do: version {self.version_string} is already {state} with build {number}")

    def submit(self, version: dict) -> None:
        submissions = get("reviewSubmissions", **{
            "filter[app]": APP_ID, "filter[platform]": "IOS",
            "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES,WAITING_FOR_REVIEW,IN_REVIEW", "limit": "10"})
        for submission in submissions:
            items = call("GET", f"reviewSubmissions/{submission['id']}/items",
                         {"include": "appStoreVersion"})["data"]
            ours = any((i["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == version["id"]
                       for i in items)
            state = submission["attributes"]["state"]
            if state in {"WAITING_FOR_REVIEW", "IN_REVIEW"}:
                if ours:
                    print(f"nothing to do: version {self.version_string} is already {state}")
                    return
                sys.exit(f"another submission ({submission['id']}) is {state}; Apple allows one at a time")
            for item in items:  # a rejected item blocks resubmission until it is marked resolved
                if item.get("attributes", {}).get("state") == "REJECTED":
                    self.write("PATCH", f"reviewSubmissionItems/{item['id']}", {"data": {
                        "type": "reviewSubmissionItems", "id": item["id"], "attributes": {"resolved": True}}},
                        "mark Apple's rejection resolved")
            break  # a draft or rejected submission: reuse it
        else:
            opened = self.write("POST", "reviewSubmissions", {"data": {
                "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
                "open a review submission")
            if self.dry_run:
                print(f"  would add version {self.version_string} to it and submit it for review")
                return
            submission, ours = opened["data"], False
        print(f"review submission {submission['id']}: {submission['attributes']['state']}")
        if not ours:
            self.write("POST", "reviewSubmissionItems", {"data": {
                "type": "reviewSubmissionItems", "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}},
                f"add version {self.version_string} to it")
        self.write("PATCH", f"reviewSubmissions/{submission['id']}", {"data": {
            "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}},
            "submit it for review")
        if not self.dry_run:
            state = get(f"reviewSubmissions/{submission['id']}")["attributes"]["state"]
            print(f"review submission {submission['id']} is now {state}")

    def check_listing(self, version: dict, localizations: list[dict]) -> list[str]:
        """What App Review needs that the public API can read. Privacy answers it cannot: Apple's check lists those."""
        missing = []

        def read(path: str, **params: str):
            try:
                return get(path, **params)
            except ApiError as error:
                missing.append(f"could not read {path}: HTTP {error.status}")
                return None

        if not version["attributes"].get("copyright"):
            missing.append("copyright (App Store version)")
        if not localizations:
            missing.append("an App Store version localization (description, keywords, support URL)")
        for localization in localizations:
            attributes, locale = localization["attributes"], localization["attributes"]["locale"]
            missing += [f"{field} ({locale})" for field in ("description", "keywords", "supportUrl")
                        if not attributes.get(field)]
            sets = read(f"appStoreVersionLocalizations/{localization['id']}/appScreenshotSets") or []
            counts = {}
            for screenshot_set in sets:
                shots = read(f"appScreenshotSets/{screenshot_set['id']}/appScreenshots") or []
                counts[screenshot_set["attributes"]["screenshotDisplayType"]] = len(shots)
            print(f"  screenshots ({locale}): {counts or 'none'}")
            for name, accepted in (("iPhone 6.9-inch", IPHONE_SETS), ("iPad 13-inch", IPAD_SETS)):
                if not any(counts.get(kind) for kind in accepted):
                    missing.append(f"{name} screenshots ({locale})")

        review = read(f"appStoreVersions/{version['id']}/appStoreReviewDetail")
        if not review:
            missing.append("App Review contact (name, phone, email)")
        else:
            missing += [f"App Review {field}" for field in ("contactFirstName", "contactLastName", "contactPhone",
                                                             "contactEmail") if not review["attributes"].get(field)]

        return missing + self.check_app()

    def check_app(self) -> list[str]:
        """The app-wide part of the listing, shared by every version."""
        missing = []

        def read(path: str, **params: str):
            try:
                return get(path, **params)
            except ApiError as error:
                missing.append(f"could not read {path}: HTTP {error.status}")
                return None

        app = read(f"apps/{APP_ID}")
        if app and not app["attributes"].get("contentRightsDeclaration"):
            missing.append("content rights declaration")
        infos = read(f"apps/{APP_ID}/appInfos") or []
        # the app info being edited, if a released one also exists
        infos.sort(key=lambda i: i["attributes"].get("state") == "READY_FOR_DISTRIBUTION")
        if infos:
            info = infos[0]
            for localization in read(f"appInfos/{info['id']}/appInfoLocalizations") or []:
                attributes = localization["attributes"]
                print(f"  name ({attributes['locale']}): {attributes.get('name')!r}, "
                      f"subtitle {attributes.get('subtitle')!r}")
                if not attributes.get("privacyPolicyUrl"):
                    missing.append(f"privacy policy URL ({attributes['locale']})")
            if not read(f"appInfos/{info['id']}/primaryCategory"):
                missing.append("primary category")
            rating = read(f"appInfos/{info['id']}/ageRatingDeclaration")
            unanswered = [k for k, v in (rating or {}).get("attributes", {}).items()
                          if v is None and k not in OPTIONAL_RATING_FIELDS]
            if not rating or unanswered:
                missing.append("age rating" + (f" (unanswered: {', '.join(unanswered)})" if unanswered else ""))
        for path, what in ((f"apps/{APP_ID}/appPriceSchedule", "price"),
                           (f"apps/{APP_ID}/appAvailabilityV2", "availability in countries")):
            try:
                get(path)
            except ApiError as error:
                missing.append(f"{what} ({error.detail if error.status != 404 else 'not set'})")
        return missing

    def report(self, missing: list[str]) -> None:
        print("App privacy answers: the public API cannot read them; a real run's submission lists them if missing")
        if missing:
            sys.exit("missing before App Review can take it:\n  - " + "\n  - ".join(missing))
        print("dry run: the listing has everything the API can check")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["next-build"]:
            next_build()
        case ["profiles", directory]:
            install_profiles(Path(directory))
        case ["wait", build]:
            try:
                wait_for_build(build)
            except ApiError as error:
                sys.exit(str(error))
        case ["status"]:
            status()
        case ["release", tag, *options]:
            dry_run = "--dry-run" in options
            options = [o for o in options if o != "--dry-run"]
            match options:
                case []:
                    whats_new = ""
                case ["--whats-new", path]:
                    whats_new = Path(path).read_text()
                case _:
                    sys.exit(__doc__)
            try:
                Release(tag, whats_new, dry_run).run()
            except ApiError as error:
                sys.exit(str(error))
        case _:
            sys.exit(__doc__)
