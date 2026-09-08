"""The push-to-talk engine: record on hotkey, transcribe, clean up, paste.

macOS-only at runtime (native pasteboard, System Events paste, global hotkey).
"""

from __future__ import annotations

import os
import queue
import signal
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


def _resolve_hotkey(name: str):
    from pynput import keyboard

    keys = {
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
        self.frames: list[np.ndarray] = []
        self.live: LiveTranscription | None = None  # streaming recording in flight
        self.stream = None
        self.record_start = 0.0
        self.was_playing = False
        self._warned_mic = False
        self.jobs = queue.Queue()
        self.lifecycle_lock = threading.RLock()
        self.status_lock = threading.Lock()
        self.shutdown_watcher = None
        self.shutdown_read_fd = None
        self.shutdown_write_fd = None
        self.instance_lock = None
        self.stopping = False
        self.finalizing_recording = False
        self.startup_complete = False
        self.latched = False  # hands-free recording after a double-tap
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
            clean_error = " ".join(error.split())
            status = {
                "pid": os.getpid(),
                "state": state,
                **self.status_details,
                "error": clean_error,
            }
            if partial:  # what the streaming recogniser has heard so far
                status["words"] = len(partial.split())
                status["partial"] = _tail(partial)
            config.write_status(status)

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
        if self.stream is not None:
            stream, self.stream = self.stream, None
            try:
                stream.stop()
            except Exception as error:
                logger.warning(f"Could not stop audio input cleanly: {error}")
            try:
                stream.close()
            except Exception as error:
                logger.warning(f"Could not close audio input cleanly: {error}")

    def _restore_media(self) -> None:
        if self.cfg.pause_music and self.was_playing:
            subprocess.run(["nowplaying-cli", "play"], check=False)
        self.was_playing = False

    # --- recording ----------------------------------------------------------
    def audio_callback(self, indata, frame_count, time_info, status):
        if status:
            logger.warning(f"Audio input: {status}")
        if self.recording:
            self.frames.append(indata.copy())

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

    def start_recording(self):
        with self.lifecycle_lock:
            if self.stopping or self.recording or self.processing:
                return
            self.frames = []
            self.record_start = time.perf_counter()
            try:
                self._refresh_audio_devices()
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
            if not self.recording:
                return
            self.recording = False
            self.finalizing_recording = True
            try:
                duration = time.perf_counter() - self.record_start
                self._close_stream()
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
        next_state, error_message = "idle", ""
        try:
            self._set_state("transcribing")
            audio = np.concatenate(frames, axis=0)
            if (
                float(np.abs(audio).max()) < 1e-4
            ):  # dead silence == no mic access, not a quiet room
                error_message = "No audio captured. Check Microphone permission, then restart the launching app."
                logger.error(error_message)
                if not self._warned_mic:
                    self._warned_mic = True
                    subprocess.run(["open", MIC_PANE], check=False)
                next_state = "error"
                return
            logger.info("Transcribing...")
            self.refresh_dictionary()
            t0 = time.perf_counter()
            raw_text = self._transcribe_whole(audio)
            stt_s = time.perf_counter() - t0
            logger.info(f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s)")
            if not raw_text:
                logger.warning("No speech detected")
                return

            self._deliver(raw_text, audio_s, stt_s, streamed=False)
        except Exception as error:
            next_state, error_message = "error", f"{type(error).__name__}: {error}"
            logger.exception(f"Transcription failed: {error}")
        finally:
            self._restore_media()
            if not self.stopping:
                self._set_state(next_state, error_message)
            self.processing = False

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

        Runs on the processing thread. New frames go into the streaming
        recogniser every STREAM_CHUNK_S seconds of audio and the partial text
        goes to the log and the menu bar. Once the hotkey thread calls `finish`,
        a recording longer than STREAM_TAKEOVER_S takes the streamed text (only
        the remainder is left to decode); a shorter one is decoded whole-file,
        which costs about the same there and gives the reference text.
        """
        next_state, error_message, stream = "idle", "", None
        handed_back = False  # streaming broke while held: release decodes whole-file
        raw_text = None  # set once some decoder produced the text
        try:
            if live.cancelled:
                return
            self.refresh_dictionary()
            stream = self.stt.stream()
            feeder = backends.ChunkFeeder(stream.feed, self.cfg.sample_rate)
            peak = 0.0
            while True:
                if self.stopping and not live.done.is_set():
                    live.cancel()  # shutdown mid-recording drops it, as before
                    return
                pushed = False
                for frame in live.frames[live.fed :]:
                    live.fed += 1
                    peak = max(peak, float(np.abs(frame).max()))
                    pushed = feeder.push(frame) or pushed
                if pushed and not live.done.is_set():  # after release: no more partials
                    self._show_partial(stream.text, feeder.sent_samples)
                if live.done.is_set() and live.fed == len(live.frames):
                    break
                live.done.wait(0.1)
            if live.cancelled:
                return
            self._set_state("transcribing")
            streamed = live.duration >= backends.STREAM_TAKEOVER_S
            if streamed:
                feeder.flush()
                raw_text = stream.close()
            else:
                stream.close()  # first: it holds the model in streaming attention
                raw_text = self._transcribe_whole(np.concatenate(live.frames, axis=0))
            stream = None
            stt_s = time.perf_counter() - live.stopped_at
            if not live.frames:
                return
            if peak < 1e-4:  # dead silence == no mic access, not a quiet room
                error_message = "No audio captured. Check Microphone permission, then restart the launching app."
                logger.error(error_message)
                if not self._warned_mic:
                    self._warned_mic = True
                    subprocess.run(["open", MIC_PANE], check=False)
                next_state = "error"
                return
            logger.info(
                f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s after release, "
                + (
                    f"{feeder.chunks} chunks while recording)"
                    if streamed
                    else f"whole-file: under {backends.STREAM_TAKEOVER_S:.0f}s)"
                )
            )
            if not raw_text:
                logger.warning("No speech detected")
                return
            self._deliver(raw_text, live.duration, stt_s, streamed=streamed)
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
                    raw_text = self._transcribe_whole(
                        np.concatenate(live.frames, axis=0)
                    )
                    stt_s = time.perf_counter() - live.stopped_at
                    logger.info(
                        f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s after release, whole-file fallback)"
                    )
                    if raw_text:
                        self._deliver(raw_text, live.duration, stt_s, streamed=False)
                    else:
                        logger.warning("No speech detected")
                except Exception as fallback_error:
                    next_state = "error"
                    error_message = f"{type(fallback_error).__name__}: {fallback_error}"
                    logger.exception(f"Transcription failed: {fallback_error}")
            else:
                next_state, error_message = "error", f"{type(error).__name__}: {error}"
                logger.exception(f"Transcription failed: {error}")
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

    def _show_partial(self, text: str, samples: int) -> None:
        words = len(text.split())
        logger.info(
            f"Heard so far: {words} words in {samples / self.cfg.sample_rate:.0f}s"
            + (f" …{_tail(text)}" if text else "")
        )
        self._set_state("recording", partial=text)

    def _deliver(
        self, raw_text: str, audio_s: float, stt_s: float, streamed: bool
    ) -> None:
        """Clean up, paste and record one transcription. Raises on failure."""
        cleaned_text, cleanup_s = raw_text, 0.0
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
                stats = getattr(self.cleaner, "last_stats", {})
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
        cleaned_text = config.apply_replacements(cleaned_text, self.replacements)

        t0 = time.perf_counter()
        self.paste_to_cursor(cleaned_text)
        paste_s = time.perf_counter() - t0
        logger.success(f"Pasted ({paste_s:.2f}s including clipboard restore)")

        if self.cfg.save_history:
            try:
                config.append_history(
                    {
                        "audio_s": round(audio_s, 2),
                        "backend": self.cfg.backend,
                        "model": self.stt_model,
                        "cleanup_engine": self.cfg.cleanup_engine
                        if self.cleaner
                        else None,
                        "cleanup_model": self.cleaner.model_id
                        if self.cleaner
                        else None,
                        "mode": self.cfg.mode,
                        "stt_s": round(stt_s, 3),
                        "cleanup_s": round(cleanup_s, 3),
                        "paste_s": round(paste_s, 3),
                        "raw": raw_text,
                        "clean": cleaned_text,
                        "streamed": streamed,
                    }
                )
            except OSError as error:
                logger.warning(f"Could not save transcription history: {error}")

    def process_next(self, timeout: float | None = None) -> bool:
        """Process one queued recording on the model-owning thread."""
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
    # A press shorter than TAP_S is a tap and never transcribes (nothing said in
    # 0.3s is a dictation). Two taps within DOUBLE_TAP_S latch the recorder on;
    # the next tap stops it and transcribes. A long hold still works as before.
    TAP_S = 0.3
    DOUBLE_TAP_S = 0.5

    def on_press(self, key):
        if key != self.hotkey or self.latched:
            return
        self.press_at = time.perf_counter()
        self.start_recording()

    def on_release(self, key):
        if key != self.hotkey:
            return
        now = time.perf_counter()
        if self.latched:
            self.latched = False
            self.stop_recording()
            return
        if now - self.press_at >= self.TAP_S:
            self.stop_recording()
            return
        self.cancel_recording()
        if now - self.last_tap_at < self.DOUBLE_TAP_S:
            self.last_tap_at = 0.0
            self.start_recording()
            self.latched = self.recording
            if self.latched:
                logger.info("Recording hands-free — tap the hotkey again to stop")
        else:
            self.last_tap_at = now

    def cancel_recording(self):
        """Drop an in-progress recording without transcribing it."""
        with self.lifecycle_lock:
            if not self.recording:
                return
            self.recording = False
            self.frames = []
            if self.live is not None:
                live, self.live = self.live, None
                live.cancel()
            self._close_stream()
            self._restore_media()
            self._set_state("idle")

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
        from pynput import keyboard

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
            with keyboard.Listener(
                on_press=self.on_press, on_release=self.on_release
            ) as listener:
                while listener.is_alive() and self._keep_running():
                    if not self.process_next(timeout=0.25):
                        break
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
            self.recording = False
            if self.live is not None:
                live, self.live = self.live, None
                live.cancel()
        self._close_stream()
        self._restore_media()
        self._clear_status()
        for fd in (self.shutdown_read_fd, self.shutdown_write_fd):
            if fd is not None:
                os.close(fd)
        self.shutdown_read_fd = self.shutdown_write_fd = None
        if self.instance_lock is not None:
            self.instance_lock.close()
            self.instance_lock = None


if __name__ == "__main__":
    # Logic here needs audio + MLX; pure helpers/tests live in backends.py & config.py.
    print("app.py: import OK")
