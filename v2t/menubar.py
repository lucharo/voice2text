"""Build and launch the optional one-file macOS menu-bar app."""

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


def app_path() -> Path:
    return Path.home() / "Applications" / APP_NAME


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
    """Use a stable local development identity when one is already available."""
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
    )
    identities = re.findall(r'"([^"]+)"', result.stdout)
    return next(
        (identity for identity in identities if identity.startswith("Apple Development:")),
        "-",
    )


def install() -> Path:
    """Compile the bundled Swift source into a small, grantable app bundle."""
    if sys.platform != "darwin":
        raise SystemExit("the Voice2Text menu app is macOS-only")
    if running():
        raise SystemExit("quit Voice2Text before updating the menu app")
    destination = app_path()
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = files("v2t").joinpath("native", "Voice2Text.swift")
    with as_file(source) as source_path, tempfile.TemporaryDirectory(
        dir=destination.parent
    ) as temporary:
        bundle = Path(temporary) / APP_NAME
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
            "V2THome": str(config.home()),
            "V2TPythonExecutable": sys.executable,
        }
        if custom_config := os.environ.get("V2T_CONFIG"):
            info["V2TConfig"] = str(Path(custom_config).expanduser())
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
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
        subprocess.run(
            [
                "codesign",
                "--force",
                "--deep",
                "--sign",
                signing_identity(),
                str(bundle),
            ],
            check=True,
        )
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(bundle, destination)
    return destination


def open_app() -> None:
    if not installed():
        raise SystemExit("menu app is not installed; run: v2t menubar install")
    subprocess.run(["open", str(app_path())], check=True)
