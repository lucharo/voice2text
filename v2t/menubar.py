"""Build and launch the optional one-file macOS menu-bar app.

Two ways the bundle reaches a Mac. `v2t menubar install` compiles it on this Mac
into ~/Applications with this user's paths baked into Info.plist. `v2t menubar
build DIR` compiles a bundle for other Macs (the release script signs it with
Developer ID and notarises it): nothing user-specific is baked, and the Swift
shell falls back to ~/.v2t and the `uv tool` interpreter at launch.
"""

from __future__ import annotations

import fcntl
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from importlib.resources import as_file, files
from pathlib import Path

from . import __version__, config

APP_NAME = "Voice2Text.app"
BUNDLE_ID = "com.lucharo.voice2text"
SYSTEM_APPLICATIONS = Path("/Applications")  # where `brew install --cask voice2text` puts the app


def user_app_path() -> Path:
    """Where `v2t menubar install` puts its locally compiled bundle."""
    return Path.home() / "Applications" / APP_NAME


def app_path() -> Path:
    """The bundle to open and to start at login: a Homebrew cask install in
    /Applications wins over the per-user build, so `brew install --cask voice2text`
    and `v2t menubar install` never race for the permission identity."""
    system = SYSTEM_APPLICATIONS / APP_NAME
    if (system / "Contents" / "MacOS" / "Voice2Text").is_file():
        return system
    return user_app_path()


def app_executable() -> Path:
    return app_path() / "Contents" / "MacOS" / "Voice2Text"


def installed() -> bool:
    return app_executable().is_file()


def running() -> bool:
    """Whether the menu app owns its single-instance lock."""
    path = config.run_dir() / "menubar.lock"
    if not path.exists():
        return False
    with path.open("a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def signing_identity() -> str:
    """Prefer a Developer ID identity (runs on any Mac), then a local development one."""
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
    )
    identities = re.findall(r'"([^"]+)"', result.stdout)
    for prefix in ("Developer ID Application:", "Apple Development:"):
        for identity in identities:
            if identity.startswith(prefix):
                return identity
    return "-"


def signing_flags(identity: str) -> list[str]:
    """Hardened runtime always (the audio-input entitlement is passed separately);
    a secure timestamp when the signature is Developer ID."""
    flags = ["--options", "runtime"]
    if identity.startswith("Developer ID Application:"):
        flags.append("--timestamp")
    return flags


def build(bundle: Path, *, bake_paths: bool = True, identity: str | None = None) -> Path:
    """Compile the bundled Swift source into a small, grantable app bundle at
    `bundle` (a `.app` path; anything already there is replaced only once the
    new bundle has compiled and signed, so a failure leaves no half-built app).

    With `bake_paths`, Info.plist carries this user's v2t home, interpreter and
    config so the shell needs no discovery. Without it the bundle is portable:
    the shell falls back to ~/.v2t and the `uv tool` interpreter of whoever
    launches it. `identity` defaults to the best one in the keychain."""
    if sys.platform != "darwin":
        raise SystemExit("the Voice2Text menu app is macOS-only")
    bundle.parent.mkdir(parents=True, exist_ok=True)
    # Staged next to the destination so the final move is a rename.
    with tempfile.TemporaryDirectory(dir=bundle.parent) as temporary:
        staged = _compile(Path(temporary) / bundle.name, bake_paths=bake_paths, identity=identity)
        if bundle.exists():
            shutil.rmtree(bundle)
        shutil.move(staged, bundle)
    return bundle


def _compile(bundle: Path, *, bake_paths: bool, identity: str | None) -> Path:
    source = files("v2t").joinpath("native", "Voice2Text.swift")
    entitlements = files("v2t").joinpath("native", "Voice2Text.entitlements.plist")
    contents = bundle / "Contents"
    executable = contents / "MacOS" / "Voice2Text"
    executable.parent.mkdir(parents=True)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "Voice2Text",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Voice2Text",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": __version__,
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription": "Voice2Text uses the microphone for fully local transcription.",
        "NSPrincipalClass": "NSApplication",
    }
    if bake_paths:
        info["V2THome"] = str(config.home())
        info["V2TPythonExecutable"] = sys.executable
        if custom_config := os.environ.get("V2T_CONFIG"):
            info["V2TConfig"] = str(Path(custom_config).expanduser())
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    with as_file(source) as source_path, as_file(entitlements) as entitlements_path:
        subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-parse-as-library",
                str(source_path),
                "-o",
                str(executable),
                "-framework",
                "AppKit",
                "-framework",
                "AVFoundation",
                "-framework",
                "ApplicationServices",
            ],
            check=True,
        )
        executable.chmod(0o755)
        if identity is None:
            identity = signing_identity()
        subprocess.run(
            [
                "codesign",
                "--force",
                *signing_flags(identity),
                "--entitlements",
                str(entitlements_path),
                "--sign",
                identity,
                str(bundle),
            ],
            check=True,
        )
    return bundle


def install() -> Path:
    """Compile the menu app for this user into ~/Applications."""
    if sys.platform != "darwin":
        raise SystemExit("the Voice2Text menu app is macOS-only")
    if running():
        raise SystemExit("quit Voice2Text before updating the menu app")
    return build(user_app_path(), bake_paths=True)


def open_app(bundle: Path | None = None) -> None:
    bundle = bundle or app_path()
    if not (bundle / "Contents" / "MacOS" / "Voice2Text").is_file():
        raise SystemExit("menu app is not installed; run: v2t menubar install")
    subprocess.run(["open", str(bundle)], check=True)
