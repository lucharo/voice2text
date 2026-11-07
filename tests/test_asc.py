"""ios/tools/asc.py release: each state App Store Connect can be in makes the right calls, and only those.

The App Store Connect API is the one thing faked: FakeConnect answers GETs from its state and records every write.
"""
import importlib.util
import io
import re
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("asc", Path(__file__).resolve().parents[1] / "ios/tools/asc.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

APP = asc.APP_ID


def version(id: str, string: str, state: str, release: str = "AFTER_APPROVAL") -> dict:
    return {"type": "appStoreVersions", "id": id, "attributes": {
        "versionString": string, "appVersionState": state, "releaseType": release, "copyright": "2026 L"}}


def build(id: str, number: str, state: str = "VALID") -> dict:
    return {"type": "builds", "id": id, "attributes": {
        "version": number, "processingState": state, "expired": False, "uploadedDate": "2026-11-07"}}


class FakeConnect:
    """Enough of App Store Connect for `release`: a listing that is complete unless a test empties part of it."""

    def __init__(self, versions, builds, attached=None, submissions=(), items=None, whats_new=""):
        self.versions = versions
        self.builds = builds  # {version string: [builds, newest first]}
        self.attached = attached or {}  # {App Store version id: build}
        self.submissions = list(submissions)
        self.items = items or {}  # {submission id: [App Store version ids]}
        self.whats_new = whats_new
        self.screenshots = {"APP_IPHONE_67": 3, "APP_IPAD_PRO_3GEN_129": 2}
        self.writes = []

    def __call__(self, method, path, params=None, body=None):
        if method != "GET":
            self.writes.append((method, path))
            if path == "reviewSubmissions":
                return {"data": {"id": "new-sub", "attributes": {"state": "READY_FOR_REVIEW"}}}
            if path == "appStoreVersions":
                return {"data": version("new-ver", body["data"]["attributes"]["versionString"],
                                        "PREPARE_FOR_SUBMISSION")}
            return {}
        params = params or {}
        if path == "builds":
            found = self.builds.get(params["filter[preReleaseVersion.version]"], [])
            if "filter[version]" in params:
                found = [b for b in found if b["attributes"]["version"] == params["filter[version]"]]
            else:
                found = [b for b in found if b["attributes"]["processingState"] == "VALID"]
            return {"data": found[:1]}
        if path == f"apps/{APP}/appStoreVersions":
            return {"data": self.versions}
        if m := re.fullmatch(r"appStoreVersions/(.+)/build", path):
            return {"data": self.attached.get(m[1])}
        if re.fullmatch(r"appStoreVersions/.+/appStoreVersionLocalizations", path):
            return {"data": [{"id": "loc", "attributes": {
                "locale": "en-GB", "description": "d", "keywords": "k", "supportUrl": "u",
                "whatsNew": self.whats_new}}]}
        if path == "appStoreVersionLocalizations/loc/appScreenshotSets":
            return {"data": [{"id": kind, "attributes": {"screenshotDisplayType": kind}} for kind in self.screenshots]}
        if m := re.fullmatch(r"appScreenshotSets/(.+)/appScreenshots", path):
            return {"data": [{}] * self.screenshots[m[1]]}
        if re.fullmatch(r"appStoreVersions/.+/appStoreReviewDetail", path):
            return {"data": {"attributes": {"contactFirstName": "L", "contactLastName": "C",
                                            "contactPhone": "1", "contactEmail": "e"}}}
        if path == f"apps/{APP}":
            return {"data": {"attributes": {"contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"}}}
        if path == f"apps/{APP}/appInfos":
            return {"data": [{"id": "info", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        if path == "appInfos/info/appInfoLocalizations":
            return {"data": [{"attributes": {"locale": "en-GB", "name": "v2t", "privacyPolicyUrl": "p"}}]}
        if path == "appInfos/info/primaryCategory":
            return {"data": {"id": "PRODUCTIVITY"}}
        if path == "appInfos/info/ageRatingDeclaration":
            return {"data": {"attributes": {"gambling": False, "kidsAgeBand": None}}}
        if path in (f"apps/{APP}/appPriceSchedule", f"apps/{APP}/appAvailabilityV2"):
            return {"data": {"id": APP}}
        if path == "reviewSubmissions":
            wanted = params["filter[state]"].split(",")
            return {"data": [s for s in self.submissions if s["attributes"]["state"] in wanted]}
        if m := re.fullmatch(r"reviewSubmissions/(.+)/items", path):
            return {"data": [{"relationships": {"appStoreVersion": {"data": {"id": v}}}}
                             for v in self.items.get(m[1], [])]}
        if m := re.fullmatch(r"reviewSubmissions/(.+)", path):
            return {"data": {"attributes": {"state": "WAITING_FOR_REVIEW"}}}
        raise AssertionError(f"unexpected GET {path}")


def submission(id: str, state: str) -> dict:
    return {"id": id, "attributes": {"state": state}}


class Release(unittest.TestCase):
    def run_release(self, fake: FakeConnect, tag="ios-v1.0", whats_new="", dry_run=False) -> str:
        out = io.StringIO()
        with mock.patch.object(asc, "call", fake), redirect_stdout(out):
            asc.Release(tag, whats_new, dry_run).run()
        return out.getvalue()

    def test_first_release_attaches_the_newest_build_and_submits(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {"1.0": [build("b113", "113")]})

        self.run_release(fake)

        self.assertEqual(fake.writes, [
            ("PATCH", "appStoreVersions/v1/relationships/build"),
            ("POST", "reviewSubmissions"),
            ("POST", "reviewSubmissionItems"),
            ("PATCH", "reviewSubmissions/new-sub"),
        ])

    def test_manual_release_type_is_switched_to_after_approval(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION", release="MANUAL")],
                           {"1.0": [build("b113", "113")]}, attached={"v1": build("b113", "113")},
                           submissions=[submission("s1", "READY_FOR_REVIEW")], items={"s1": ["v1"]})

        self.run_release(fake)

        self.assertEqual(fake.writes, [("PATCH", "appStoreVersions/v1"), ("PATCH", "reviewSubmissions/s1")])

    def test_rerun_after_submission_changes_nothing(self):
        fake = FakeConnect([version("v1", "1.0", "WAITING_FOR_REVIEW")], {"1.0": [build("b113", "113")]},
                           attached={"v1": build("b113", "113")})

        out = self.run_release(fake)

        self.assertEqual(fake.writes, [])
        self.assertIn("nothing to do: version 1.0 is already WAITING_FOR_REVIEW", out)

    def test_pinned_build_differing_from_the_one_in_review_stops(self):
        fake = FakeConnect([version("v1", "1.0", "IN_REVIEW")],
                           {"1.0": [build("b113", "113"), build("b112", "112")]},
                           attached={"v1": build("b113", "113")})

        with self.assertRaisesRegex(SystemExit, "already IN_REVIEW with build 113, not 112"):
            self.run_release(fake, tag="ios-v1.0-112")
        self.assertEqual(fake.writes, [])

    def test_draft_left_by_a_failed_run_is_reused(self):
        fake = FakeConnect([version("v1", "1.0", "READY_FOR_REVIEW")], {"1.0": [build("b113", "113")]},
                           attached={"v1": build("b113", "113")},
                           submissions=[submission("s1", "READY_FOR_REVIEW")], items={"s1": ["v1"]})

        self.run_release(fake)

        self.assertEqual(fake.writes, [("PATCH", "reviewSubmissions/s1")])

    def test_empty_draft_gets_the_version_added(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {"1.0": [build("b113", "113")]},
                           attached={"v1": build("b113", "113")}, submissions=[submission("s1", "READY_FOR_REVIEW")])

        self.run_release(fake)

        self.assertEqual(fake.writes, [("POST", "reviewSubmissionItems"), ("PATCH", "reviewSubmissions/s1")])

    def test_rejected_submission_is_resubmitted_with_the_new_build(self):
        fake = FakeConnect([version("v1", "1.0", "REJECTED")], {"1.0": [build("b114", "114")]},
                           attached={"v1": build("b113", "113")},
                           submissions=[submission("s1", "UNRESOLVED_ISSUES")], items={"s1": ["v1"]})

        self.run_release(fake)

        self.assertEqual(fake.writes, [
            ("PATCH", "appStoreVersions/v1/relationships/build"), ("PATCH", "reviewSubmissions/s1")])

    def test_another_submission_in_review_stops_before_submitting(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {"1.0": [build("b113", "113")]},
                           attached={"v1": build("b113", "113")}, submissions=[submission("s9", "IN_REVIEW")])

        with self.assertRaisesRegex(SystemExit, "another submission .s9. is IN_REVIEW"):
            self.run_release(fake)
        self.assertEqual(fake.writes, [])

    def test_update_without_whats_new_stops_before_any_change(self):
        fake = FakeConnect([version("v1", "1.0", "READY_FOR_SALE"), version("v2", "1.1", "PREPARE_FOR_SUBMISSION")],
                           {"1.1": [build("b120", "120")]})

        with self.assertRaisesRegex(SystemExit, "needs \"What's New\""):
            self.run_release(fake, tag="ios-v1.1")
        self.assertEqual(fake.writes, [])

    def test_update_sets_whats_new(self):
        fake = FakeConnect([version("v1", "1.0", "READY_FOR_SALE"), version("v2", "1.1", "PREPARE_FOR_SUBMISSION")],
                           {"1.1": [build("b120", "120")]}, attached={"v2": build("b120", "120")})

        self.run_release(fake, tag="ios-v1.1", whats_new="Fixes the mic key\n")

        self.assertEqual(fake.writes, [("PATCH", "appStoreVersionLocalizations/loc"), ("POST", "reviewSubmissions"),
                                       ("POST", "reviewSubmissionItems"), ("PATCH", "reviewSubmissions/new-sub")])

    def test_draft_version_with_another_number_is_renamed(self):
        fake = FakeConnect([version("v1", "1.0", "READY_FOR_SALE"), version("v2", "1.1", "PREPARE_FOR_SUBMISSION")],
                           {"1.2": [build("b130", "130")]}, attached={"v2": build("b130", "130")},
                           whats_new="New")

        self.run_release(fake, tag="ios-v1.2", whats_new="New")

        self.assertEqual(fake.writes[0], ("PATCH", "appStoreVersions/v2"))

    def test_no_draft_version_creates_one(self):
        fake = FakeConnect([version("v1", "1.0", "READY_FOR_SALE")], {"1.1": [build("b120", "120")]},
                           whats_new="New")

        self.run_release(fake, tag="ios-v1.1", whats_new="New")

        self.assertEqual(fake.writes[:2], [("POST", "appStoreVersions"),
                                           ("PATCH", "appStoreVersions/new-ver/relationships/build")])

    def test_pinned_build_still_processing_stops(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")],
                           {"1.0": [build("b114", "114", state="PROCESSING")]})

        with self.assertRaisesRegex(SystemExit, "build 114 is PROCESSING"):
            self.run_release(fake, tag="ios-v1.0-114")
        self.assertEqual(fake.writes, [])

    def test_no_build_of_the_version_stops(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {})

        with self.assertRaisesRegex(SystemExit, "no processed build of version 1.0"):
            self.run_release(fake)

    def test_tag_of_the_wrong_shape_stops(self):
        with self.assertRaisesRegex(SystemExit, "is not ios-v<version>"):
            asc.Release("v1.0", "", dry_run=False)

    def test_dry_run_writes_nothing_and_passes_on_a_complete_listing(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {"1.0": [build("b113", "113")]})

        out = self.run_release(fake, dry_run=True)

        self.assertEqual(fake.writes, [])
        self.assertIn("would attach build 113", out)
        self.assertIn("would open a review submission", out)

    def test_dry_run_fails_listing_the_missing_screenshots(self):
        fake = FakeConnect([version("v1", "1.0", "PREPARE_FOR_SUBMISSION")], {"1.0": [build("b113", "113")]})
        fake.screenshots = {"APP_IPHONE_67": 3}

        with self.assertRaises(SystemExit) as stop:
            self.run_release(fake, dry_run=True)

        self.assertEqual(str(stop.exception),
                         "missing before App Review can take it:\n  - iPad 13-inch screenshots (en-GB)")
        self.assertEqual(fake.writes, [])


if __name__ == "__main__":
    unittest.main()
