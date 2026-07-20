"""The push-to-talk engine: record on hotkey, transcribe, clean up, paste.

macOS-only at runtime (native pasteboard, System Events paste, global hotkey).
"""

from __future__ import annotations

import os
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

from . import backends, config
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


def check_and_request_permissions() -> None:
    """Fail early with the exact macOS permission panes that still need a grant."""
    from ApplicationServices import AXIsProcessTrusted, CGPreflightListenEventAccess

    logger.info("Checking permissions...")
    checks = [
        ("Accessibility", bool(AXIsProcessTrusted()), "Privacy_Accessibility"),
        (
            "Input Monitoring",
            bool(CGPreflightListenEventAccess()),
            "Privacy_ListenEvent",
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


class VoiceToText:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.stt_model = cfg.stt_model or backends.STT[cfg.backend].default_model
        self.stt = None  # loaded in run()
        self.cleaner = None  # loaded in run() if cleanup is enabled
        self.recording = False
        self.processing = False
        self.frames: list[np.ndarray] = []
        self.stream = None
        self.record_start = 0.0
        self.was_playing = False
        self._warned_mic = False
        self.worker = None
        self.instance_lock = None
        self.stopping = False
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

    # --- live status for the SwiftBar plugin -------------------------------
    # state: starting | idle | recording | transcribing | cleaning. Written on
    # every transition (and the icon repainted) so actions get instant feedback.
    def _set_state(self, state: str, error: str = "") -> None:
        clean_error = " ".join(error.split())
        config.write_status(
            {
                "pid": os.getpid(),
                "state": state,
                **self.status_details,
                "error": clean_error,
            }
        )

    def _clear_status(self) -> None:
        config.clear_status()

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

    def start_recording(self):
        if self.recording or self.processing:
            return
        self.frames = []
        self.record_start = time.perf_counter()
        try:
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
            self._set_state("error", f"Microphone unavailable: {error}")
            if not self._warned_mic:
                self._warned_mic = True
                subprocess.run(["open", MIC_PANE], check=False)
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

    def stop_recording(self):
        if not self.recording:
            return
        self.recording = False
        duration = time.perf_counter() - self.record_start
        self._close_stream()
        logger.info(f"Stopped ({duration:.1f}s)")
        if self.frames:
            frames, self.frames = self.frames, []
            self.processing = True
            self.worker = threading.Thread(
                target=self.process_audio, args=(frames, duration)
            )
            self.worker.start()
        else:
            self._restore_media()
            self._set_state("idle")

    def process_audio(self, frames: list[np.ndarray], audio_s: float):
        next_state, error_message, temp_path = "idle", "", None
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
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                wavfile.write(
                    f.name, self.cfg.sample_rate, (audio * 32767).astype(np.int16)
                )
                temp_path = f.name

            logger.info("Transcribing...")
            t0 = time.perf_counter()
            raw_text = self.stt.transcribe(temp_path)
            stt_s = time.perf_counter() - t0
            logger.info(f"Transcribed {len(raw_text)} characters ({stt_s:.2f}s)")
            if not raw_text:
                logger.warning("No speech detected")
                return

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
                except Exception as e:
                    logger.error(f"LLM cleanup failed: {e}")
                    logger.warning("Falling back to raw transcription")
                    cleaned_text = raw_text

            self.paste_to_cursor(cleaned_text)
            logger.success("Pasted!")

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
                            "raw": raw_text,
                            "clean": cleaned_text,
                        }
                    )
                except OSError as error:
                    logger.warning(f"Could not save transcription history: {error}")
        except Exception as error:
            next_state, error_message = "error", f"{type(error).__name__}: {error}"
            logger.exception(f"Transcription failed: {error}")
        finally:
            if temp_path:
                Path(temp_path).unlink(missing_ok=True)
            self._restore_media()
            if not self.stopping:
                self._set_state(next_state, error_message)
            self.processing = False

    def paste_to_cursor(self, text: str) -> None:
        """Paste at the cursor, preserving every native pasteboard representation."""
        from AppKit import NSPasteboard, NSPasteboardItem, NSPasteboardTypeString

        pasteboard = NSPasteboard.generalPasteboard()
        saved = []
        for item in pasteboard.pasteboardItems() or []:
            values = []
            for kind in item.types():
                if data := item.dataForType_(kind):
                    values.append((kind, data))
            saved.append(values)
        try:
            pasteboard.clearContents()
            if not pasteboard.setString_forType_(text, NSPasteboardTypeString):
                raise RuntimeError("could not write to the clipboard")
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to keystroke "v" using command down',
                ],
                check=True,
            )
            # Give slower targets time to consume the synthetic paste before restoration.
            time.sleep(0.3)
        finally:
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
    def on_press(self, key):
        if key == self.hotkey:
            self.start_recording()

    def on_release(self, key):
        if key == self.hotkey:
            self.stop_recording()

    def warmup(self):
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

        if self.cfg.cleanup_enabled:
            self._set_state("loading-cleanup")
            t0 = time.perf_counter()
            self.cleaner = backends.make_cleanup(
                self.cfg.cleanup_engine, self.cfg.cleanup_model, self.cfg.ollama_url
            )
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
        signal.signal(signal.SIGTERM, self._handle_signal)
        try:
            self.warmup()
            self._set_state("idle")
            logger.info(f"Voice-to-Text — {self.cfg.backend} · {self.cfg.mode}")
            if self.cfg.pause_music:
                logger.info("Pause Music — on")
            logger.info(
                f"Hold {self.cfg.hotkey} to record, release to transcribe and paste. Ctrl+C to quit."
            )
            with keyboard.Listener(
                on_press=self.on_press, on_release=self.on_release
            ) as listener:
                listener.join()
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

    def _handle_signal(self, *_):
        self.shutdown()
        raise SystemExit(0)

    def shutdown(self) -> None:
        if self.stopping:
            return
        self.stopping = True
        self.recording = False
        self._close_stream()
        self._restore_media()
        if (
            self.worker is not None
            and self.worker.is_alive()
            and self.worker is not threading.current_thread()
        ):
            self._set_state("stopping")
            self.worker.join()
        self._clear_status()
        if self.instance_lock is not None:
            self.instance_lock.close()
            self.instance_lock = None


if __name__ == "__main__":
    # Logic here needs audio + MLX; pure helpers/tests live in backends.py & config.py.
    print("app.py: import OK")
