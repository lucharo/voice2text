"""Small behavior checks for v2t's user-facing mechanics."""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import queue
import signal
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from v2t import app, backends, bench, cli, config, menubar, permissions, service


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
            mock.patch.object(app.subprocess, "run") as run,
        ):
            voice.start_recording()

        self.assertFalse(voice.recording)
        self.assertIsNone(voice.stream)
        self.assertEqual(config.read_status()["state"], "error")
        self.assertNotIn(
            ["nowplaying-cli", "pause"], [call.args[0] for call in run.call_args_list]
        )

    def test_permission_check_reports_missing_accessibility(self):
        with (
            mock.patch.object(
                app.permissions,
                "statuses",
                return_value={
                    "microphone": "granted",
                    "accessibility": "missing",
                },
            ),
            mock.patch.object(app.subprocess, "run") as run,
            self.assertRaises(SystemExit),
        ):
            app.check_and_request_permissions()

        run.assert_any_call(
            [
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ],
            check=False,
        )
        self.assertIn("Accessibility", config.read_last_error())

    def test_permission_check_requests_microphone_before_startup(self):
        with (
            mock.patch.object(
                app.permissions,
                "statuses",
                return_value={
                    "microphone": "not-requested",
                    "accessibility": "granted",
                },
            ),
            mock.patch.object(
                app.permissions, "request_microphone", return_value=True
            ) as request,
        ):
            app.check_and_request_permissions()

        request.assert_called_once_with()

    def test_permission_statuses_use_native_macos_checks(self):
        application_services = types.SimpleNamespace(
            AXIsProcessTrusted=lambda: True,
        )
        avfoundation = types.SimpleNamespace(
            AVCaptureDevice=types.SimpleNamespace(
                authorizationStatusForMediaType_=lambda _media: 3
            ),
            AVMediaTypeAudio="audio",
        )
        with (
            mock.patch.object(permissions.sys, "platform", "darwin"),
            mock.patch.dict(
                sys.modules,
                {
                    "ApplicationServices": application_services,
                    "AVFoundation": avfoundation,
                },
            ),
        ):
            states = permissions.statuses()

        self.assertEqual(
            states,
            {"microphone": "granted", "accessibility": "granted"},
        )

    def test_microphone_request_waits_for_native_result(self):
        device = types.SimpleNamespace(
            authorizationStatusForMediaType_=lambda _media: 0,
            requestAccessForMediaType_completionHandler_=lambda _media,
            callback: callback(True),
        )
        avfoundation = types.SimpleNamespace(
            AVCaptureDevice=device,
            AVMediaTypeAudio="audio",
        )
        with mock.patch.dict(sys.modules, {"AVFoundation": avfoundation}):
            self.assertTrue(permissions.request_microphone(timeout=0.1))

    def test_status_reports_the_running_overrides(self):
        cfg = config.Config(cleanup_enabled=False, mode="casual")
        voice = app.VoiceToText(cfg)
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)

        voice._set_state("idle")
        output = io.StringIO()
        with (
            contextlib.redirect_stdout(output),
        ):
            cli.cmd_status([])

        self.assertEqual(
            output.getvalue(),
            "idle\tparakeet-v3\toff\tcasual\t\n",
        )

    def test_recording_cannot_restart_before_processing_begins(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.recording = True
        voice.record_start = app.time.perf_counter()
        voice.frames = [np.ones((2, 1), dtype=np.float32)]
        voice.stream = mock.Mock()

        with mock.patch.object(app.sd, "InputStream") as input_stream:
            voice.stop_recording()
            voice.start_recording()

        self.assertTrue(voice.processing)
        self.assertEqual(voice.frames, [])
        frames, duration = voice.jobs.get_nowait()
        self.assertEqual(len(frames), 1)
        self.assertGreaterEqual(duration, 0)
        input_stream.assert_not_called()

    def test_queued_transcription_runs_on_the_processing_thread(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.jobs.put(([np.ones((8, 1), dtype=np.float32)], 1.0))

        with mock.patch.object(voice, "process_audio") as process:
            self.assertTrue(voice.process_next())

        process.assert_called_once()

    def test_empty_job_poll_keeps_the_hotkey_loop_alive(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))

        self.assertTrue(voice.process_next(timeout=0))

    def test_signal_waits_for_the_active_transcription_before_cleanup(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.instance_lock = config.acquire_instance_lock()
        voice.processing = True
        voice._set_state("transcribing")
        voice._start_shutdown_watcher()

        voice._handle_signal(signal.SIGTERM)
        voice.shutdown_watcher.join(timeout=1)

        self.assertTrue(voice.stopping)
        self.assertEqual(config.running_pid(), os.getpid())
        voice._set_state("cleaning")
        self.assertEqual(config.read_status()["state"], "stopping")
        with self.assertRaises(queue.Empty):
            voice.jobs.get_nowait()
        voice._handle_signal(signal.SIGTERM)
        self.assertTrue(voice.stopping)
        with self.assertRaises(SystemExit):
            voice._handle_signal(signal.SIGINT)

        voice.shutdown()
        self.assertIsNone(config.running_pid())

    def test_signal_exits_promptly_when_no_transcription_is_active(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.instance_lock = config.acquire_instance_lock()

        with self.assertRaises(SystemExit):
            voice._handle_signal()

        voice.shutdown()
        self.assertIsNone(config.running_pid())

    def test_shutdown_blocks_late_recording_and_closes_a_racing_stream(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        config.ensure_dirs()
        voice.stopping = True
        stream = voice.stream = mock.Mock()

        with mock.patch.object(app.sd, "InputStream") as input_stream:
            voice.start_recording()
            voice.shutdown()

        input_stream.assert_not_called()
        stream.stop.assert_called_once()
        stream.close.assert_called_once()

    def test_shutdown_wins_if_requested_while_the_stream_starts(self):
        voice = app.VoiceToText(
            config.Config(cleanup_enabled=False, pause_music=True)
        )
        stream = mock.Mock()
        stream.start.side_effect = lambda: setattr(voice, "stopping", True)

        with (
            mock.patch.object(app.sd, "InputStream", return_value=stream),
            mock.patch.object(app.subprocess, "run") as run,
        ):
            voice.start_recording()

        self.assertFalse(voice.recording)
        stream.stop.assert_called_once()
        stream.close.assert_called_once()
        self.assertNotIn(
            ["nowplaying-cli", "pause"], [call.args[0] for call in run.call_args_list]
        )

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

        with mock.patch.object(voice, "paste_to_cursor") as paste:
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
        fake_quartz = types.SimpleNamespace(
            CGEventCreateKeyboardEvent=lambda *_args: object(),
            CGEventPost=lambda *_args: None,
            CGEventSetFlags=mock.Mock(side_effect=RuntimeError("paste failed")),
            kCGEventFlagMaskCommand=1,
            kCGHIDEventTap=0,
        )

        with (
            mock.patch.dict(
                sys.modules, {"AppKit": fake_appkit, "Quartz": fake_quartz}
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

    def test_stale_status_cannot_reuse_an_unrelated_live_pid(self):
        config.ensure_dirs()
        config.write_status({"pid": os.getpid(), "state": "idle"})

        self.assertIsNone(config.read_status())
        self.assertFalse((config.run_dir() / "status.json").exists())

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

    def test_setup_quotes_the_whisper_extra_for_zsh(self):
        output = io.StringIO()
        with (
            mock.patch("builtins.input", side_effect=["2", "n"]),
            contextlib.redirect_stdout(output),
        ):
            cli.cmd_setup([])

        self.assertIn("uv tool install 'voice2text[whisper]'", output.getvalue())

    def test_menubar_install_builds_a_grantable_native_app(self):
        destination = Path(self.tempdir.name) / "Voice2Text.app"

        def compile_app(command, **_kwargs):
            if command[0] == "xcrun":
                Path(command[command.index("-o") + 1]).touch(mode=0o755)
            return mock.Mock(returncode=0)

        with (
            mock.patch.object(menubar, "app_path", return_value=destination),
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar, "signing_identity", return_value="-"),
            mock.patch.object(menubar.subprocess, "run", side_effect=compile_app),
            mock.patch.dict(
                os.environ, {"V2T_HOME": self.tempdir.name}, clear=True
            ),
        ):
            installed = menubar.install()

        info = plistlib.loads(
            (installed / "Contents" / "Info.plist").read_bytes()
        )
        self.assertEqual(
            info,
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "Voice2Text",
                "CFBundleIdentifier": "com.lucharo.voice2text",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Voice2Text",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.3.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSMicrophoneUsageDescription": "Voice2Text uses the microphone for fully local transcription.",
                "NSPrincipalClass": "NSApplication",
                "V2THome": self.tempdir.name,
                "V2TPythonExecutable": sys.executable,
            },
        )
        self.assertEqual(
            stat.S_IMODE(
                (installed / "Contents" / "MacOS" / "Voice2Text").stat().st_mode
            ),
            0o755,
        )

    def test_menubar_prefers_a_stable_apple_development_signature(self):
        output = """\
  1) ABCDEF \"Apple Development: Developer (TEAMID)\"
  2) 123456 \"Apple Distribution: Developer (TEAMID)\"
     2 valid identities found
"""
        with mock.patch.object(
            menubar.subprocess,
            "run",
            return_value=mock.Mock(stdout=output),
        ):
            self.assertEqual(
                menubar.signing_identity(),
                "Apple Development: Developer (TEAMID)",
            )

    def test_launch_agent_keeps_one_warm_v2t_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        app_executable = Path(self.tempdir.name) / "Voice2Text.app/Contents/MacOS/Voice2Text"
        app_executable.parent.mkdir(parents=True)
        app_executable.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(menubar, "app_executable", return_value=app_executable),
            mock.patch.object(service, "loaded", return_value=False),
            mock.patch.object(service, "service_pid", return_value=None),
            mock.patch.object(service, "_launchctl") as launchctl,
            mock.patch.object(service.sys, "platform", "darwin"),
        ):
            service.install()

        data = plistlib.loads(plist.read_bytes())
        self.assertEqual(
            data["ProgramArguments"],
            [
                str(app_executable),
                "--start",
            ],
        )
        self.assertTrue(data["RunAtLoad"])
        self.assertNotIn("KeepAlive", data)
        launchctl.assert_called_once_with(
            "bootstrap", f"gui/{os.getuid()}", str(plist)
        )

    def test_service_start_does_not_restart_a_healthy_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(
                config, "read_status", return_value={"pid": 42, "state": "idle"}
            ),
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.start()

        launchctl.assert_not_called()

    def test_service_start_restarts_a_launchd_menu_with_no_engine(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(service, "engine_ready", side_effect=[False, True]),
            mock.patch.object(config, "running_pid", return_value=None),
            mock.patch.object(service, "owned_engine_pid", return_value=None),
            mock.patch.object(config, "clear_last_error"),
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.start()

        launchctl.assert_called_once_with("kickstart", "-k", service.target())

    def test_service_start_waits_for_a_prelock_child(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(service, "engine_ready", side_effect=[False, True]),
            mock.patch.object(config, "running_pid", return_value=None),
            mock.patch.object(service, "owned_engine_pid", return_value=84),
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.start()

        launchctl.assert_not_called()

    def test_service_start_waits_until_models_are_ready(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        statuses = [
            {"pid": 42, "state": "loading-stt"},
            {"pid": 42, "state": "idle"},
        ]
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(config, "running_pid", return_value=84),
            mock.patch.object(service, "owned_engine_pid", return_value=84),
            mock.patch.object(config, "read_status", side_effect=statuses) as status,
        ):
            service.start()

        self.assertEqual(status.call_count, 2)

    def test_service_start_clears_a_stale_error_before_bootstrap(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", side_effect=[None, 42]),
            mock.patch.object(service.menubar, "running", return_value=False),
            mock.patch.object(config, "running_pid", return_value=None),
            mock.patch.object(service, "loaded", return_value=True),
            mock.patch.object(service, "engine_ready", side_effect=[False, True]),
            mock.patch.object(config, "clear_last_error") as clear_error,
            mock.patch.object(config, "read_last_error", return_value=""),
            mock.patch.object(service, "_launchctl"),
            mock.patch.object(service.time, "sleep"),
        ):
            service.start()

        clear_error.assert_called_once()

    def test_service_stop_waits_for_menu_and_engine_to_exit(self):
        with (
            mock.patch.object(service, "service_pid", side_effect=[42, None]),
            mock.patch.object(service, "owned_engine_pid", return_value=None),
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.stop()

        launchctl.assert_called_once_with("kill", "SIGTERM", service.target())

    def test_service_finds_its_child_before_engine_status_exists(self):
        with (
            mock.patch.object(config, "running_pid", return_value=None),
            mock.patch.object(
                service.subprocess,
                "run",
                return_value=mock.Mock(stdout="84\n", returncode=0),
            ) as run,
        ):
            self.assertEqual(service.owned_engine_pid(42), 84)

        run.assert_called_once_with(
            ["pgrep", "-P", "42"],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_service_stop_waits_only_for_its_owned_engine(self):
        with (
            mock.patch.object(service, "service_pid", side_effect=[42, None]),
            mock.patch.object(service, "owned_engine_pid", return_value=84),
            mock.patch.object(service, "_pid_alive", side_effect=[True, False]),
            mock.patch.object(service.os, "kill") as kill,
            mock.patch.object(service, "_launchctl") as launchctl,
            mock.patch.object(service.time, "sleep"),
        ):
            service.stop()

        kill.assert_called_once_with(84, signal.SIGTERM)
        launchctl.assert_called_once_with("kill", "SIGTERM", service.target())

    def test_service_preserves_an_external_engine(self):
        with (
            mock.patch.object(service, "service_pid", side_effect=[42, None]),
            mock.patch.object(service, "owned_engine_pid", return_value=None),
            mock.patch.object(service.os, "kill") as kill,
            mock.patch.object(service, "_launchctl"),
        ):
            service.stop()

        kill.assert_not_called()

    def test_service_stop_does_not_force_an_engine_already_stopping(self):
        with (
            mock.patch.object(service, "service_pid", side_effect=[42, None]),
            mock.patch.object(service, "owned_engine_pid", return_value=84),
            mock.patch.object(
                config, "read_status", return_value={"pid": 84, "state": "stopping"}
            ),
            mock.patch.object(service, "_pid_alive", side_effect=[True, False]),
            mock.patch.object(service.os, "kill") as kill,
            mock.patch.object(service, "_launchctl"),
            mock.patch.object(service.time, "sleep"),
        ):
            service.stop()

        kill.assert_not_called()

    def test_service_stop_tolerates_engine_exit_before_signal(self):
        with (
            mock.patch.object(service, "service_pid", side_effect=[42, None]),
            mock.patch.object(service, "owned_engine_pid", return_value=84),
            mock.patch.object(config, "read_status", return_value=None),
            mock.patch.object(service, "_pid_alive", return_value=False),
            mock.patch.object(
                service.os, "kill", side_effect=ProcessLookupError
            ),
            mock.patch.object(service, "_launchctl"),
        ):
            service.stop()

    def test_stop_reports_graceful_shutdown_honestly(self):
        output = io.StringIO()
        with (
            mock.patch.object(config, "running_pid", return_value=42),
            mock.patch.object(cli.os, "kill") as kill,
            contextlib.redirect_stdout(output),
        ):
            cli.cmd_stop([])

        kill.assert_called_once_with(42, signal.SIGTERM)
        self.assertEqual(output.getvalue(), "stopping v2t (pid 42)\n")

    def test_force_stop_uses_sigkill(self):
        with (
            mock.patch.object(config, "running_pid", return_value=42),
            mock.patch.object(cli.os, "kill") as kill,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            cli.cmd_stop(["--force"])

        kill.assert_called_once_with(42, signal.SIGKILL)

    def test_cleanup_modes_are_mutually_exclusive(self):
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            cli.cmd_run(["--casual", "--strict"])

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

    def test_cleanup_benchmark_skips_a_missing_engine(self):
        with (
            mock.patch.object(
                backends, "make_cleanup", side_effect=SystemExit("missing dependency")
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            results = bench.bench_cleanup(["mlx:model"], ["sample"], 1, "")

        self.assertIsNone(results["mlx:model"])

    def test_benchmark_repeat_must_be_positive(self):
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            bench.main(["--repeat", "0"])


if __name__ == "__main__":
    unittest.main()
