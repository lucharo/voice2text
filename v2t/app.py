"""The push-to-talk engine: record on hotkey, transcribe, clean up, paste.

macOS-only at runtime (osascript paste, pbcopy/pbpaste, System Events perms).
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

import numpy as np
import sounddevice as sd
from loguru import logger
from scipy.io import wavfile

from . import backends, config
from .config import Config


def short_model(name: str) -> str:
    """parakeet-tdt-0.6b-v3 -> parakeet-v3, whisper-large-v3-turbo -> whisper-turbo."""
    tail = name.rsplit("/", 1)[-1]
    for short in ("parakeet-v3", "parakeet-v2", "whisper-turbo"):
        a, b = short.split("-")
        if a in tail and b in tail:
            return short
    return tail


def _resolve_hotkey(name: str):
    from pynput import keyboard

    keys = {
        "cmd_r": keyboard.Key.cmd_r, "cmd_l": keyboard.Key.cmd_l,
        "alt_r": keyboard.Key.alt_r, "alt_l": keyboard.Key.alt_l,
        "ctrl_r": keyboard.Key.ctrl_r, "ctrl_l": keyboard.Key.ctrl_l,
    }
    if name not in keys:
        raise SystemExit(f"unknown hotkey {name!r}; choose: {', '.join(keys)}")
    return keys[name]


def check_and_request_permissions() -> None:
    """Open the right System Settings panes if Accessibility/Input Monitoring are missing."""
    logger.info("Checking permissions...")
    test = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to return "ok"'],
        capture_output=True, text=True,
    )
    if "not allowed" in test.stderr.lower() or test.returncode != 0:
        logger.warning("Permissions needed! Grant them to your TERMINAL APP (or SwiftBar if you start v2t from the menu).")
        subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
        input("Press Enter after granting Accessibility permission...")
        subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"])
        input("Press Enter after granting Input Monitoring permission...")
        logger.success("Permissions granted. Restart your terminal if the hotkey doesn't fire, then run again.")
        sys.exit(0)
    logger.success("Permissions OK")


class VoiceToText:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.stt_model = cfg.stt_model or backends.STT[cfg.backend].default_model
        self.stt = None  # loaded in run()
        self.recording = False
        self.processing = False
        self.frames: list[np.ndarray] = []
        self.stream = None
        self.record_start = 0.0
        self.was_playing = False

    # --- status file for the SwiftBar plugin -------------------------------
    def _write_status(self) -> None:
        d = config.run_dir()
        d.mkdir(parents=True, exist_ok=True)
        (d / "v2t.pid").write_text(str(os.getpid()))
        (d / "status.json").write_text(json.dumps({
            "pid": os.getpid(),
            "backend": self.cfg.backend,
            "model": short_model(self.stt_model),
            "mode": self.cfg.mode,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
        }))

    def _clear_status(self) -> None:
        d = config.run_dir()
        for name in ("v2t.pid", "status.json"):
            (d / name).unlink(missing_ok=True)

    # --- recording ----------------------------------------------------------
    def audio_callback(self, indata, frame_count, time_info, status):
        if self.recording:
            self.frames.append(indata.copy())

    def start_recording(self):
        if self.recording or self.processing:
            return
        self.recording = True
        self.frames = []
        self.record_start = time.perf_counter()
        if self.cfg.pause_music:
            r = subprocess.run(["nowplaying-cli", "get", "playbackRate"], capture_output=True, text=True)
            self.was_playing = r.stdout.strip() == "1"
            if self.was_playing:
                subprocess.run(["nowplaying-cli", "pause"])
        logger.info("Recording...")
        self.stream = sd.InputStream(
            samplerate=self.cfg.sample_rate, channels=1, dtype="float32", callback=self.audio_callback,
        )
        self.stream.start()

    def stop_recording(self):
        if not self.recording:
            return
        self.recording = False
        duration = time.perf_counter() - self.record_start
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        logger.info(f"Stopped ({duration:.1f}s)")
        if self.frames:
            threading.Thread(target=self.process_audio, args=(duration,), daemon=True).start()

    def process_audio(self, audio_s: float):
        self.processing = True
        try:
            audio = np.concatenate(self.frames, axis=0)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                wavfile.write(f.name, self.cfg.sample_rate, (audio * 32767).astype(np.int16))
                temp_path = f.name

            logger.info("Transcribing...")
            t0 = time.perf_counter()
            raw_text = self.stt.transcribe(temp_path)
            stt_s = time.perf_counter() - t0
            logger.info(f"Raw: {raw_text} ({stt_s:.2f}s)")
            if not raw_text:
                logger.warning("No speech detected")
                return

            cleaned_text, cleanup_s = raw_text, 0.0
            if self.cfg.cleanup_enabled:
                logger.info("Cleaning up...")
                try:
                    cleaned_text, _ttft, cleanup_s = backends.cleanup(
                        raw_text, self.cfg.cleanup_model, self.cfg.mode, self.cfg.ollama_url,
                    )
                    if not cleaned_text:
                        raise RuntimeError("empty response")
                    logger.info(f"Clean: {cleaned_text} ({cleanup_s:.2f}s)")
                except Exception as e:
                    logger.error(f"LLM cleanup failed: {e}")
                    logger.warning("Falling back to raw transcription")
                    cleaned_text = raw_text

            self.paste_to_cursor(cleaned_text)
            logger.success("Pasted!")

            if self.cfg.save_history:
                config.append_history({
                    "audio_s": round(audio_s, 2), "backend": self.cfg.backend, "model": self.stt_model,
                    "mode": self.cfg.mode, "stt_s": round(stt_s, 3), "cleanup_s": round(cleanup_s, 3),
                    "raw": raw_text, "clean": cleaned_text,
                })
        finally:
            if self.cfg.pause_music and self.was_playing:
                subprocess.run(["nowplaying-cli", "play"])
            self.processing = False

    def paste_to_cursor(self, text: str) -> None:
        """Copy, paste at cursor, restore the previous clipboard."""
        original = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
        subprocess.run(["pbcopy"], input=text, text=True)
        subprocess.run(["osascript", "-e", 'tell application "System Events" to keystroke "v" using command down'])
        time.sleep(0.15)
        subprocess.run(["pbcopy"], input=original, text=True)

    # --- run loop -----------------------------------------------------------
    def on_press(self, key):
        if key == self.hotkey:
            self.start_recording()

    def on_release(self, key):
        if key == self.hotkey:
            self.stop_recording()

    def warmup(self):
        logger.info("Loading models...")
        t0 = time.perf_counter()
        self.stt = backends.make_stt(self.cfg.backend, self.cfg.stt_model)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wavfile.write(f.name, self.cfg.sample_rate, np.zeros(self.cfg.sample_rate, dtype=np.int16))
            self.stt.transcribe(f.name)
        logger.success(f"{self.cfg.backend} ready ({time.perf_counter()-t0:.1f}s)")

        if self.cfg.cleanup_enabled:
            t0 = time.perf_counter()
            try:
                backends.cleanup("hi", self.cfg.cleanup_model, self.cfg.mode, self.cfg.ollama_url)
                logger.success(f"cleanup model ready ({time.perf_counter()-t0:.1f}s)")
            except Exception as e:
                logger.warning(f"cleanup warmup failed ({e}); will retry per transcription")

    def run(self):
        from pynput import keyboard

        self.hotkey = _resolve_hotkey(self.cfg.hotkey)
        self.warmup()
        self._write_status()
        signal.signal(signal.SIGTERM, lambda *_: (self._clear_status(), sys.exit(0)))

        logger.info(f"Voice-to-Text — {self.cfg.backend} · {self.cfg.mode}")
        if self.cfg.pause_music:
            logger.info("Pause Music — on")
        logger.info(f"Hold {self.cfg.hotkey} to record, release to transcribe and paste. Ctrl+C to quit.")
        try:
            with keyboard.Listener(on_press=self.on_press, on_release=self.on_release) as listener:
                listener.join()
        except KeyboardInterrupt:
            logger.info("Shutting down...")
        finally:
            self._clear_status()


if __name__ == "__main__":
    # ponytail: only the pure helper is testable off-Mac; the rest needs audio + MLX.
    assert short_model("mlx-community/parakeet-tdt-0.6b-v3") == "parakeet-v3"
    assert short_model("mlx-community/whisper-large-v3-turbo") == "whisper-turbo"
    assert short_model("custom/my-model") == "my-model"
    print("app.py: helper checks passed")
