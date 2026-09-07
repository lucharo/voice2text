"""Reproduce issue #14: PortAudio's device list goes stale when the default mic changes.

Not user-facing and not packaged: a maintainer probe. macOS has no built-in CLI
to switch the input device, so this drives CoreAudio through ctypes: it moves
the system default input to the named device, asks PortAudio which input it
would open with and without a re-init, opens a 16 kHz stream each time, then
restores the original default. It refuses to run while the current default
input is in use by another app (a call), so it never yanks a live microphone.

    uv run python utils/mic_switch/probe_mic_switch.py "MacBook Pro Microphone"

Expected on a fixed build: the "no refresh" line still names the old device,
the "refreshed" line names the target. Device names come from
`uv run python -m sounddevice`.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import sys
import time

import sounddevice as sd

coreaudio = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))
corefoundation = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
corefoundation.CFStringGetCString.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_long,
    ctypes.c_uint32,
]

SYSTEM_OBJECT = 1
UTF8 = 0x08000100


def fourcc(code: str) -> int:
    return int.from_bytes(code.encode(), "big")


class PropertyAddress(ctypes.Structure):
    _fields_ = [
        ("selector", ctypes.c_uint32),
        ("scope", ctypes.c_uint32),
        ("element", ctypes.c_uint32),
    ]


def address(selector: str) -> PropertyAddress:
    return PropertyAddress(fourcc(selector), fourcc("glob"), 0)


def get_property(obj: int, selector: str, ctype):
    addr = address(selector)
    size = ctypes.c_uint32(ctypes.sizeof(ctype))
    out = ctype()
    status = coreaudio.AudioObjectGetPropertyData(
        obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(out)
    )
    if status:
        raise OSError(f"CoreAudio {selector!r} on {obj}: status {status}")
    return out


def device_ids() -> list[int]:
    addr = address("dev#")
    size = ctypes.c_uint32()
    coreaudio.AudioObjectGetPropertyDataSize(
        SYSTEM_OBJECT, ctypes.byref(addr), 0, None, ctypes.byref(size)
    )
    ids = (ctypes.c_uint32 * (size.value // 4))()
    coreaudio.AudioObjectGetPropertyData(
        SYSTEM_OBJECT, ctypes.byref(addr), 0, None, ctypes.byref(size), ids
    )
    return list(ids)


def device_name(device: int) -> str:
    ref = get_property(device, "lnam", ctypes.c_void_p).value
    buffer = ctypes.create_string_buffer(256)
    corefoundation.CFStringGetCString(ref, buffer, 256, UTF8)
    return buffer.value.decode()


def default_input() -> int:
    return get_property(SYSTEM_OBJECT, "dIn ", ctypes.c_uint32).value


def set_default_input(device: int) -> None:
    addr = address("dIn ")
    value = ctypes.c_uint32(device)
    status = coreaudio.AudioObjectSetPropertyData(
        SYSTEM_OBJECT, ctypes.byref(addr), 0, None, 4, ctypes.byref(value)
    )
    if status:
        raise OSError(f"could not set default input: status {status}")


def in_use_elsewhere(device: int) -> bool:
    return bool(get_property(device, "gone", ctypes.c_uint32).value)


def portaudio_view(label: str) -> None:
    try:
        seen = sd.query_devices(kind="input")["name"]
    except Exception as error:
        seen = f"ERR {error}"
    try:
        stream = sd.InputStream(samplerate=16000, channels=1, dtype="float32")
        stream.start()
        stream.stop()
        stream.close()
        opened = "open OK"
    except Exception as error:
        opened = f"open FAILED: {error}"
    print(f"[{label}] PortAudio default input = {seen!r}; {opened}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    original = default_input()
    by_name = {device_name(d): d for d in device_ids()}
    if sys.argv[1] not in by_name:
        print(f"no device named {sys.argv[1]!r}; have: {sorted(by_name)}")
        return 2
    target = by_name[sys.argv[1]]
    print("system default:", device_name(original))
    if in_use_elsewhere(original):
        print("default input is in use by another app (a call?) — refusing to switch")
        return 1
    portaudio_view("before switch")
    set_default_input(target)
    time.sleep(0.5)
    try:
        print("system default now:", device_name(default_input()))
        portaudio_view("after switch, no refresh")
        sd._terminate()
        sd._initialize()
        portaudio_view("after switch, refreshed")
    finally:
        set_default_input(original)
        time.sleep(0.3)
        print("restored system default:", device_name(default_input()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
