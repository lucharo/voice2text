"""Small behavior checks for v2t's user-facing mechanics."""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from v2t import app, backends, bench, cli, config, service


class V2TSmokeTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.env = mock.patch.dict(
            os.environ, {"V2T_HOME": self.tempdir.name}, clear=False
        )
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_audio_device_failure_returns_to_error_state(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)

        with (
            mock.patch.object(
                app.sd, "InputStream", side_effect=RuntimeError("device unavailable")
            ),
            mock.patch.object(app, "_refresh_swiftbar"),
            mock.patch.object(app.subprocess, "run") as run,
        ):
            voice.start_recording()

        self.assertFalse(voice.recording)
        self.assertIsNone(voice.stream)
        self.assertEqual(config.read_status()["state"], "error")
        self.assertNotIn(
            ["nowplaying-cli", "pause"], [call.args[0] for call in run.call_args_list]
        )

    def test_permission_check_reports_each_missing_native_permission(self):
        permissions = types.SimpleNamespace(
            AXIsProcessTrusted=lambda: True,
            CGPreflightListenEventAccess=lambda: False,
        )
        with (
            mock.patch.dict(sys.modules, {"ApplicationServices": permissions}),
            mock.patch.object(app.subprocess, "run") as run,
            self.assertRaises(SystemExit),
        ):
            app.check_and_request_permissions()

        run.assert_any_call(
            [
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            ],
            check=False,
        )
        self.assertIn("Input Monitoring", config.read_last_error())

    def test_status_reports_the_running_overrides(self):
        cfg = config.Config(cleanup_enabled=False, mode="casual")
        voice = app.VoiceToText(cfg)
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)

        with mock.patch.object(app, "_refresh_swiftbar"):
            voice._set_state("idle")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cli.cmd_status([])

        self.assertEqual(output.getvalue(), "idle\tparakeet-v3\toff\tcasual\t\n")

    def test_recording_cannot_restart_before_processing_begins(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.recording = True
        voice.record_start = app.time.perf_counter()
        voice.frames = [np.ones((2, 1), dtype=np.float32)]
        voice.stream = mock.Mock()

        with (
            mock.patch.object(app.threading, "Thread") as thread,
            mock.patch.object(app.sd, "InputStream") as input_stream,
        ):
            voice.stop_recording()
            voice.start_recording()

        self.assertTrue(voice.processing)
        self.assertEqual(voice.frames, [])
        thread.return_value.start.assert_called_once_with()
        input_stream.assert_not_called()

    def test_transcription_pipeline_pastes_cleanup_and_deletes_audio(self):
        voice = app.VoiceToText(config.Config(save_history=False))
        audio_path = None

        def transcribe(path):
            nonlocal audio_path
            audio_path = path
            return "raw words"

        voice.stt = mock.Mock(transcribe=transcribe)
        voice.cleaner = mock.Mock(model_id="cleaner")
        voice.cleaner.cleanup.return_value = ("Clean words.", 0.1, 0.2)
        voice.processing = True
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)

        with (
            mock.patch.object(voice, "paste_to_cursor") as paste,
            mock.patch.object(app, "_refresh_swiftbar"),
        ):
            voice.process_audio([np.ones((8, 1), dtype=np.float32)], 1.0)

        paste.assert_called_once_with("Clean words.")
        self.assertIsNotNone(audio_path)
        self.assertFalse(Path(audio_path).exists())
        self.assertEqual(config.read_status()["state"], "idle")

    def test_clipboard_is_restored_when_paste_fails(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        original = mock.Mock()
        original.types.return_value = ["public.png", "public.utf8-plain-text"]
        original.dataForType_.side_effect = lambda kind: {
            "public.png": b"png",
            "public.utf8-plain-text": b"text",
        }[kind]
        pasteboard = mock.Mock()
        pasteboard.pasteboardItems.return_value = [original]
        pasteboard.setString_forType_.return_value = True
        restored_item = mock.Mock()
        item_class = mock.Mock()
        item_class.alloc.return_value.init.return_value = restored_item
        fake_appkit = types.SimpleNamespace(
            NSPasteboard=mock.Mock(
                generalPasteboard=mock.Mock(return_value=pasteboard)
            ),
            NSPasteboardItem=item_class,
            NSPasteboardTypeString="public.utf8-plain-text",
        )

        with (
            mock.patch.dict(sys.modules, {"AppKit": fake_appkit}),
            mock.patch.object(
                app.subprocess, "run", side_effect=RuntimeError("paste failed")
            ),
            self.assertRaisesRegex(RuntimeError, "paste failed"),
        ):
            voice.paste_to_cursor("dictated")

        self.assertEqual(
            [call.args for call in restored_item.setData_forType_.call_args_list],
            [(b"png", "public.png"), (b"text", "public.utf8-plain-text")],
        )
        pasteboard.writeObjects_.assert_called_once_with([restored_item])

    def test_history_is_private_and_valid_jsonl(self):
        config.append_history({"raw": "hello", "clean": "Hello."})

        path = config.history_path()
        mode = stat.S_IMODE(path.stat().st_mode)

        self.assertEqual(mode, 0o600)
        self.assertEqual(path.read_text().count("\n"), 1)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

    def test_custom_config_keeps_existing_parent_permissions(self):
        parent = Path(self.tempdir.name) / "shared"
        parent.mkdir(mode=0o755)
        path = parent / "v2t.toml"

        config.write_config("[cleanup]\nenabled = false\n", path)

        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_second_instance_lock_is_rejected(self):
        first = config.acquire_instance_lock()
        self.addCleanup(first.close)

        with self.assertRaises(BlockingIOError):
            config.acquire_instance_lock()

    def test_missing_optional_stt_is_rendered_as_not_available(self):
        samples = [("short", Path("short.wav"), 1.0)]
        with mock.patch.object(backends, "make_stt", side_effect=SystemExit("missing")):
            results = bench.bench_stt(["whisper:model"], samples, repeat=1)

        table = bench.md_stt_table(results, samples)

        self.assertIsNone(results["whisper:model"])
        self.assertIn("| load | n/a |", table)
        self.assertIn("| short (1.0s) | n/a |", table)

    def test_setup_recommends_the_real_parakeet_install(self):
        output = io.StringIO()
        with (
            mock.patch("builtins.input", side_effect=["", "n"]),
            contextlib.redirect_stdout(output),
        ):
            cli.cmd_setup([])

        self.assertIn("uv tool install voice2text", output.getvalue())
        self.assertNotIn("voice2text[parakeet]", output.getvalue())
        self.assertEqual(stat.S_IMODE(config.config_path().stat().st_mode), 0o600)

    def test_swiftbar_command_installs_the_bundled_plugin(self):
        plugin_dir = Path(self.tempdir.name) / "plugins"
        with mock.patch.object(cli.subprocess, "run"):
            cli.cmd_swiftbar(["--dir", str(plugin_dir)])

        installed = plugin_dir / "v2t.5s.sh"
        source = Path(cli.__file__).resolve().parent.parent / "swiftbar" / "v2t.5s.sh"
        self.assertEqual(installed.read_text(), source.read_text())
        self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o755)

    def test_launch_agent_keeps_one_warm_v2t_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "loaded", return_value=False),
            mock.patch.object(service, "service_pid", return_value=None),
            mock.patch.object(service, "start") as start,
            mock.patch.object(service.sys, "platform", "darwin"),
        ):
            service.install()

        data = plistlib.loads(plist.read_bytes())
        self.assertEqual(data["ProgramArguments"], [sys.executable, "-m", "v2t"])
        self.assertTrue(data["RunAtLoad"])
        self.assertNotIn("KeepAlive", data)
        self.assertEqual(data["EnvironmentVariables"]["V2T_HOME"], self.tempdir.name)
        start.assert_called_once_with()

    def test_service_start_does_not_restart_a_healthy_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(config, "running_pid", return_value=42),
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.start()

        launchctl.assert_not_called()

    def test_cleanup_refuses_to_return_a_capped_partial_result(self):
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.apply_chat_template.return_value = "prompt"
        cleaner.tokenizer.encode.return_value = list(range(10))
        response = type("Response", (), {"text": "x"})
        cleaner._stream = lambda *_args, **kwargs: (
            response() for _ in range(kwargs["max_tokens"])
        )

        with self.assertRaisesRegex(RuntimeError, "token limit"):
            cleaner.cleanup("hello")


if __name__ == "__main__":
    unittest.main()
