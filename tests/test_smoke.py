"""Small behavior checks for v2t's user-facing mechanics."""

from __future__ import annotations

import contextlib
import io
import json
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
            newly_granted = app.check_and_request_permissions()

        request.assert_called_once_with()
        self.assertTrue(newly_granted)

    def test_permission_check_reports_no_new_grant_when_already_granted(self):
        with (
            mock.patch.object(
                app.permissions,
                "statuses",
                return_value={
                    "microphone": "granted",
                    "accessibility": "granted",
                },
            ),
            mock.patch.object(app.permissions, "request_microphone") as request,
        ):
            self.assertFalse(app.check_and_request_permissions())

        request.assert_not_called()

    def test_run_restarts_once_after_a_fresh_microphone_grant(self):
        started = mock.Mock()
        with (
            mock.patch.object(cli, "_which", return_value=None),
            mock.patch.dict(
                os.environ, {"V2T_LAUNCH_CONTEXT": "terminal"}, clear=False
            ),
            mock.patch.object(app, "check_and_request_permissions", return_value=True),
            mock.patch.object(app, "VoiceToText", return_value=started),
            mock.patch.object(cli.os, "execve") as execve,
        ):
            os.environ.pop("V2T_RESTARTED", None)
            cli.cmd_run([])
            execve.assert_called_once()
            executable, argv, env = execve.call_args.args
            self.assertEqual(executable, sys.executable)
            self.assertEqual(argv, [sys.executable, *sys.argv])
            self.assertEqual(env["V2T_RESTARTED"], "1")

            execve.reset_mock()
            with mock.patch.dict(os.environ, {"V2T_RESTARTED": "1"}, clear=False):
                cli.cmd_run([])
            execve.assert_not_called()

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
        voice.stream.stop.side_effect = lambda: self.assertTrue(
            voice.finalizing_recording
        )

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

    def test_signal_requests_prompt_shutdown_when_no_transcription_is_active(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.instance_lock = config.acquire_instance_lock()
        voice.startup_complete = True

        voice._handle_signal(signal.SIGTERM)

        self.assertTrue(voice.stopping)
        voice.shutdown()
        self.assertIsNone(config.running_pid())

    def test_signal_interrupts_model_startup(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))

        with self.assertRaises(SystemExit):
            voice._handle_signal(signal.SIGTERM)

    def test_run_drains_an_accepted_job_before_shutdown(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))

        class Listener:
            def __init__(self, **_callbacks):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def is_alive(self):
                return True

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(Listener=Listener)

        def queue_then_stop():
            voice.processing = True
            voice.stopping = True
            voice.jobs.put(([np.ones((8, 1), dtype=np.float32)], 1.0))

        def finish_job(*_):
            voice.processing = False

        with (
            mock.patch.dict(sys.modules, {"pynput": pynput}),
            mock.patch.object(app, "_resolve_hotkey", return_value=object()),
            mock.patch.object(app.signal, "signal"),
            mock.patch.object(voice, "warmup", side_effect=queue_then_stop),
            mock.patch.object(
                voice, "process_audio", side_effect=finish_job
            ) as process,
        ):
            voice.run()

        process.assert_called_once()

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
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, pause_music=True))
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
            "public.png": b"",
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
            [(b"", "public.png"), (b"text", "public.utf8-plain-text")],
        )
        pasteboard.writeObjects_.assert_called_once_with([restored_item])

    def test_clipboard_is_not_restored_over_a_new_user_copy(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        pasteboard = mock.Mock()
        pasteboard.pasteboardItems.return_value = []
        pasteboard.setString_forType_.return_value = True
        pasteboard.changeCount.side_effect = [9, 9, 10, 11]
        fake_appkit = types.SimpleNamespace(
            NSPasteboard=mock.Mock(
                generalPasteboard=mock.Mock(return_value=pasteboard)
            ),
            NSPasteboardItem=mock.Mock(),
            NSPasteboardTypeString="public.utf8-plain-text",
        )
        fake_quartz = types.SimpleNamespace(
            CGEventCreateKeyboardEvent=lambda *_args: object(),
            CGEventPost=lambda *_args: None,
            CGEventSetFlags=lambda *_args: None,
            kCGEventFlagMaskCommand=1,
            kCGHIDEventTap=0,
        )

        with (
            mock.patch.dict(
                sys.modules, {"AppKit": fake_appkit, "Quartz": fake_quartz}
            ),
            mock.patch.object(app.time, "sleep"),
        ):
            voice.paste_to_cursor("dictated")

        pasteboard.clearContents.assert_called_once()
        pasteboard.writeObjects_.assert_not_called()

    def test_paste_aborts_before_clear_if_clipboard_snapshot_keeps_changing(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        pasteboard = mock.Mock()
        pasteboard.pasteboardItems.return_value = []
        pasteboard.changeCount.side_effect = [1, 2, 3, 4]
        fake_appkit = types.SimpleNamespace(
            NSPasteboard=mock.Mock(
                generalPasteboard=mock.Mock(return_value=pasteboard)
            ),
            NSPasteboardItem=mock.Mock(),
            NSPasteboardTypeString="public.utf8-plain-text",
        )
        fake_quartz = types.SimpleNamespace(
            CGEventCreateKeyboardEvent=lambda *_args: object(),
            CGEventPost=lambda *_args: None,
            CGEventSetFlags=lambda *_args: None,
            kCGEventFlagMaskCommand=1,
            kCGHIDEventTap=0,
        )

        with (
            mock.patch.dict(
                sys.modules, {"AppKit": fake_appkit, "Quartz": fake_quartz}
            ),
            self.assertRaisesRegex(RuntimeError, "clipboard changed"),
        ):
            voice.paste_to_cursor("dictated")

        pasteboard.clearContents.assert_not_called()

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

        commands = []

        def compile_app(command, **_kwargs):
            commands.append(command)
            if command[0] == "xcrun":
                Path(command[command.index("-o") + 1]).touch(mode=0o755)
            return mock.Mock(returncode=0)

        with (
            mock.patch.object(menubar, "app_path", return_value=destination),
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar, "signing_identity", return_value="-"),
            mock.patch.object(menubar.subprocess, "run", side_effect=compile_app),
            mock.patch.dict(os.environ, {"V2T_HOME": self.tempdir.name}, clear=True),
        ):
            installed = menubar.install()

        info = plistlib.loads((installed / "Contents" / "Info.plist").read_bytes())
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

        codesign = next(command for command in commands if command[0] == "codesign")
        entitlements = codesign[codesign.index("--entitlements") + 1]
        self.assertTrue(entitlements.endswith("Voice2Text.entitlements.plist"))
        self.assertEqual(
            [item for item in codesign if item != entitlements][:-1],
            [
                "codesign",
                "--force",
                "--options",
                "runtime",
                "--entitlements",
                "--sign",
                "-",
            ],
        )
        self.assertTrue(
            codesign[-1].endswith("/Voice2Text.app")
        )  # staged bundle, moved after signing

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
        self.assertEqual(
            menubar.signing_flags("Apple Development: Developer (TEAMID)"),
            ["--options", "runtime"],
        )

    def test_menubar_prefers_developer_id_over_development_signature(self):
        output = """\
  1) ABCDEF \"Apple Development: Developer (TEAMID)\"
  2) 123456 \"Developer ID Application: Developer (TEAMID)\"
     2 valid identities found
"""
        with mock.patch.object(
            menubar.subprocess,
            "run",
            return_value=mock.Mock(stdout=output),
        ):
            self.assertEqual(
                menubar.signing_identity(),
                "Developer ID Application: Developer (TEAMID)",
            )
        self.assertEqual(
            menubar.signing_flags("Developer ID Application: Developer (TEAMID)"),
            ["--options", "runtime", "--timestamp"],
        )

    def test_launch_agent_keeps_one_warm_v2t_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        app_executable = (
            Path(self.tempdir.name) / "Voice2Text.app/Contents/MacOS/Voice2Text"
        )
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
        launchctl.assert_called_once_with("bootstrap", f"gui/{os.getuid()}", str(plist))

    def test_service_start_does_not_restart_a_healthy_process(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(
                config, "read_status", return_value={"pid": 84, "state": "idle"}
            ),
            mock.patch.object(service, "_is_child", return_value=True),
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
            mock.patch.object(service, "stop") as stop,
            mock.patch.object(service, "_launchctl") as launchctl,
        ):
            service.start()

        stop.assert_called_once()
        launchctl.assert_called_once_with("kickstart", service.target())

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
            {"pid": 84, "state": "loading-stt"},
            {"pid": 84, "state": "idle"},
        ]
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(config, "running_pid", return_value=84),
            mock.patch.object(service, "_is_child", return_value=True),
            mock.patch.object(config, "read_status", side_effect=statuses) as status,
        ):
            service.start()

        self.assertEqual(status.call_count, 2)

    def test_service_does_not_accept_an_external_ready_engine(self):
        with (
            mock.patch.object(
                config, "read_status", return_value={"pid": 84, "state": "idle"}
            ),
            mock.patch.object(service, "_is_child", return_value=False),
        ):
            self.assertFalse(service.engine_ready(42))

    def test_service_start_rejects_an_external_engine(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(service, "engine_ready", return_value=False),
            mock.patch.object(config, "running_pid", return_value=84),
            mock.patch.object(service, "_is_child", return_value=False),
        ):
            with self.assertRaisesRegex(SystemExit, "outside the login service"):
                service.start()

    def test_service_status_reports_an_external_engine_honestly(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", return_value=42),
            mock.patch.object(config, "running_pid", return_value=84),
            mock.patch.object(service, "_is_child", return_value=False),
        ):
            self.assertEqual(
                service.status(),
                "menu running; v2t is running outside the login service",
            )

    def test_service_start_clears_a_stale_error_before_bootstrap(self):
        plist = Path(self.tempdir.name) / "com.lucharo.voice2text.plist"
        plist.touch()
        with (
            mock.patch.object(service, "plist_path", return_value=plist),
            mock.patch.object(service, "service_pid", side_effect=[None, 42, 42]),
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
            mock.patch.object(service.os, "kill", side_effect=ProcessLookupError),
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

    def _audio_file(self, name: str = "memo.opus") -> Path:
        path = Path(self.tempdir.name) / name
        path.write_bytes(b"not really audio; the backend is mocked")
        return path

    def _transcribe(self, argv: list[str], stt, cleaner=None) -> str:
        """Run `v2t transcribe` with both backends mocked; returns stdout."""
        output = io.StringIO()
        with (
            mock.patch.object(backends, "make_stt", return_value=stt),
            mock.patch.object(
                backends, "make_cleanup", return_value=cleaner
            ) as make_cleanup,
            mock.patch.object(cli, "_audio_seconds", return_value=10.0),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(cli.cmd_transcribe(argv), 0)
        self.make_cleanup = make_cleanup
        return output.getvalue()

    def test_transcribe_is_verbatim_and_loads_no_cleaner_by_default(self):
        path = self._audio_file()
        stt = mock.Mock(transcribe=mock.Mock(return_value="hey um there"))

        text = self._transcribe([str(path)], stt)

        self.assertEqual(text, "hey um there\n")
        stt.transcribe.assert_called_once_with(str(path))
        self.make_cleanup.assert_not_called()

    def test_transcribe_mode_flag_turns_the_cleanup_pass_on(self):
        path = self._audio_file()
        stt = mock.Mock(transcribe=mock.Mock(return_value="hey um there"))
        cleaner = mock.Mock(
            model_id="cleaner",
            cleanup=mock.Mock(return_value=("Hey, there.", 0.1, 0.4)),
        )

        text = self._transcribe(["--casual", str(path)], stt, cleaner)

        self.assertEqual(text, "Hey, there.\n")
        cleaner.cleanup.assert_called_once_with("hey um there", "casual")

    def test_transcribe_keeps_the_raw_text_when_cleanup_fails(self):
        path = self._audio_file()
        stt = mock.Mock(transcribe=mock.Mock(return_value="hey um there"))
        cleaner = mock.Mock(
            model_id="cleaner", cleanup=mock.Mock(side_effect=RuntimeError("no model"))
        )

        text = self._transcribe(["--clean", str(path)], stt, cleaner)

        self.assertEqual(text, "hey um there\n")

    def test_transcribe_labels_each_file_when_given_several(self):
        first, second = self._audio_file("a.opus"), self._audio_file("b.m4a")
        stt = mock.Mock(transcribe=mock.Mock(side_effect=["one", "two"]))

        text = self._transcribe([str(first), str(second)], stt)

        self.assertEqual(text, "# a.opus\none\n\n# b.m4a\ntwo\n")

    def test_transcribe_records_each_file_in_history(self):
        path = self._audio_file()
        stt = mock.Mock(transcribe=mock.Mock(return_value="hey um there"))

        self._transcribe([str(path)], stt)

        record = json.loads(config.history_path().read_text().splitlines()[-1])
        self.assertEqual(
            record,
            {
                "ts": record["ts"],
                "source": str(path),
                "audio_s": 10.0,
                "backend": "parakeet",
                "model": backends.PARAKEET_DEFAULT,
                "cleanup_engine": None,
                "cleanup_model": None,
                "mode": "casual",
                "stt_s": record["stt_s"],
                "cleanup_s": 0.0,
                "raw": "hey um there",
                "clean": "hey um there",
            },
        )

    def test_transcribe_writes_no_history_when_the_user_turned_it_off(self):
        config.write_config("[behavior]\nsave_history = false\n")
        stt = mock.Mock(transcribe=mock.Mock(return_value="hey um there"))

        self._transcribe([str(self._audio_file())], stt)

        self.assertFalse(config.history_path().exists())

    def test_transcribe_rejects_a_missing_file_before_loading_a_model(self):
        missing = str(Path(self.tempdir.name) / "gone.wav")

        with (
            mock.patch.object(backends, "make_stt") as make_stt,
            self.assertRaises(SystemExit),
        ):
            cli.cmd_transcribe([missing])

        make_stt.assert_not_called()

    def test_cleanup_modes_are_mutually_exclusive(self):
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            cli.cmd_run(["--casual", "--strict"])

    def _mlx_cleaner(self, replies):
        """An MLXCleanup with the model mocked: each call streams the next reply."""
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.apply_chat_template.return_value = "prompt"
        cleaner.tokenizer.encode.side_effect = lambda text: text.split()
        cleaner.last_stats = {}
        queue_ = list(replies)
        response = type("Response", (), {"text": ""})

        def stream(*_args, **kwargs):
            reply = queue_.pop(0)
            if reply is None:  # loop forever: emit max_tokens single tokens
                for _ in range(kwargs["max_tokens"]):
                    yield response()
                return
            for piece in reply.split(" "):
                r = response()
                r.text = piece + " "
                yield r

        cleaner._stream = stream
        return cleaner

    def test_cleanup_keeps_the_raw_chunk_when_the_model_hits_its_token_limit(self):
        cleaner = self._mlx_cleaner([None])

        text, _ttft, _total = cleaner.cleanup("hello um there friend", "casual")

        self.assertEqual(text, "hello um there friend")
        self.assertEqual(cleaner.last_stats, {"chunks": 1, "guarded": 0, "limited": 1})

    def test_cleanup_keeps_the_raw_chunk_when_the_output_length_drifts(self):
        raw = "so um I think we should ship the migration on friday and watch the error rates"
        cleaner = self._mlx_cleaner(["Ship it Friday."])

        text, _ttft, _total = cleaner.cleanup(raw, "casual")

        self.assertEqual(text, raw)
        self.assertEqual(cleaner.last_stats["guarded"], 1)

    def test_cleanup_accepts_a_faithful_rewrite(self):
        raw = "so um I think we should ship the migration on friday"
        cleaner = self._mlx_cleaner(
            ["So, I think we should ship the migration on Friday."]
        )

        text, ttft, total = cleaner.cleanup(raw, "casual")

        self.assertEqual(text, "So, I think we should ship the migration on Friday.")
        self.assertIsNotNone(ttft)
        self.assertGreaterEqual(total, ttft)
        self.assertEqual(cleaner.last_stats, {"chunks": 1, "guarded": 0, "limited": 0})

    def test_long_dictations_are_cleaned_in_sentence_chunks(self):
        sentences = [f"Sentence number {i} has exactly seven words." for i in range(40)]
        raw = " ".join(sentences)
        chunks = backends.chunk_text(raw)

        self.assertGreater(len(chunks), 1)
        self.assertEqual(" ".join(chunks), raw, "chunking is lossless")
        for chunk in chunks:
            self.assertLessEqual(len(chunk.split()), backends.CHUNK_WORDS)
            self.assertTrue(chunk.endswith("."), "chunks end on sentence boundaries")

        cleaner = self._mlx_cleaner([chunk for chunk in chunks])
        text, _ttft, _total = cleaner.cleanup(raw, "casual")
        self.assertEqual(text, raw)
        self.assertEqual(cleaner.last_stats["chunks"], len(chunks))

    def test_unpunctuated_run_on_speech_is_still_chunked(self):
        raw = " ".join(["word"] * 300)

        chunks = backends.chunk_text(raw)

        self.assertEqual([len(c.split()) for c in chunks], [120, 120, 60])

    def _tapper(self):
        """A VoiceToText whose audio stream is mocked, plus a helper to tap the hotkey."""
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.hotkey = "HOTKEY"
        stream = mock.patch.object(app.sd, "InputStream")
        self.addCleanup(stream.stop)
        stream.start()
        clock = mock.patch.object(app.time, "perf_counter")
        self.addCleanup(clock.stop)
        now = clock.start()
        now.return_value = 100.0

        def press_release(at: float, held: float):
            now.return_value = at
            voice.on_press("HOTKEY")
            voice.frames = [np.ones((8, 1), dtype=np.float32)]
            now.return_value = at + held
            voice.on_release("HOTKEY")

        return voice, press_release

    def test_a_short_tap_is_discarded_not_transcribed(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=0.1)

        self.assertFalse(voice.recording)
        self.assertFalse(voice.processing)
        self.assertTrue(voice.jobs.empty())
        self.assertEqual(config.read_status()["state"], "idle")

    def test_a_double_tap_records_hands_free_until_the_next_tap(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=0.1)
        tap(at=100.3, held=0.1)

        self.assertTrue(voice.latched)
        self.assertTrue(voice.recording, "still recording after the second release")
        self.assertEqual(config.read_status()["state"], "recording")

        tap(at=110.0, held=0.1)

        self.assertFalse(voice.latched)
        self.assertFalse(voice.recording)
        self.assertTrue(voice.processing)
        _frames, duration = voice.jobs.get_nowait()
        self.assertGreater(duration, 9.0)

    def test_two_taps_far_apart_do_not_latch(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=0.1)
        tap(at=101.0, held=0.1)

        self.assertFalse(voice.latched)
        self.assertFalse(voice.recording)
        self.assertTrue(voice.jobs.empty())

    def test_holding_the_hotkey_still_transcribes_on_release(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=2.0)

        self.assertFalse(voice.latched)
        self.assertTrue(voice.processing)
        self.assertFalse(voice.jobs.empty())

    def test_cleanup_prompt_is_a_system_message_with_examples_then_the_text(self):
        messages = backends.cleanup_messages("raw words", "casual")

        self.assertEqual(messages[0]["role"], "system")
        self.assertEqual(messages[0]["content"], backends.PROMPTS["casual"])
        self.assertEqual(
            [m["role"] for m in messages[1:-1]],
            ["user", "assistant"] * len(backends.EXAMPLES["casual"]),
        )
        self.assertEqual(messages[-1], {"role": "user", "content": "raw words"})
        self.assertNotIn("raw words", "".join(m["content"] for m in messages[:-1]))

    def test_mlx_cleanup_sends_the_chat_messages_in_non_thinking_mode(self):
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.apply_chat_template.return_value = "prompt"
        cleaner.tokenizer.encode.return_value = [1, 2, 3]
        response = type("Response", (), {"text": "Hello, there."})
        cleaner._stream = lambda *_args, **_kwargs: iter([response()])

        text, ttft, total = cleaner.cleanup("hello um there", "strict")

        self.assertEqual(text, "Hello, there.")
        self.assertIsNotNone(ttft)
        self.assertGreaterEqual(total, ttft)
        cleaner.tokenizer.apply_chat_template.assert_called_once_with(
            backends.cleanup_messages("hello um there", "strict"),
            add_generation_prompt=True,
            enable_thinking=False,
        )

    def test_ollama_cleanup_uses_the_chat_api_with_the_same_messages(self):
        lines = [
            json.dumps({"message": {"role": "assistant", "content": "Hello, "}}),
            json.dumps({"message": {"role": "assistant", "content": "there."}}),
            json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}),
        ]
        stream = mock.MagicMock()
        stream.__enter__.return_value = iter(line.encode() + b"\n" for line in lines)

        with mock.patch.object(
            backends.urllib.request, "urlopen", return_value=stream
        ) as urlopen:
            text, ttft, _total = backends.OllamaCleanup("m", "http://o").cleanup(
                "hello there", "casual"
            )

        request = urlopen.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(text, "Hello, there.")
        self.assertIsNotNone(ttft)
        self.assertEqual(request.full_url, "http://o/api/chat")
        self.assertEqual(
            body,
            {
                "model": "m",
                "messages": backends.cleanup_messages("hello there", "casual"),
                "stream": True,
                "options": {"temperature": 0, "num_predict": 68},
            },
        )

    def _history_output(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.cmd_history(argv)
        return code, out.getvalue(), err.getvalue()

    def test_history_command_lists_recent_entries_oldest_first(self):
        for index in range(12):
            config.append_history(
                {
                    "audio_s": 7.2,
                    "stt_s": 0.5,
                    "cleanup_s": 0.2,
                    "raw": f"um entry {index}",
                    "clean": f"Entry {index}.",
                }
            )

        code, out, _err = self._history_output([])
        cleans = [line.strip() for line in out.splitlines() if line.startswith("  ")]

        self.assertEqual(code, 0)
        self.assertEqual(cleans, [f"Entry {i}." for i in range(2, 12)])
        self.assertIn("0:07 audio · stt 0.5s · clean 0.2s", out)

        code, out, _err = self._history_output(["-n", "2", "--raw"])
        self.assertEqual(code, 0)
        self.assertEqual(
            [line.strip() for line in out.splitlines() if line.startswith("  ")],
            [
                "raw:   um entry 10",
                "clean: Entry 10.",
                "raw:   um entry 11",
                "clean: Entry 11.",
            ],
        )

    def test_history_command_searches_raw_and_clean_text(self):
        config.append_history({"raw": "buy milk um", "clean": "Buy milk."})
        config.append_history({"raw": "call mum", "clean": "Call Mum."})
        config.append_history({"source": "/tmp/memo.opus", "raw": "hi", "clean": "Hi."})

        code, out, _err = self._history_output(["MUM"])
        self.assertEqual(code, 0)
        self.assertEqual(out.strip().splitlines()[-1].strip(), "Call Mum.")

        code, out, _err = self._history_output(["milk", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["clean"], "Buy milk.")

        code, out, _err = self._history_output(["memo"])
        self.assertEqual((code, out), (1, ""))
        self.assertIn("no transcriptions match 'memo'", _err)

        code, _out, _err = self._history_output(["opus"])
        self.assertEqual(code, 1, "source path is metadata, not searched text")

    def test_history_command_reports_an_empty_history(self):
        code, out, err = self._history_output([])

        self.assertEqual((code, out), (1, ""))
        self.assertIn("no transcriptions yet", err)

    def test_dictionary_terms_reach_the_prompt_and_replacements_the_text(self):
        config.write_dictionary(
            ["Parakeet", "Zscaler"], [("whisper flow", "Wispr Flow")]
        )

        terms, replacements = config.read_dictionary()
        self.assertEqual(terms, ["Parakeet", "Zscaler"])
        self.assertEqual(replacements, [("whisper flow", "Wispr Flow")])
        self.assertEqual(stat.S_IMODE(config.dictionary_path().stat().st_mode), 0o600)

        system = backends.cleanup_messages("x", "casual", terms)[0]["content"]
        self.assertIn("Parakeet, Zscaler", system)
        self.assertNotIn("Parakeet", backends.cleanup_messages("x")[0]["content"])

        self.assertEqual(
            config.apply_replacements(
                "I used Whisper Flow and whisperflow", replacements
            ),
            "I used Wispr Flow and whisperflow",
        )

    def test_replacements_are_literal_even_with_backslashes(self):
        text = config.apply_replacements(
            "path is c drive", [("c drive", r"C:\drive\1"), ("path", r"\g<0>")]
        )

        self.assertEqual(text, r"\g<0> is C:\drive\1")

    def test_dictionary_rewrite_keeps_user_comments(self):
        config.write_dictionary(["Alpha"], [])
        path = config.dictionary_path()
        path.write_text(path.read_text() + "# team names below\nBeta\n")

        config.write_dictionary(*config.read_dictionary())

        body = path.read_text()
        self.assertIn("# team names below", body)
        self.assertEqual(body.count("# v2t dictionary"), 1, "header emitted once")
        self.assertEqual(config.read_dictionary(), (["Alpha", "Beta"], []))

    def test_dictionary_edits_apply_without_a_restart(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.cleaner = mock.Mock(vocabulary=())
        config.write_dictionary(["Alpha"], [("a", "b")])

        voice.refresh_dictionary()
        self.assertEqual(voice.cleaner.vocabulary, ("Alpha",))

        config.write_dictionary(["Alpha", "Gamma"], [("a", "b")])
        os.utime(config.dictionary_path(), (1, 2_000_000_000))  # force a new mtime
        voice.refresh_dictionary()

        self.assertEqual(voice.cleaner.vocabulary, ("Alpha", "Gamma"))
        self.assertEqual(voice.replacements, [("a", "b")])

    def test_whisper_resolves_its_weights_once_and_transcribes_from_the_local_path(
        self,
    ):
        import types

        weights = Path(self.tempdir.name) / "snap"
        weights.mkdir()
        (weights / "weights.safetensors").write_bytes(b"w")
        whisper = types.SimpleNamespace(
            transcribe=mock.Mock(return_value={"text": " hi there "})
        )
        hub = types.SimpleNamespace(
            snapshot_download=mock.Mock(return_value=str(weights)),
            constants=types.SimpleNamespace(
                HF_HUB_CACHE=self.tempdir.name, HF_HUB_OFFLINE=False
            ),
        )
        with mock.patch.dict(
            sys.modules, {"mlx_whisper": whisper, "huggingface_hub": hub}
        ):
            stt = backends.WhisperSTT()
            text = stt.transcribe("a.wav")

        self.assertEqual(text, "hi there")
        hub.snapshot_download.assert_called_once_with(backends.WHISPER_DEFAULT)
        whisper.transcribe.assert_called_once_with(
            "a.wav", path_or_hf_repo=str(weights)
        )

    def test_whisper_uses_a_local_model_directory_as_is(self):
        import types

        local = Path(self.tempdir.name) / "whisper-local"
        local.mkdir()
        whisper = types.SimpleNamespace(
            transcribe=mock.Mock(return_value={"text": "ok"})
        )
        hub = types.SimpleNamespace(snapshot_download=mock.Mock())
        with mock.patch.dict(
            sys.modules, {"mlx_whisper": whisper, "huggingface_hub": hub}
        ):
            stt = backends.WhisperSTT(str(local))
            stt.transcribe("a.wav")

        hub.snapshot_download.assert_not_called()
        whisper.transcribe.assert_called_once_with("a.wav", path_or_hf_repo=str(local))

    def test_whisper_snapshot_without_weights_is_retried_online(self):
        import types

        cache = Path(self.tempdir.name) / "hub"
        snapshot = cache / "models--org--w" / "snapshots" / "abc"
        snapshot.mkdir(parents=True)
        (snapshot / "config.json").write_text("{}")
        constants = types.SimpleNamespace(HF_HUB_CACHE=str(cache), HF_HUB_OFFLINE=False)
        seen = []

        def snapshot_download(_repo):
            seen.append(constants.HF_HUB_OFFLINE)
            if not constants.HF_HUB_OFFLINE:
                (snapshot / "weights.safetensors").write_bytes(b"w")
            return str(snapshot)

        hub = types.SimpleNamespace(
            snapshot_download=snapshot_download, constants=constants
        )
        whisper = types.SimpleNamespace(
            transcribe=mock.Mock(return_value={"text": "ok"})
        )
        with mock.patch.dict(
            sys.modules, {"mlx_whisper": whisper, "huggingface_hub": hub}
        ):
            stt = backends.WhisperSTT("org/w")

        self.assertEqual(seen, [True, False], "offline first, then online to finish")
        self.assertEqual(stt.model_path, str(snapshot))

    def test_dictionary_rewrite_dedupes_case_insensitively_and_keeps_comments_out(self):
        config.write_dictionary(["Orx", "orx", "GSK"], [("a", "b"), ("A", "B")])

        terms, replacements = config.read_dictionary()

        self.assertEqual((terms, replacements), (["Orx", "GSK"], [("a", "b")]))
        self.assertTrue(
            config.dictionary_path().read_text().startswith("# v2t dictionary")
        )

    def test_dictionary_import_merges_wispr_entries_read_only(self):
        import sqlite3

        db = Path(self.tempdir.name) / "flow.sqlite"
        con = sqlite3.connect(db)
        con.execute(
            "create table Dictionary (phrase text, replacement text, isDeleted int, frequencyUsed int)"
        )
        con.executemany(
            "insert into Dictionary values (?, ?, ?, ?)",
            [
                ("Parakeet", None, 0, 5),
                ("gsk", "GSK", 0, 9),
                ("Deleted", None, 1, 1),
                ("Same", "same", 0, 0),
            ],
        )
        con.commit()
        con.close()
        config.write_dictionary(["Existing"], [])

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.cmd_dictionary(["import-wispr", "--db", str(db)])

        terms, replacements = config.read_dictionary()
        self.assertEqual(code, 0)
        self.assertEqual(terms, ["Existing", "Parakeet"])
        self.assertEqual(replacements, [("gsk", "GSK"), ("Same", "same")])
        self.assertIn("imported 3 new entries", out.getvalue())

    def test_cached_models_load_without_hub_revision_checks(self):
        import types

        cache = Path(self.tempdir.name) / "hub"
        snapshot = cache / "models--org--cached" / "snapshots" / "abc"
        snapshot.mkdir(parents=True)
        (snapshot / "config.json").write_text("{}")
        constants = types.SimpleNamespace(HF_HUB_CACHE=str(cache), HF_HUB_OFFLINE=False)
        seen = []

        def loader():
            seen.append(constants.HF_HUB_OFFLINE)
            return "model"

        with mock.patch.dict(
            sys.modules, {"huggingface_hub": types.SimpleNamespace(constants=constants)}
        ):
            self.assertEqual(backends.load_cache_first("org/cached", loader), "model")
            self.assertEqual(backends.load_cache_first("org/missing", loader), "model")

        self.assertEqual(seen, [True, False], "offline only when the snapshot exists")
        self.assertFalse(constants.HF_HUB_OFFLINE, "flag restored afterwards")

    def test_partial_cache_falls_back_to_an_online_load(self):
        import types

        cache = Path(self.tempdir.name) / "hub"
        snapshot = cache / "models--org--partial" / "snapshots" / "abc"
        snapshot.mkdir(parents=True)
        (snapshot / "config.json").write_text("{}")
        constants = types.SimpleNamespace(HF_HUB_CACHE=str(cache), HF_HUB_OFFLINE=False)
        attempts = []

        def loader():
            attempts.append(constants.HF_HUB_OFFLINE)
            if constants.HF_HUB_OFFLINE:
                raise OSError("weights not in cache")
            return "model"

        with mock.patch.dict(
            sys.modules, {"huggingface_hub": types.SimpleNamespace(constants=constants)}
        ):
            self.assertEqual(backends.load_cache_first("org/partial", loader), "model")

        self.assertEqual(attempts, [True, False])
        self.assertFalse(constants.HF_HUB_OFFLINE)

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
