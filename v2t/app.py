"""The push-to-talk engine: record on hotkey, transcribe, clean up, paste.

macOS-only at runtime (native pasteboard, System Events paste, global hotkey).
"""

from __future__ import annotations

import json
import os
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import sounddevice as sd
from loguru import logger
from scipy.io import wavfile

from . import backends, config, permissions
from .config import Config


MIC_PANE = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
FN_VK = 0x3F  # kVK_Function: the Fn / Globe key, bottom-left on Apple keyboards
GLOBE_KEY_FIX = (
    "System Settings → Keyboard → Press 🌐 key to → Do Nothing "
    "(the setting only takes effect from that pane, or after logging out and in; "
    "`defaults write com.apple.HIToolbox AppleFnUsageType -int 0` alone does not apply)"
)
LOUD_RMS = 0.01  # a 100 ms frame above this holds speech-level sound (full scale 1)
LEVEL_INTERVAL_S = 0.02  # the pill's waveform: at most one input level per 20 ms
# How long a cancelled dictation stays recoverable (pill, menu, Cmd+Z) before the
# audio is dropped: Gmail's default undo-send window, inside Material Design's
# 4-10 s snackbar range.
UNDO_WINDOW_S = 5.0
Z_VK = 6  # kVK_ANSI_Z
# PortAudio's stop can deadlock inside CoreAudio on macOS 26 (PortAudio#1174, open
# as of 19.7: Pa_StopStream holds the AudioUnit lock while the HAL IO thread holds
# its own and asks for the AudioUnit one). So the microphone stops on its own thread,
# never on the hotkey listener's (2026-10-07: the listener froze inside
# FinishStoppingStream, Fn and Esc died with it, and quitting the app left the mic
# held). A healthy stop took 105 ms at the median and 110 ms at most over 20 cycles
# on the built-in mic (2026-10-07); one still running after MIC_STUCK_S, thirty times
# that, is the deadlock, and the engine restarts itself once idle to free the mic.
MIC_STUCK_S = 3.0
# How long a new press waits for the last stop before declining to open the mic.
MIC_REOPEN_WAIT_S = 0.3
SOUND_PANE = "x-apple.systempreferences:com.apple.Sound-Settings.extension"


def _resolve_hotkey(name: str):
    from pynput import keyboard

    keys = {
        "fn": keyboard.KeyCode.from_vk(FN_VK),
        "cmd_r": keyboard.Key.cmd_r,
        "cmd_l": keyboard.Key.cmd_l,
        "alt_r": keyboard.Key.alt_r,
        "alt_l": keyboard.Key.alt_l,
        "ctrl_r": keyboard.Key.ctrl_r,
        "ctrl_l": keyboard.Key.ctrl_l,
    }
    if name not in keys:
        raise SystemExit(f"unknown hotkey {name!r}; choose: {', '.join(keys)}")
    return keys[name]


def _listener(on_press, on_release, suppress_escape=None, undo_shortcut=None):
    """pynput's global listener, taught the Fn key.

    Fn arrives as a flags-changed event like the other modifiers, but pynput
    has no flag on record for it, so it would report every Fn event as a
    release. Its flag is kCGEventFlagMaskSecondaryFn.
    """
    from pynput import keyboard
    from Quartz import kCGEventFlagMaskSecondaryFn

    class Listener(keyboard.Listener):
        _MODIFIER_FLAGS = {
            **keyboard.Listener._MODIFIER_FLAGS,
            keyboard.KeyCode.from_vk(FN_VK): kCGEventFlagMaskSecondaryFn,
        }

    options = {}
    if suppress_escape is not None:
        from Quartz import (
            CGEventGetFlags,
            CGEventGetIntegerValueField,
            kCGEventFlagMaskAlternate,
            kCGEventFlagMaskCommand,
            kCGEventFlagMaskControl,
            kCGEventFlagMaskShift,
            kCGEventKeyUp,
            kCGKeyboardEventKeycode,
        )

        others = kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate

        def intercept(_event_type, event):
            # pynput 1.8.1 calls on_press/on_release BEFORE darwin_intercept
            # (_util/darwin.py:290). Only swallow Esc handled by this dictation,
            # and Cmd+Z while a cancelled dictation can be recovered.
            keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)
            released = _event_type == kCGEventKeyUp
            if keycode == keyboard.Key.esc.value.vk and suppress_escape(released):
                return None
            if keycode == Z_VK and undo_shortcut is not None:
                flags = CGEventGetFlags(event)
                plain_command = flags & kCGEventFlagMaskCommand and not flags & others
                if (plain_command or released) and undo_shortcut(released):
                    return None
            return event

        options["darwin_intercept"] = intercept
    return Listener(on_press=on_press, on_release=on_release, **options)


def globe_key_warning() -> str:
    """Why a tap of Fn may still do something else, or '' when the key is free.

    System Settings → Keyboard → "Press 🌐 key to" opens the emoji picker or
    switches input source on a tap unless it is "Do Nothing"
    (AppleFnUsageType 0, which is not written until the setting is changed).
    """
    try:
        result = subprocess.run(
            ["defaults", "read", "com.apple.HIToolbox", "AppleFnUsageType"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:  # no `defaults`: not macOS, nothing to warn about
        return ""
    if result.returncode == 0 and result.stdout.strip() == "0":
        return ""
    return (
        'System Settings → Keyboard → "Press 🌐 key to" is not "Do Nothing", so a tap '
        f"of Fn may also open the emoji picker or switch input source. Fix: {GLOBE_KEY_FIX}"
    )


def audio_levels(audio: np.ndarray, sample_rate: int) -> dict:
    """Level facts about one recording, for its history row and the input warning.

    `loud_frac` is the share of 100 ms frames inside a run of three or more
    whose RMS is above LOUD_RMS: speech, not a click or the pop of a Bluetooth
    link opening. A dictation into a working microphone sits well above 0.1; a
    dead Bluetooth or virtual input gives about 0.
    """
    x = np.asarray(audio, dtype=np.float32).reshape(-1)
    if x.size == 0:
        return {"rms": 0.0, "peak": 0.0, "zero_frac": 1.0, "loud_frac": 0.0}
    frame = max(1, sample_rate // 10)
    frames = x[: x.size // frame * frame].reshape(-1, frame)
    loud = 0.0
    if len(frames):
        above = np.sqrt((frames**2).mean(axis=1)) > LOUD_RMS
        in_run = np.zeros(len(above), dtype=bool)
        edges = np.flatnonzero(np.diff(np.concatenate(([0], above.astype(int), [0]))))
        for start, stop in zip(edges[::2], edges[1::2]):  # each run of loud frames
            if stop - start >= 3:
                in_run[start:stop] = True
        loud = float(in_run.mean())
    return {
        "rms": round(float(np.sqrt((x**2).mean())), 5),
        "peak": round(float(np.abs(x).max()), 4),
        "zero_frac": round(float((x == 0).mean()), 4),
        "loud_frac": round(loud, 4),
    }


def level_warning(levels: dict, audio_s: float, device: str | None) -> str:
    """Why this recording probably did not carry the speech, or ''."""
    if audio_s < 1.0 or levels["peak"] < 1e-4 or levels["loud_frac"] >= 0.02:
        return ""
    where = f" from {device}" if device else ""
    return (
        f"Near-silent audio{where}: speech-level sound in "
        f"{levels['loud_frac']:.0%} of {audio_s:.0f}s (peak {levels['peak']:.2f}). "
        "Check System Settings → Sound → Input."
    )


def _default_input_name() -> str | None:
    """The input device a recording started now would use."""
    try:
        return str(sd.query_devices(kind="input")["name"])
    except Exception:
        return None


def _notify(title: str, text: str) -> None:
    """A macOS notification, best effort (Notification Center may be muted)."""

    def quote(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                f"display notification {quote(text)} with title {quote(title)}",
            ],
            capture_output=True,
            check=False,
        )
    except OSError:  # no osascript: not macOS
        pass


def _tail(text: str, limit: int = 80) -> str:
    """The last `limit` characters of a partial transcript, cut on a word."""
    flat = " ".join(text.split())
    if len(flat) <= limit:
        return flat
    return flat[-limit:].split(" ", 1)[-1]


def check_and_request_permissions() -> bool:
    """Fail early with the exact macOS permission panes that still need a grant.

    Returns True when Microphone access was granted just now. CoreAudio was
    already initialised in this process before the grant landed, so the caller
    must re-exec before the microphone can actually be opened (issue #7).
    """
    logger.info("Checking permissions...")
    states = permissions.statuses()
    newly_granted = False
    if states["microphone"] == "not-requested":
        logger.info("Requesting Microphone permission...")
        newly_granted = permissions.request_microphone()
        states["microphone"] = "granted" if newly_granted else "denied"
    checks = [
        ("Microphone", states["microphone"] == "granted", "Privacy_Microphone"),
        (
            "Accessibility",
            states["accessibility"] == "granted",
            "Privacy_Accessibility",
        ),
    ]
    missing = [(name, pane) for name, granted, pane in checks if not granted]
    if missing:
        names = " + ".join(name for name, _pane in missing)
        message = f"Grant {names} to the launching app, restart that app, then start v2t again."
        config.write_last_error(message)
        logger.error(message)
        security = "x-apple.systempreferences:com.apple.preference.security"
        for _name, pane in missing:
            subprocess.run(["open", f"{security}?{pane}"], check=False)
        raise SystemExit(1)
    logger.success("Permissions OK")
    return newly_granted


class LiveTranscription:
    """A recording being transcribed while it is still going (issue #12).

    Made on the hotkey thread when recording starts and queued like a finished
    recording; the processing thread, which owns the model, feeds `frames` (the
    very list the audio callback appends to) into the streaming recogniser
    until the hotkey thread calls `finish` or `cancel`.
    """

    def __init__(self, frames: list[np.ndarray]):
        self.frames = frames
        self.fed = 0  # frames already handed to the feeder
        self.done = threading.Event()
        self.cancelled = False
        self.duration = 0.0
        self.stopped_at = 0.0

    def finish(self, duration: float) -> None:
        self.duration = duration
        self.stopped_at = time.perf_counter()
        self.done.set()

    def cancel(self) -> None:
        self.cancelled = True
        self.done.set()


class VoiceToText:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.stt_model = cfg.stt_model or backends.STT[cfg.backend].default_model
        self.stt = None  # loaded in run()
        self.cleaner = None  # loaded in run() if cleanup is enabled
        self.recording = False
        self.processing = False
        self.cancel_requested = False
        self.escape_consumed = False
        self.delivered = False
        self.current_audio = None
        self.cancelled_audio = None  # one recoverable clip, held in memory only
        self.cancelled_job = None
        self.undo_requested = threading.Event()
        self.undo_timer = None  # running while a cancelled dictation is recoverable
        self.undo_key_down = False  # a Cmd+Z press taken for undo, until its key-up
        self.frames: list[np.ndarray] = []
        self.live: LiveTranscription | None = None  # streaming recording in flight
        self.stream = None
        self.frames_lock = threading.Lock()  # the audio callback's append vs. a stop
        self.mic_closer: threading.Thread | None = None  # the last stop, on its thread
        self.mic_closed_at = 0.0
        self.record_start = 0.0
        self.was_playing = False
        self._warned_mic = False
        self.jobs = queue.Queue()
        self.lifecycle_lock = threading.RLock()
        self.status_lock = threading.Lock()
        # Every status change and the live input level also go to the menu
        # app's pill as datagrams; nobody listening (a terminal run) is normal.
        self.live_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.live_socket.setblocking(False)
        self.level_peak = 0.0  # loudest block since the last level sent
        self.level_sent_at = 0.0
        self.shutdown_watcher = None
        self.shutdown_read_fd = None
        self.shutdown_write_fd = None
        self.instance_lock = None
        self.stopping = False
        self.finalizing_recording = False
        self.startup_complete = False
        self.latched = False  # hands-free recording after a double-tap
        self.trigger = "hold"  # hold | latched: how the current recording started
        self.input_device: str | None = None  # device the current recording uses
        self.warning = ""  # about the last dictation, shown until the next one
        self.shown = False  # the recording is past the hold threshold and visible
        self.chorded = False  # the hotkey was part of a shortcut, not a dictation
        self.hold_timer: threading.Timer | None = None
        self.press_at = 0.0
        self.last_tap_at = 0.0
        self.vocabulary: list[str] = []  # from dictionary.txt; refreshed per dictation
        self.replacements: list[tuple[str, str]] = []
        self.dictionary_mtime = -1.0
        cleanup_model = (
            cfg.cleanup_model or backends.CLEANUP[cfg.cleanup_engine].default_model
        )
        self.status_details = {
            "stt": backends.short_model(self.stt_model),
            "cleanup": backends.short_model(cleanup_model)
            if cfg.cleanup_enabled
            else "off",
            "mode": cfg.mode,
        }

    # --- live status for CLI and menu-bar clients --------------------------
    # Written on every transition (and the icon repainted) so actions get
    # immediate feedback, including loading, active work, errors, and shutdown.
    def _set_state(self, state: str, error: str = "", partial: str = "") -> None:
        with self.status_lock:
            if self.stopping and state != "stopping":
                return
            if self.cancel_requested and state not in ("cancelled", "stopping"):
                return  # a late recogniser result must not revive the pill
            clean_error = " ".join(error.split())
            status = {
                "pid": os.getpid(),
                "state": state,
                **self.status_details,
                "streaming": self.can_stream(),
                "live_transcript": self.cfg.live_transcript and self.can_stream(),
                "error": clean_error,
                "warning": self.warning,
            }
            if partial:  # what the streaming recogniser has heard so far
                status["words"] = len(partial.split())
                status["partial"] = _tail(partial)
            config.write_status(status)
            self._send_live(status)

    def _send_live(self, event: dict) -> None:
        try:
            self.live_socket.sendto(
                json.dumps(event).encode(), str(config.live_socket_path())
            )
        except OSError:  # no menu app, it is busy, or the status outgrew a
            pass  # datagram (2 KB on macOS): the one-second status poll still has it

    def _clear_status(self) -> None:
        with self.status_lock:
            config.clear_status()

    def _start_shutdown_watcher(self) -> None:
        self.shutdown_read_fd, self.shutdown_write_fd = os.pipe()

        def watch():
            os.read(self.shutdown_read_fd, 1)
            self._set_state("stopping")

        self.shutdown_watcher = threading.Thread(
            target=watch, name="v2t-shutdown-status", daemon=True
        )
        self.shutdown_watcher.start()

    def _close_stream(self) -> None:
        """Stop and close the microphone on its own thread and return at once.

        The callers run on the hotkey listener's event tap, which must never
        block: a stop takes ~0.1 s even when healthy, and can deadlock.
        """
        if self.stream is None:
            return
        stream, self.stream = self.stream, None

        def close() -> None:
            try:
                stream.stop()
            except Exception as error:
                logger.warning(f"Could not stop audio input cleanly: {error}")
            try:
                stream.close()
            except Exception as error:
                logger.warning(f"Could not close audio input cleanly: {error}")

        self.mic_closer = threading.Thread(target=close, name="v2t-mic-close", daemon=True)
        self.mic_closed_at = time.perf_counter()
        self.mic_closer.start()

    def _await_mic_closed(self, timeout: float) -> bool:
        """Wait up to `timeout` for the last stop; False while it is still running."""
        closer = self.mic_closer
        if closer is not None:
            closer.join(timeout)
            if closer.is_alive():
                return False
            if self.mic_closer is closer:
                self.mic_closer = None
        return True

    def mic_stuck(self) -> bool:
        """Whether the last stop has run past MIC_STUCK_S: the CoreAudio deadlock."""
        return (
            self.mic_closer is not None
            and self.mic_closer.is_alive()
            and time.perf_counter() - self.mic_closed_at >= MIC_STUCK_S
        )

    def _should_restart_for_microphone(self) -> bool:
        """A stop still stuck once the dictation is delivered and any Undo has lapsed."""
        with self.lifecycle_lock:
            return (
                not (self.stopping or self.recording or self.processing)
                and self.cancelled_audio is None
                and self.mic_stuck()
            )

    def _restart_for_microphone(self) -> None:
        """Replace this process with a fresh engine: the only way to free a
        CoreAudio deadlock. Same PID, so the menu app keeps tracking it; the
        instance lock, sockets and microphone are released by the exec."""
        logger.error(
            "The microphone stop never finished (a macOS audio deadlock, "
            "PortAudio#1174); restarting v2t to release it"
        )
        self._clear_status()
        sys.stdout.flush()
        sys.stderr.flush()
        os.execv(sys.executable, sys.orig_argv)

    def _restore_media(self) -> None:
        if self.cfg.pause_music and self.was_playing:
            subprocess.run(["nowplaying-cli", "play"], check=False)
        self.was_playing = False

    # --- recording ----------------------------------------------------------
    def audio_callback(self, indata, frame_count, time_info, status):
        if status:
            logger.warning(f"Audio input: {status}")
        with self.frames_lock:  # a stop waits for a block already being appended
            if not self.recording:
                return
            self.frames.append(indata.copy())
        if self.shown:  # a tap or a chord stays invisible
            self._send_level(indata)

    def _end_capture(self) -> None:
        """Stop taking frames. The stream itself stops later, on its own thread, so
        this is what guarantees the last block is in `frames` before they are read."""
        with self.frames_lock:
            self.recording = False

    def _send_level(self, block: np.ndarray) -> None:
        """Send the input level (RMS, full scale 1) to the pill's waveform.

        Callback blocks can be a few milliseconds long, so the loudest block
        in each LEVEL_INTERVAL_S goes out and the rest are folded into it.
        """
        self.level_peak = max(self.level_peak, float(np.sqrt(np.mean(block**2))))
        now = time.perf_counter()
        if now - self.level_sent_at >= LEVEL_INTERVAL_S:
            self._send_live({"level": round(self.level_peak, 5)})
            self.level_peak, self.level_sent_at = 0.0, now

    def _refresh_audio_devices(self) -> None:
        """Re-read the device list so the stream follows the current default mic.

        PortAudio snapshots devices once at init. Plugging or unplugging a
        headset, a Bluetooth profile switch during a call, or changing the
        input in System Settings leaves that snapshot pointing at a stale or
        missing device, and every open then fails with a PaMacCore
        ``Invalid Property Value`` until the process restarts. No stream is
        open here, so a re-init costs a few milliseconds.
        """
        try:
            sd._terminate()
        except Exception as error:
            # Already torn down by an earlier failed refresh; still re-init.
            logger.warning(f"Could not release audio devices: {error}")
        sd._initialize()

    def start_recording(self, show: bool = True, resume=None):
        """Open the microphone; with `show` the recording is also made visible.

        A held hotkey opens the microphone at once so no speech is lost, but
        stays invisible until `_show_recording` (nothing in the status file or
        log, no music paused, no streaming), so a tap or a chord leaves no trace.
        """
        with self.lifecycle_lock:
            if self.stopping or self.recording or self.processing:
                return
            # Re-initialising PortAudio while the last stop still runs would hang too.
            if not self._await_mic_closed(MIC_REOPEN_WAIT_S):
                logger.warning("Microphone still stopping; not recording")
                return
            self.frames = list(resume[0]) if resume else []
            self.shown = False
            self.record_start = time.perf_counter() - (resume[1] if resume else 0)
            try:
                self._refresh_audio_devices()
                self.input_device = _default_input_name()
                self.stream = sd.InputStream(
                    samplerate=self.cfg.sample_rate,
                    channels=1,
                    dtype="float32",
                    callback=self.audio_callback,
                )
                self.recording = True
                self.stream.start()
            except Exception as error:
                self.recording = False
                self._close_stream()
                logger.error(f"Could not open the microphone: {error}")
                self._set_state(
                    "error",
                    f"Microphone unavailable: {error}. "
                    "If you just granted Microphone permission, restart v2t.",
                )
                if not self._warned_mic:
                    self._warned_mic = True
                    subprocess.run(["open", MIC_PANE], check=False)
                return
            if self.stopping:
                self.recording = False
                self._close_stream()
                return
            self.cancel_requested = False
            self.current_audio = None
            self.delivered = False
            if show:
                self._show_recording()

    def _show_recording(self) -> None:
        with self.lifecycle_lock:
            if not self.recording or self.shown:
                return
            self.shown = True
            self.cancelled_audio = None
            self._withdraw_undo()
            self.level_peak = self.level_sent_at = 0.0  # none of the last recording's
            self.warning = ""  # the last dictation's; a tap or chord keeps it
            if self.cfg.pause_music:
                result = subprocess.run(
                    ["nowplaying-cli", "get", "playbackRate"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.was_playing = result.stdout.strip() == "1"
                if self.was_playing:
                    subprocess.run(["nowplaying-cli", "pause"], check=False)
            self._set_state("recording")
            logger.info("Recording...")
            if self.can_stream():
                self.live = LiveTranscription(self.frames)
                self.jobs.put(self.live)

    def can_stream(self) -> bool:
        """Whether recordings are transcribed while they happen.

        Needs a streaming mode, a backend with a streaming path (Parakeet;
        Whisper has none and keeps the whole-file path), and a capture rate the
        model accepts as-is, since streamed audio is not resampled.
        """
        stt = self.stt
        return bool(
            self.cfg.streaming_mode != "off"
            and getattr(stt, "streaming", False)
            and getattr(stt, "sample_rate", None) == self.cfg.sample_rate
        )

    def stop_recording(self):
        with self.lifecycle_lock:
            self._cancel_hold_timer()
            if not self.recording:
                return
            self._end_capture()
            self.finalizing_recording = True
            try:
                duration = time.perf_counter() - self.record_start
                self._close_stream()
                self.current_audio = (list(self.frames), duration)
                logger.info(f"Stopped ({duration:.1f}s)")
                if self.live is not None:
                    live, self.live = self.live, None
                    self.frames = []
                    self.processing = True
                    live.finish(duration)
                elif self.frames:
                    frames, self.frames = self.frames, []
                    self.processing = True
                    self.jobs.put((frames, duration))
                else:
                    self._restore_media()
                    self._set_state("idle")
            finally:
                self.finalizing_recording = False

    def process_audio(self, frames: list[np.ndarray], audio_s: float):
        next_state, error_message, levels = "idle", "", None
        try:
            if self.cancel_requested:
                return
            self.current_audio = (frames, audio_s)
            self._set_state("transcribing")
            audio = np.concatenate(frames, axis=0)
            self._keep_audio(audio)
            levels = audio_levels(audio, self.cfg.sample_rate)
            if levels["peak"] < 1e-4:  # dead silence == no mic access, not a quiet room
                error_message = self._no_audio(audio_s, levels)
                next_state = "error"
                return
            logger.info("Transcribing...")
            self.refresh_dictionary()
            t0 = time.perf_counter()
            raw_text = self._transcribe_whole(audio)
            stt_s = time.perf_counter() - t0
            logger.info(f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s)")
            if not raw_text:
                self._no_speech(audio_s, levels, stt_s)
                return

            self._deliver(raw_text, audio_s, stt_s, streamed=False, levels=levels)
        except Exception as error:
            next_state, error_message = "error", f"{type(error).__name__}: {error}"
            logger.exception(f"Transcription failed: {error}")
            if levels is not None:  # the audio was there: keep the failure on record
                self._record(audio_s, levels, outcome=f"error: {error_message}")
        finally:
            self._restore_media()
            if not self.stopping:
                self._set_state(next_state, error_message)
            self.processing = False
            self.current_audio = None

    def _no_audio(self, audio_s: float, levels: dict) -> str:
        """The dead-input error: log it, open the Microphone pane once, record it."""
        message = "No audio captured. Check Microphone permission, then restart the launching app."
        logger.error(message)
        if not self._warned_mic:
            self._warned_mic = True
            subprocess.run(["open", MIC_PANE], check=False)
        self._record(audio_s, levels, outcome="error: no audio captured")
        return message

    def _no_speech(self, audio_s: float, levels: dict, stt_s: float) -> None:
        logger.warning("No speech detected")
        warning = self._warn_about_level(levels, audio_s)
        self._record(
            audio_s,
            levels,
            level_warning=warning or None,
            outcome="error: no speech detected",
            stt_s=round(stt_s, 3),
        )

    def _warn_about_level(self, levels: dict, audio_s: float) -> str:
        """Publish the near-silent warning (log, notification, status) and return it.

        The warning names the device so a dead headset link is caught before
        the next dictation; whatever text there was is still pasted.
        """
        warning = level_warning(levels, audio_s, self.input_device) if levels else ""
        if warning:
            logger.warning(warning)
            self.warning = warning  # status.json, until the next recording
            _notify("v2t: check your microphone", warning)
        return warning

    def _record(self, audio_s: float, levels: dict, **fields) -> None:
        """One history row for the current recording, if history is on."""
        if not self.cfg.save_history:
            return
        try:
            config.append_history(
                {
                    "trigger": self.trigger,
                    "device": self.input_device,
                    "sample_rate": self.cfg.sample_rate,
                    "audio_s": round(audio_s, 2),
                    **levels,
                    "backend": self.cfg.backend,
                    "model": self.stt_model,
                    **fields,
                }
            )
        except OSError as error:
            logger.warning(f"Could not save transcription history: {error}")

    def _keep_audio(self, audio: np.ndarray) -> None:
        """Keep this recording's audio as run/last-recording.wav (owner-only, replaced
        every time) so a dictation that came out cut can be transcribed again with
        `v2t transcribe`. Never fatal: the transcription matters more than the copy."""
        path = config.last_audio_path()
        if not self.cfg.keep_last_audio:
            path.unlink(
                missing_ok=True
            )  # retention off: keep nothing from before either
            return
        temp_path = path.with_suffix(".wav.tmp")
        try:
            config.ensure_dirs()
            wavfile.write(
                temp_path, self.cfg.sample_rate, (audio * 32767).astype(np.int16)
            )
            temp_path.chmod(0o600)
            os.replace(temp_path, path)
        except Exception as error:
            logger.warning(f"Could not keep the recording's audio: {error}")
            temp_path.unlink(missing_ok=True)

    def _transcribe_whole(self, audio: np.ndarray) -> str:
        """Whole-file decoding of one recording, through a temporary WAV."""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wavfile.write(
                f.name, self.cfg.sample_rate, (audio * 32767).astype(np.int16)
            )
            temp_path = f.name
        try:
            return self.stt.transcribe(temp_path)
        finally:
            Path(temp_path).unlink(missing_ok=True)

    def process_live(self, live: LiveTranscription) -> None:
        """Transcribe a recording while it is still going, then deliver it.

        Runs on the processing thread. Until STREAM_TAKEOVER_S of audio, new
        frames go into the streaming recogniser every STREAM_CHUNK_S seconds and
        the partial text goes to the log and the menu bar; with the experimental
        live transcript on, every PREVIEW_STEP_S seconds in between the audio not
        pushed yet is decoded on its own and shown after it, display only. A
        recording released before then is decoded whole-file: about as quick
        there, and the reference text. From STREAM_TAKEOVER_S the stream closes
        and the recording is decoded whole in pieces of about PIECE_S as it
        arrives, the audio after the last piece previewed for the partial text,
        so once the hotkey thread calls `finish` only the last piece is left.
        """
        next_state, error_message, stream, pieces = "idle", "", None, None
        handed_back = False  # streaming broke while held: release decodes whole-file
        raw_text = None  # set once some decoder produced the text
        levels = None  # set once the recording's audio is in hand
        try:
            if live.cancelled:
                return
            self.refresh_dictionary()
            stream = self.stt.stream()
            feeder = backends.ChunkFeeder(stream.feed, self.cfg.sample_rate)
            takeover = int(self.cfg.sample_rate * backends.STREAM_TAKEOVER_S)
            preview_step = int(self.cfg.sample_rate * backends.PREVIEW_STEP_S)
            # From the takeover the partial text is a preview of the audio after the
            # last piece: every push's worth of audio, or every preview step when the
            # live transcript is on.
            tail_step = (
                preview_step
                if self.cfg.live_transcript
                else int(self.cfg.sample_rate * backends.STREAM_CHUNK_S)
            )
            tail_previews = True  # off for the recording once one fails
            previewed = 0  # unpushed (or undecoded) samples at the last preview
            previewing = self.cfg.live_transcript  # previews exist only to be shown
            while True:
                if self.stopping and not live.done.is_set():
                    live.cancel()  # shutdown mid-recording drops it, as before
                    return
                if pieces is not None:
                    for frame in live.frames[live.fed :]:
                        live.fed += 1
                        pieces.add(frame)
                    if pieces.step():
                        previewed = 0
                        if not live.done.is_set():
                            self._show_partial(pieces.text, pieces.decoded_samples)
                    elif (
                        tail_previews
                        and not live.done.is_set()
                        and pieces.pending_samples - previewed >= tail_step
                    ):
                        previewed = pieces.pending_samples
                        try:
                            tail = self.stt.decode(pieces.peek())
                        except Exception as error:  # display only: never the recording
                            logger.warning(f"Live preview off for this recording: {error}")
                            tail_previews = False
                        else:
                            partial = f"{pieces.text} {tail}".strip()
                            if self.cfg.live_transcript:
                                self._set_state("recording", partial=partial)
                            else:
                                self._show_partial(
                                    partial,
                                    pieces.decoded_samples + pieces.pending_samples,
                                )
                    if live.done.is_set() and live.fed == len(live.frames):
                        break
                    live.done.wait(0.1)
                    continue
                pushed = False
                for frame in live.frames[live.fed :]:
                    live.fed += 1
                    pushed = feeder.push(frame) or pushed
                if feeder.sent_samples + feeder.pending_samples >= takeover:
                    pieces, stream, previewed = self._pieces_from(stream, live), None, 0
                    logger.info("Past the takeover: decoding the rest in pieces")
                    continue
                if pushed:
                    previewed = 0
                    if not live.done.is_set():  # after release: no more partials
                        self._show_partial(stream.text, feeder.sent_samples)
                elif (
                    previewing
                    and not live.done.is_set()
                    and feeder.pending_samples - previewed >= preview_step
                ):
                    previewed = feeder.pending_samples
                    try:
                        tail = stream.preview(feeder.peek())
                    except Exception as error:  # display only: never the recording
                        logger.warning(f"Live preview off for this recording: {error}")
                        previewing = False
                    else:
                        self._set_state(
                            "recording", partial=f"{stream.text} {tail}".strip()
                        )
                if live.done.is_set() and live.fed == len(live.frames):
                    break
                live.done.wait(0.1)
            if live.cancelled:
                return
            if not live.frames:  # the microphone delivered nothing: back to idle
                return
            self._set_state("transcribing")
            audio = np.concatenate(live.frames, axis=0)
            self._keep_audio(audio)
            levels = audio_levels(audio, self.cfg.sample_rate)
            # `streamed` (history's column): decoded while held, in pieces.
            streamed = pieces is not None or live.duration >= backends.STREAM_TAKEOVER_S
            if streamed:
                if pieces is None:  # released just past the mark, before the switch
                    pieces, stream = self._pieces_from(stream, live), None
                held = pieces.pieces
                raw_text = pieces.finish()
            else:
                stream.close()  # first: it holds the model in streaming attention
                raw_text = self._transcribe_whole(audio)
            stream = None
            stt_s = time.perf_counter() - live.stopped_at
            if levels["peak"] < 1e-4:  # dead silence == no mic access, not a quiet room
                error_message = self._no_audio(live.duration, levels)
                next_state = "error"
                return
            logger.info(
                f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s after release, "
                + (
                    f"{pieces.pieces} pieces, {held} decoded while recording)"
                    if streamed
                    else f"whole-file: under {backends.STREAM_TAKEOVER_S:.0f}s)"
                )
            )
            if not raw_text:
                self._no_speech(live.duration, levels, stt_s)
                return
            self._deliver(
                raw_text, live.duration, stt_s, streamed=streamed, levels=levels
            )
        except Exception as error:
            with self.lifecycle_lock:
                if not live.done.is_set() and self.live is live:
                    # Still recording: detach so stop_recording queues the frames
                    # for whole-file decoding instead of finishing a dead job.
                    self.live = None
                    handed_back = True
            if handed_back:
                logger.warning(
                    f"Streaming failed ({error}); this recording is decoded after release"
                )
            elif raw_text is None and live.done.is_set() and not live.cancelled:
                # Streaming broke at release (final push, flush or close): the
                # audio is all still here, so decode it whole-file instead.
                logger.warning(
                    f"Streaming failed at release ({error}); decoding whole-file"
                )
                try:
                    if stream is not None:
                        stream.close()
                        stream = None
                    audio = np.concatenate(live.frames, axis=0)
                    self._keep_audio(audio)  # a push may have failed before the keep
                    levels = audio_levels(audio, self.cfg.sample_rate)
                    raw_text = self._transcribe_whole(audio)
                    stt_s = time.perf_counter() - live.stopped_at
                    logger.info(
                        f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s after release, whole-file fallback)"
                    )
                    if raw_text:
                        self._deliver(
                            raw_text,
                            live.duration,
                            stt_s,
                            streamed=False,
                            levels=levels,
                        )
                    else:
                        self._no_speech(live.duration, levels, stt_s)
                except Exception as fallback_error:
                    next_state = "error"
                    error_message = f"{type(fallback_error).__name__}: {fallback_error}"
                    logger.exception(f"Transcription failed: {fallback_error}")
            else:
                next_state, error_message = "error", f"{type(error).__name__}: {error}"
                logger.exception(f"Transcription failed: {error}")
            if next_state == "error" and levels is not None:
                self._record(live.duration, levels, outcome=f"error: {error_message}")
        finally:
            if stream is not None:
                try:
                    stream.close()
                except Exception as error:
                    logger.warning(f"Could not close the streaming recogniser: {error}")
            # Only a job that reached release here owns the idle/error transition:
            # a cancelled one was cleaned up by cancel_recording (a new recording
            # may already be running), a handed-back one is still recording.
            if live.done.is_set() and not live.cancelled and not handed_back:
                self._restore_media()
                if not self.stopping:
                    self._set_state(next_state, error_message)
                self.processing = False
                self.current_audio = None
            if self.cancelled_job is live:
                self.cancelled_job = None
                self.processing = False

    def _pieces_from(self, stream, live: LiveTranscription) -> backends.PieceDecoder:
        """Close the stream and hand everything fed so far to a PieceDecoder."""
        stream.close()  # first: it holds the model in streaming attention
        pieces = backends.PieceDecoder(self.stt.decode, self.cfg.sample_rate)
        if live.fed:
            pieces.add(np.concatenate(live.frames[: live.fed], axis=0))
        return pieces

    def _show_partial(self, text: str, samples: int) -> None:
        # The log never carries dictated text (0.3.0 guarantee); the tail goes
        # only to the owner-only status file, for the menu-bar tooltip.
        words = len(text.split())
        logger.info(
            f"Heard so far: {words} words in {samples / self.cfg.sample_rate:.0f}s"
        )
        self._set_state("recording", partial=text)

    def _deliver(
        self,
        raw_text: str,
        audio_s: float,
        stt_s: float,
        streamed: bool,
        levels: dict | None = None,
    ) -> None:
        """Clean up, paste and record one transcription. Raises on failure."""
        if self.cancel_requested:
            return
        levels = levels or {}
        cleaned_text, cleanup_s, stats = raw_text, 0.0, {}
        if self.cleaner is not None:
            self._set_state("cleaning")
            logger.info("Cleaning up...")
            try:
                cleaned_text, _ttft, cleanup_s = self.cleaner.cleanup(
                    raw_text, self.cfg.mode
                )
                if not cleaned_text:
                    raise RuntimeError("empty response")
                logger.info(
                    f"Cleaned {len(cleaned_text)} characters ({cleanup_s:.2f}s)"
                )
                stats = getattr(self.cleaner, "last_stats", None)
                if not isinstance(stats, dict):  # engines without chunk stats
                    stats = {}
                if stats.get("guarded") or stats.get("limited"):
                    logger.warning(
                        f"Cleanup kept raw text for {stats.get('guarded', 0)} chunk(s) "
                        f"that changed length too much and {stats.get('limited', 0)} "
                        f"that hit the token limit (of {stats.get('chunks', 0)})"
                    )
            except Exception as e:
                logger.error(f"LLM cleanup failed: {e}")
                logger.warning("Falling back to raw transcription")
                cleaned_text = raw_text
        fired = config.replacements_fired(cleaned_text, self.replacements)
        cleaned_text = config.apply_replacements(cleaned_text, self.replacements)

        t0 = time.perf_counter()
        with self.lifecycle_lock:
            if self.cancel_requested:
                return
            # Serialize the final paste decision with Esc. Once pasted, Esc
            # belongs to the target app; never claim that a paste was cancelled.
            self.delivered = True
            # The pill fades out as the paste lands, before the caret moves.
            self._set_state("delivering")
            self.paste_to_cursor(cleaned_text)
        paste_s = time.perf_counter() - t0
        logger.success(f"Pasted ({paste_s:.2f}s including clipboard restore)")

        warning = self._warn_about_level(levels, audio_s)
        self._record(
            audio_s,
            levels,
            level_warning=warning or None,
            streamed=streamed,
            stt_s=round(stt_s, 3),
            cleanup_engine=self.cfg.cleanup_engine if self.cleaner else None,
            cleanup_model=self.cleaner.model_id if self.cleaner else None,
            mode=self.cfg.mode,
            cleanup_chunks=stats.get("chunks"),
            cleanup_guarded=stats.get("guarded"),
            cleanup_limited=stats.get("limited"),
            cleanup_s=round(cleanup_s, 3),
            replacements=len(fired),
            paste_s=round(paste_s, 3),
            raw=raw_text,
            clean=cleaned_text,
            outcome="pasted",
        )

    def process_next(self, timeout: float | None = None) -> bool:
        """Process one queued recording on the model-owning thread."""
        if self.undo_requested.is_set() and not self.processing:
            self.undo_requested.clear()
            self.undo_cancelled()
        try:
            job = self.jobs.get(timeout=timeout)
        except queue.Empty:
            return True
        if job is None:
            return False
        if isinstance(job, LiveTranscription):
            self.process_live(job)
        else:
            self.process_audio(*job)
        return True

    def _keep_running(self) -> bool:
        with self.lifecycle_lock:
            return not self.stopping or self.finalizing_recording or self.processing

    def paste_to_cursor(self, text: str) -> None:
        """Paste at the cursor, preserving every native pasteboard representation."""
        from AppKit import NSPasteboard, NSPasteboardItem, NSPasteboardTypeString
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventPost,
            CGEventSetFlags,
            kCGEventFlagMaskCommand,
            kCGHIDEventTap,
        )

        pasteboard = NSPasteboard.generalPasteboard()
        saved = None
        for _ in range(2):
            snapshot_change = pasteboard.changeCount()
            snapshot = []
            for item in pasteboard.pasteboardItems() or []:
                values = []
                for kind in item.types():
                    data = item.dataForType_(kind)
                    if data is not None:
                        values.append((kind, data))
                snapshot.append(values)
            if pasteboard.changeCount() == snapshot_change:
                saved = snapshot
                break
        if saved is None:
            raise RuntimeError("clipboard changed while preparing paste")
        dictated_change = None
        try:
            pasteboard.clearContents()
            if not pasteboard.setString_forType_(text, NSPasteboardTypeString):
                raise RuntimeError("could not write to the clipboard")
            dictated_change = pasteboard.changeCount()
            down = CGEventCreateKeyboardEvent(None, 9, True)
            up = CGEventCreateKeyboardEvent(None, 9, False)
            CGEventSetFlags(down, kCGEventFlagMaskCommand)
            CGEventSetFlags(up, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, down)
            CGEventPost(kCGHIDEventTap, up)
            # Give slower targets time to consume the synthetic paste before restoration.
            time.sleep(0.3)
        finally:
            should_restore = (
                dictated_change is None or pasteboard.changeCount() == dictated_change
            )
            if should_restore:
                pasteboard.clearContents()
                restored = []
                for values in saved:
                    item = NSPasteboardItem.alloc().init()
                    for kind, data in values:
                        item.setData_forType_(data, kind)
                    restored.append(item)
                if restored:
                    pasteboard.writeObjects_(restored)

    # --- run loop -----------------------------------------------------------
    # --- hotkey: hold to talk, or double-tap for hands-free -----------------
    # The microphone opens on press, but the recording only shows once the key
    # has been down for HOLD_S. A shorter press is a tap and is dropped without
    # a trace (nothing said in 0.5 s is a dictation); a press joined by another
    # key before then (Fn+arrow, Cmd+Enter) is a chord and is dropped at once,
    # and does not count as a tap. Two taps within DOUBLE_TAP_S latch the
    # recorder on; the next tap stops it and transcribes.
    HOLD_S = 0.5
    DOUBLE_TAP_S = 0.5

    def on_press(self, key):
        if getattr(key, "name", None) == "esc":
            self.escape_consumed = self.escape_consumed or self.cancel_dictation()
            return
        if key != self.hotkey:
            if self.recording and not self.shown and not self.latched:
                self.chorded = True
                self.cancel_recording()
            return
        if self.latched:
            return
        self.press_at = time.perf_counter()
        self.chorded = False
        self.trigger = "hold"
        self.start_recording(show=False)
        if self.recording:
            self.hold_timer = threading.Timer(self.HOLD_S, self._show_recording)
            self.hold_timer.daemon = True
            self.hold_timer.start()

    def on_release(self, key):
        if key != self.hotkey:
            return
        now = time.perf_counter()
        if self.latched:
            self.latched = False
            self.stop_recording()
            return
        if self.chorded:
            self.chorded = False
            return
        if now - self.press_at >= self.HOLD_S:
            self.stop_recording()
            return
        self.cancel_recording()
        if now - self.last_tap_at < self.DOUBLE_TAP_S:
            self.last_tap_at = 0.0
            self.trigger = "latched"
            self.start_recording()
            self.latched = self.recording
            if self.latched:
                logger.info("Recording hands-free — tap the hotkey again to stop")
        else:
            self.last_tap_at = now

    def consume_escape(self, released: bool) -> bool:
        """Keep repeats and release suppressed for the same physical press."""
        consumed = self.escape_consumed
        if released:
            self.escape_consumed = False
        return consumed

    def _cancel_hold_timer(self) -> None:
        if self.hold_timer is not None:
            self.hold_timer.cancel()
            self.hold_timer = None

    def cancel_recording(self):
        """Drop an in-progress recording without transcribing it."""
        with self.lifecycle_lock:
            self._cancel_hold_timer()
            if not self.recording:
                return
            self._end_capture()
            self.frames = []
            if self.live is not None:
                live, self.live = self.live, None
                live.cancel()
            self._close_stream()
            self._restore_media()
            self._set_state("cancelled" if self.cancelled_audio else "idle")
            if self.cancelled_audio:
                self._offer_undo()

    def cancel_dictation(self) -> bool:
        """Esc stops capture immediately and makes any in-flight result inert."""
        with self.lifecycle_lock:
            if self.delivered or not (self.recording or self.processing):
                return False
            if self.cancel_requested:
                return True
            self._cancel_hold_timer()
            self.cancel_requested = True
            self.latched = False
            self.chorded = True  # the outstanding Fn release cannot latch/start
            self.last_tap_at = 0.0
            if self.recording:
                duration = time.perf_counter() - self.record_start
                self._end_capture()
                self._close_stream()
                self.cancelled_audio = (list(self.frames), duration)
                self.frames = []
                if self.live is not None:
                    live, self.live = self.live, None
                    self.cancelled_job = live
                    self.processing = True  # drain it before using the same model again
                    live.cancel()
            else:
                self.cancelled_audio = self.current_audio
            self._restore_media()
            self._set_state("cancelled")
            self._offer_undo()
            return True

    def _offer_undo(self, seconds: float = UNDO_WINDOW_S) -> None:
        """(Re)start the window in which the cancelled dictation can come back."""
        self._withdraw_undo()
        self.undo_timer = threading.Timer(seconds, self._expire_undo)
        self.undo_timer.daemon = True
        self.undo_timer.start()

    def _withdraw_undo(self) -> None:
        if self.undo_timer is not None:
            self.undo_timer.cancel()
            self.undo_timer = None

    def _expire_undo(self) -> None:
        """The window closed: drop the held audio and put the pill away."""
        with self.lifecycle_lock:
            self.undo_timer = None
            if self.recording or self.cancelled_audio is None or self.stopping:
                return
            if self.processing:  # the cancelled job is still draining: look again
                self._offer_undo(0.5)
                return
            self.cancelled_audio = None
            self.cancel_requested = False
            self._set_state("idle")

    def take_undo_shortcut(self, released: bool) -> bool:
        """Cmd+Z while a cancelled dictation is recoverable: undo it, and keep
        the key (repeats and key-up included) from reaching the app."""
        if released:
            taken, self.undo_key_down = self.undo_key_down, False
            return taken
        if self.undo_key_down:
            return True
        with self.lifecycle_lock:
            offered = self.undo_timer is not None and not self.recording
        if offered:
            self.undo_key_down = True
            self.request_undo()
        return offered

    def request_undo(self, _signum=None, _frame=None) -> None:
        # A signal only requests work; opening the microphone belongs to the
        # model-owning loop, after any cancelled inference has returned.
        self.undo_requested.set()

    def undo_cancelled(self) -> None:
        with self.lifecycle_lock:
            if self.stopping or self.processing or not self.cancelled_audio:
                return
            self.trigger = "latched"
            self.start_recording(resume=self.cancelled_audio)
            self.latched = self.recording

    def refresh_dictionary(self) -> None:
        """Re-read dictionary.txt when it changed, so edits apply without a restart."""
        mtime = config.dictionary_mtime()
        if mtime == self.dictionary_mtime:
            return
        self.dictionary_mtime = mtime
        self.vocabulary, self.replacements = config.read_dictionary()
        if self.cleaner is not None:
            self.cleaner.vocabulary = tuple(self.vocabulary)
        logger.info(
            f"Dictionary: {len(self.vocabulary)} terms, {len(self.replacements)} replacements"
        )

    def warmup(self):
        self.refresh_dictionary()
        logger.info("Loading transcription model...")
        self._set_state("loading-stt")
        t0 = time.perf_counter()
        self.stt = backends.make_stt(self.cfg.backend, self.cfg.stt_model)
        temp_path = None
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wavfile.write(
                f.name,
                self.cfg.sample_rate,
                np.zeros(self.cfg.sample_rate, dtype=np.int16),
            )
            temp_path = f.name
        try:
            self.stt.transcribe(temp_path)
        finally:
            Path(temp_path).unlink(missing_ok=True)
        logger.success(f"{self.cfg.backend} ready ({time.perf_counter() - t0:.1f}s)")
        if self.can_stream():
            logger.info(
                f"Streaming ({self.cfg.streaming_mode}) — transcribing while the hotkey is held"
            )
        elif self.cfg.streaming_mode != "off":
            logger.info(
                f"Streaming off: {self.cfg.backend} has no streaming path"
                if not getattr(self.stt, "streaming", False)
                else f"Streaming off: audio.sample_rate must be {self.stt.sample_rate}"
            )

        if self.cfg.cleanup_enabled:
            self._set_state("loading-cleanup")
            t0 = time.perf_counter()
            self.cleaner = backends.make_cleanup(
                self.cfg.cleanup_engine, self.cfg.cleanup_model, self.cfg.ollama_url
            )
            self.cleaner.vocabulary = tuple(self.vocabulary)
            try:
                self.cleaner.cleanup("hi", self.cfg.mode)
                logger.success(
                    f"cleanup ({self.cfg.cleanup_engine}) ready ({time.perf_counter() - t0:.1f}s)"
                )
            except Exception as e:
                logger.warning(
                    f"cleanup warmup failed ({e}); will retry per transcription"
                )

    def run(self):
        try:
            self.instance_lock = config.acquire_instance_lock()
        except BlockingIOError:
            logger.error("v2t already running. Stop it first: v2t stop")
            sys.exit(1)
        config.clear_last_error()
        config.ensure_dirs()
        self.hotkey = _resolve_hotkey(self.cfg.hotkey)
        self._start_shutdown_watcher()
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGUSR1, self.request_undo)
        try:
            self.warmup()
            self.startup_complete = True
            self._set_state("idle")
            logger.info(f"Voice-to-Text — {self.cfg.backend} · {self.cfg.mode}")
            if self.cfg.pause_music:
                logger.info("Pause Music — on")
            logger.info(
                f"Hold {self.cfg.hotkey} to record, release to transcribe and paste; "
                f"double-tap it for hands-free, tap again to stop. Ctrl+C to quit."
            )
            if self.cfg.hotkey == "fn" and (warning := globe_key_warning()):
                logger.warning(warning)
            with _listener(
                self.on_press, self.on_release, self.consume_escape, self.take_undo_shortcut
            ) as listener:
                while listener.is_alive() and self._keep_running():
                    if not self.process_next(timeout=0.25):
                        break
                    if self._should_restart_for_microphone():
                        self._restart_for_microphone()
                if not self.stopping and not listener.is_alive():
                    raise RuntimeError("global hotkey listener stopped unexpectedly")
        except KeyboardInterrupt:
            logger.info("Shutting down...")
        except SystemExit as error:
            if error.code not in (None, 0):
                config.write_last_error(f"v2t stopped with an error: {error}")
            raise
        except Exception as error:
            config.write_last_error(f"v2t stopped with an error: {error}")
            raise
        finally:
            self.shutdown()

    def _handle_signal(self, signum=None, _frame=None):
        if self.stopping:
            if signum == signal.SIGINT:
                raise SystemExit(0)
            return
        self.stopping = True
        if self.shutdown_write_fd is not None:
            try:
                os.write(self.shutdown_write_fd, b"\0")
            except OSError:
                pass
        if (
            not self.startup_complete
            and not self.finalizing_recording
            and not self.processing
        ):
            raise SystemExit(0)

    def shutdown(self) -> None:
        self.stopping = True
        if self.shutdown_write_fd is not None:
            try:
                os.write(self.shutdown_write_fd, b"\0")
            except OSError:
                pass
        if self.shutdown_watcher is not None:
            self.shutdown_watcher.join()
        self._set_state("stopping")
        self.jobs.put(None)
        with self.lifecycle_lock:
            self._cancel_hold_timer()
            self._end_capture()
            if self.live is not None:
                live, self.live = self.live, None
                live.cancel()
        self._close_stream()
        mic_free = self._await_mic_closed(MIC_STUCK_S)
        self._restore_media()
        self._clear_status()
        for fd in (self.shutdown_read_fd, self.shutdown_write_fd):
            if fd is not None:
                os.close(fd)
        self.shutdown_read_fd = self.shutdown_write_fd = None
        if self.instance_lock is not None:
            self.instance_lock.close()
            self.instance_lock = None
        if not mic_free:
            # sounddevice's exit hook terminates PortAudio, which would wait on the
            # deadlocked CoreAudio lock forever and keep the microphone held.
            logger.warning("Microphone stop still stuck; exiting without PortAudio teardown")
            sys.stdout.flush()
            sys.stderr.flush()
            os._exit(0)


if __name__ == "__main__":
    # Logic here needs audio + MLX; pure helpers/tests live in backends.py & config.py.
    print("app.py: import OK")
