"""Read the three macOS privacy grants v2t needs, without prompting."""

from __future__ import annotations

import sys
import threading


def statuses() -> dict[str, str]:
    if sys.platform != "darwin":
        return {"microphone": "unknown", "accessibility": "unknown", "input": "unknown"}

    from ApplicationServices import AXIsProcessTrusted, CGPreflightListenEventAccess

    accessibility = "granted" if AXIsProcessTrusted() else "missing"
    input_monitoring = "granted" if CGPreflightListenEventAccess() else "missing"
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

        microphone = {
            0: "not-requested",
            1: "restricted",
            2: "denied",
            3: "granted",
        }.get(
            int(AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)),
            "unknown",
        )
    except ImportError:
        microphone = "unknown"
    return {
        "microphone": microphone,
        "accessibility": accessibility,
        "input": input_monitoring,
    }


def request_microphone(timeout: float = 60) -> bool:
    """Ask macOS for microphone access once, waiting for the user's choice."""
    from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

    current = int(AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio))
    if current != 0:
        return current == 3

    answered = threading.Event()
    granted = False

    def complete(value):
        nonlocal granted
        granted = bool(value)
        answered.set()

    AVCaptureDevice.requestAccessForMediaType_completionHandler_(
        AVMediaTypeAudio, complete
    )
    answered.wait(timeout)
    return granted
