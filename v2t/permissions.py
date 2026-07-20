"""Read the three macOS privacy grants v2t needs, without prompting."""

from __future__ import annotations

import sys


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
