"""Small behavior checks for v2t's user-facing mechanics."""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import queue
import signal
import socket
import sqlite3
import stat
import sys
import tempfile
import threading
import tomllib
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.io import wavfile

from v2t import app, backends, bench, cli, config, coreml, menubar, permissions, service


class V2TSmokeTests(unittest.TestCase):
    def test_app_version_matches_package_release(self):
        project = Path(__file__).resolve().parents[1] / "pyproject.toml"
        expected = tomllib.loads(project.read_text())["project"]["version"]
        self.assertEqual(menubar.__version__, expected)

    def test_grid_compute_uses_the_shipped_short_and_long_clip_paths(self):
        from utils.asr_grid import grid

        row = {"duration_s": 20, "offline_s": 7, "stream_busy_s": 5,
               "stream_wait_s": 2, "stream_feed_s": 3}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "results" / "fixture").mkdir(parents=True)
            (root / "sets").mkdir()
            for duration, expected in ((20, 10), (60, 5)):
                row["duration_s"] = duration
                clip = {"id": "clip", "text": "hello", "lang": "en", "duration_s": duration}
                result = {"id": "clip", "offline": "hello", "stream": "hello", **row}
                (root / "sets" / "fixture.jsonl").write_text(json.dumps(clip) + "\n")
                (root / "results" / "fixture" / "parakeet-v3.jsonl").write_text(json.dumps(result) + "\n")
                scoring_dependencies = {
                    "whisper_normalizer.basic": types.SimpleNamespace(BasicTextNormalizer=lambda: str.lower),
                    "whisper_normalizer.english": types.SimpleNamespace(EnglishTextNormalizer=lambda: str.lower),
                    "rapidfuzz.distance": types.SimpleNamespace(Levenshtein=types.SimpleNamespace(distance=lambda a, b: 0 if a == b else 1)),
                }
                with mock.patch.object(grid, "SETS", root / "sets"), mock.patch.object(grid, "RESULTS", root / "results"), mock.patch.dict(sys.modules, scoring_dependencies):
                    scored = grid.score_set("fixture")
                self.assertEqual(scored[0]["busy_s"], expected)
                self.assertEqual(scored[0]["rtf"], expected / duration)

    def test_grid_empty_cell_has_no_scored_results(self):
        from utils.asr_grid import grid

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "results" / "fixture").mkdir(parents=True)
            (root / "sets").mkdir()
            clip = {"id": "clip", "text": "hello", "lang": "en", "duration_s": 20}
            (root / "sets" / "fixture.jsonl").write_text(json.dumps(clip) + "\n")
            (root / "results" / "fixture" / "parakeet-v3.jsonl").touch()
            with mock.patch.object(grid, "SETS", root / "sets"), mock.patch.object(grid, "RESULTS", root / "results"):
                self.assertEqual(grid.score_set("fixture"), [])

    def test_grid_flags_empty_and_partial_cells_beside_complete_ones(self):
        from utils.asr_grid import grid

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "results" / "fixture").mkdir(parents=True)
            (root / "sets").mkdir()
            clips = [{"id": f"c{i}", "text": "hi", "lang": "en", "duration_s": 5} for i in range(3)]
            (root / "sets" / "fixture.jsonl").write_text("".join(json.dumps(c) + "\n" for c in clips))
            cells = root / "results" / "fixture"
            (cells / "parakeet-v3.jsonl").write_text("".join(json.dumps({"id": c["id"]}) + "\n" for c in clips))
            (cells / "phonon-2.jsonl").write_text(json.dumps({"id": "c0"}) + "\n")
            (cells / "cohere-transcribe.jsonl").touch()
            with mock.patch.object(grid, "SETS", root / "sets"), mock.patch.object(grid, "RESULTS", root / "results"):
                self.assertEqual(
                    grid.incomplete_cells("fixture"),
                    {"cohere-transcribe": (0, 3), "phonon-2": (1, 3)},
                )

    def test_cleanup_report_only_uses_the_saved_configuration(self):
        from utils.cleanup_speed import bench_cleanup

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = {"config": {"model": "measured-model", "mode": "strict", "n_terms": 13},
                   "baseline_chunks": 1, "prefix_same": True, "lookup_same": True}
            for variant in ("baseline", "prefix", "lookup"):
                row[f"{variant}_s"] = 2.0
                row[f"{variant}_last_chunk_s"] = 2.0
            (root / "results.jsonl").write_text(json.dumps(row) + "\n")
            with mock.patch.object(bench_cleanup, "OUT", root), mock.patch.object(config, "read_dictionary", side_effect=AssertionError("must use saved metadata")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bench_cleanup.main(["--report-only", "--model", "different-model"]), 0)
            report = next(root.glob("*-report.md")).read_text()
            self.assertIn("measured-model, strict mode, 13 dictionary terms", report)
            self.assertNotIn("different-model", report)

    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.env = mock.patch.dict(
            os.environ, {"V2T_HOME": self.tempdir.name}, clear=False
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        # No test may post a real notification (tiny synthetic clips read as
        # near-silent); the tests about notifications patch this again.
        self.real_notify = app._notify
        notify = mock.patch.object(app, "_notify")
        notify.start()
        self.addCleanup(notify.stop)
        # Each engine opens a pill socket; close it with the test. Left to the
        # garbage collector, its ResourceWarning prints into whichever later
        # test is capturing stderr (CI, 2026-10-06: a dictionary-apply test).
        real_init = app.VoiceToText.__init__

        def init(voice, *args, **kwargs):
            real_init(voice, *args, **kwargs)
            self.addCleanup(voice.live_socket.close)

        engines = mock.patch.object(app.VoiceToText, "__init__", init)
        engines.start()
        self.addCleanup(engines.stop)

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
            self.assertEqual(argv, list(sys.orig_argv))
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
        cfg = config.Config(backend="parakeet", cleanup_enabled=False, mode="casual")
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
            "idle\tparakeet-v3\toff\tcasual\t\t\n",
        )

    def test_status_carries_the_last_dictations_microphone_warning(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, mode="casual"))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.warning = (
            "Near-silent audio from LABLABLA: speech-level sound in 0% of 62s"
        )

        voice._set_state("idle")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cli.cmd_status([])

        self.assertEqual(
            output.getvalue().rstrip("\n").split("\t")[-1],
            "Near-silent audio from LABLABLA: speech-level sound in 0% of 62s",
        )

    def test_recording_refreshes_the_device_list_before_opening_the_mic(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        calls = mock.Mock()
        stream = mock.Mock()

        with (
            mock.patch.object(app.sd, "_terminate", calls.terminate),
            mock.patch.object(app.sd, "_initialize", calls.initialize),
            mock.patch.object(app.sd, "InputStream", calls.open, create=True),
        ):
            calls.open.return_value = stream
            voice.start_recording()

        self.assertEqual(
            [name for name, _, _ in calls.mock_calls][:3],
            ["terminate", "initialize", "open"],
        )
        self.assertTrue(voice.recording)
        stream.start.assert_called_once()

    def test_recording_still_initialises_audio_when_release_fails(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)

        with (
            mock.patch.object(app.sd, "_terminate", side_effect=RuntimeError("gone")),
            mock.patch.object(app.sd, "_initialize") as initialize,
            mock.patch.object(app.sd, "InputStream", return_value=mock.Mock()),
        ):
            voice.start_recording()

        initialize.assert_called_once()
        self.assertTrue(voice.recording)

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

        def queue_then_stop():
            voice.processing = True
            voice.stopping = True
            voice.jobs.put(([np.ones((8, 1), dtype=np.float32)], 1.0))

        def finish_job(*_):
            voice.processing = False

        with (
            mock.patch.object(app, "_listener", return_value=Listener()),
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
        self.assertTrue(voice._await_mic_closed(1.0))  # the stop runs on its own thread
        stream.stop.assert_called_once()
        stream.close.assert_called_once()
        self.assertNotIn(
            ["nowplaying-cli", "pause"], [call.args[0] for call in run.call_args_list]
        )

    def _hanging_mic(self, voice, hold_s: float = 3):
        """Open the microphone on a stream whose stop() hangs, like the CoreAudio
        deadlock (PortAudio#1174), until the returned event is set or `hold_s` passes."""
        config.ensure_dirs()
        release = app.threading.Event()
        self.addCleanup(release.set)
        stream = mock.Mock()
        stream.stop.side_effect = lambda: release.wait(hold_s)
        with mock.patch.object(app.sd, "InputStream", return_value=stream):
            voice.start_recording(show=False)
        voice.frames.append(np.ones((1600, 1), dtype=np.float32))
        return stream, release

    def test_a_hanging_mic_stop_never_blocks_the_hotkey_thread(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        stream, _release = self._hanging_mic(voice)

        started = app.time.perf_counter()
        voice.stop_recording()
        took = app.time.perf_counter() - started

        self.assertLess(took, 0.5, "the hotkey callback returned while stop() hangs")
        stream.stop.assert_called_once()
        frames, _duration = voice.jobs.get_nowait()
        self.assertEqual([f.shape for f in frames], [(1600, 1)], "the dictation still goes on")

    def test_a_block_being_appended_when_the_key_is_released_is_kept(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        _stream, _release = self._hanging_mic(voice)
        copying = app.threading.Event()

        class SlowBlock:  # the audio callback is mid-append when the key comes up
            shape = (1600, 1)

            def copy(self):
                copying.set()
                app.time.sleep(0.2)
                return np.full((1600, 1), 0.5, dtype=np.float32)

        callback = app.threading.Thread(
            target=voice.audio_callback, args=(SlowBlock(), 1600, None, None)
        )
        callback.start()
        copying.wait(1)
        voice.stop_recording()
        callback.join()

        self.assertEqual(len(voice.current_audio[0]), 2, "the in-flight block is in")

    def test_a_press_while_the_last_stop_runs_leaves_the_mic_closed(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        _stream, _release = self._hanging_mic(voice)
        voice.cancel_recording()

        with (
            mock.patch.object(app, "MIC_REOPEN_WAIT_S", 0.05),
            mock.patch.object(app.sd, "InputStream") as input_stream,
        ):
            voice.start_recording(show=False)

        input_stream.assert_not_called()
        self.assertFalse(voice.recording)

    def test_a_stop_stuck_past_the_limit_restarts_the_engine_once_idle(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        _stream, _release = self._hanging_mic(voice)
        voice.cancel_recording()
        before = voice._should_restart_for_microphone()  # a slow stop, not yet stuck

        with mock.patch.object(app, "MIC_STUCK_S", 0.0):
            voice.processing = True
            while_busy = voice._should_restart_for_microphone()
            voice.processing = False
            when_idle = voice._should_restart_for_microphone()
            with mock.patch.object(app.os, "execv") as execv:
                voice._restart_for_microphone()

        self.assertEqual((before, while_busy, when_idle), (False, False, True))
        execv.assert_called_once_with(sys.executable, sys.orig_argv)

    def test_a_reload_waits_until_nothing_is_in_hand_then_refuses_new_recordings(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        unrequested = voice._begin_reload()
        voice.request_reload()
        busy = {}
        for name, arrange, undo in (
            ("recording", lambda: setattr(voice, "recording", True), lambda: setattr(voice, "recording", False)),
            ("processing", lambda: setattr(voice, "processing", True), lambda: setattr(voice, "processing", False)),
            ("queued", lambda: voice.jobs.put(("frames", 1.0)), lambda: voice.jobs.get_nowait()),
            ("undo window", lambda: setattr(voice, "cancelled_audio", ("frames", 1.0)), lambda: setattr(voice, "cancelled_audio", None)),
            ("double tap", lambda: setattr(voice, "last_tap_at", app.time.perf_counter()), lambda: setattr(voice, "last_tap_at", 0.0)),
        ):
            arrange()
            busy[name] = voice._begin_reload()
            undo()

        idle = voice._begin_reload()
        with mock.patch.object(app.sd, "InputStream") as input_stream:
            voice.start_recording(show=False)
        with mock.patch.object(app.os, "execv") as execv:
            voice._reload()

        self.assertEqual(
            (unrequested, busy, idle),
            (False, {"recording": False, "processing": False, "queued": False, "undo window": False, "double tap": False}, True),
        )
        input_stream.assert_not_called()
        execv.assert_called_once_with(sys.executable, sys.orig_argv)

    def test_the_run_loop_reloads_on_sighup_and_status_says_it_can(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        deadline = app.time.perf_counter() + 5  # a loop that never reloads fails, not hangs

        class Listener:
            def __init__(self, **_callbacks):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def is_alive(self):
                return app.time.perf_counter() < deadline

        handlers = {}
        reloads = []

        def reload():
            reloads.append(True)
            voice.stopping = True  # what exec would end: leave the loop

        def warmup():
            handlers[signal.SIGHUP](signal.SIGHUP, None)  # the menu app's signal arrives

        with (
            mock.patch.object(app, "_listener", return_value=Listener()),
            mock.patch.object(app, "_resolve_hotkey", return_value=object()),
            mock.patch.object(app.signal, "signal", side_effect=lambda signum, handler: handlers.__setitem__(signum, handler)),
            mock.patch.object(voice, "warmup", side_effect=warmup),
            mock.patch.object(voice, "_reload", side_effect=reload),
            mock.patch.object(app.config, "write_status") as write_status,
            contextlib.suppress(RuntimeError),
        ):
            voice.run()

        self.assertEqual(reloads, [True])
        self.assertTrue(write_status.call_args_list[0].args[0]["reload"])

    def test_a_stop_during_a_reload_shuts_down_instead_of_restarting(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        voice.startup_complete = True  # reloads happen only once the engine is up

        def stop_arrives(_timeout):
            voice._handle_signal(signal.SIGTERM)
            return True

        with (
            mock.patch.object(voice, "_await_mic_closed", side_effect=stop_arrives),
            mock.patch.object(app.os, "execv") as execv,
        ):
            voice._reload()

        execv.assert_not_called()

    def test_sighup_is_handled_before_the_instance_lock_is_taken(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        handlers = {}
        handled_at_lock = []

        def lock():
            handled_at_lock.append(signal.SIGHUP in handlers)
            raise BlockingIOError  # stop run() here, as a second engine would

        with (
            mock.patch.object(app.signal, "signal", side_effect=lambda signum, handler: handlers.__setitem__(signum, handler)),
            mock.patch.object(app.config, "acquire_instance_lock", side_effect=lock),
            self.assertRaises(SystemExit),
        ):
            voice.run()

        self.assertEqual(handled_at_lock, [True])

    def test_an_engine_launched_with_overriding_flags_does_not_offer_reload(self):
        reloadable = {}

        class Voice:
            def __init__(self, cfg):
                self.reloadable = True

            def run(self):
                reloadable[tuple(argv)] = self.reloadable

        for argv in ([], ["--config", str(Path(self.tempdir.name) / "other.toml")], ["--strict"]):
            with (
                mock.patch.dict(os.environ, {"V2T_LAUNCH_CONTEXT": "menubar"}),
                mock.patch.object(app, "VoiceToText", Voice),
            ):
                cli.cmd_run(list(argv))

        self.assertEqual(reloadable, {
            (): True,
            ("--config", str(Path(self.tempdir.name) / "other.toml")): True,  # the menu compares paths
            ("--strict",): False,
        })

    def test_the_run_loop_restarts_the_engine_when_the_mic_is_stuck(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        deadline = app.time.perf_counter() + 5  # a loop that never restarts fails, not hangs

        class Listener:
            def __init__(self, **_callbacks):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def is_alive(self):
                return app.time.perf_counter() < deadline

        restarts = []

        def restart():
            restarts.append(True)
            voice.stopping = True  # what exec would end: leave the loop

        def stuck_mic():
            self._hanging_mic(voice, hold_s=30)  # still stuck when shutdown checks
            voice.cancel_recording()

        with (
            mock.patch.object(app, "MIC_STUCK_S", 0.0),
            mock.patch.object(app, "_listener", return_value=Listener()),
            mock.patch.object(app, "_resolve_hotkey", return_value=object()),
            mock.patch.object(app.signal, "signal"),
            mock.patch.object(voice, "warmup", side_effect=stuck_mic),
            mock.patch.object(voice, "_restart_for_microphone", side_effect=restart),
            mock.patch.object(app.os, "_exit") as hard_exit,
            contextlib.suppress(RuntimeError),  # the listener "died" at the deadline
        ):
            voice.run()

        self.assertEqual(restarts, [True])
        hard_exit.assert_called_once_with(0)  # shutdown skips PortAudio's exit hook

    def test_shutdown_with_a_healthy_mic_exits_normally(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        config.ensure_dirs()
        stream = voice.stream = mock.Mock()

        with mock.patch.object(app.os, "_exit") as hard_exit:
            voice.shutdown()

        hard_exit.assert_not_called()
        stream.close.assert_called_once()  # shutdown waited for the stop to finish

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

    def test_whole_file_decoding_hands_parakeet_the_array_without_a_wav(self):
        voice = app.VoiceToText(config.Config(save_history=False))
        decoded = []
        voice.stt = types.SimpleNamespace(
            sample_rate=16000,
            decode=lambda audio: decoded.append(audio) or "raw words",
            transcribe=mock.Mock(side_effect=AssertionError("no WAV round trip")),
        )
        audio = np.ones((8, 1), dtype=np.float32)

        text = voice._transcribe_whole(audio)

        self.assertEqual(text, "raw words")
        self.assertEqual(len(decoded), 1)
        self.assertIs(decoded[0], audio)

    def test_whole_file_decoding_writes_a_wav_when_the_rates_differ(self):
        voice = app.VoiceToText(config.Config(save_history=False, sample_rate=48000))
        seen = []

        def transcribe(path):
            seen.append(wavfile.read(path)[0])
            return "raw words"

        voice.stt = types.SimpleNamespace(
            sample_rate=16000,
            decode=mock.Mock(side_effect=AssertionError("audio is not at 16 kHz")),
            transcribe=transcribe,
        )

        text = voice._transcribe_whole(np.ones((8, 1), dtype=np.float32))

        self.assertEqual((text, seen), ("raw words", [48000]))

    def test_parakeet_loads_its_model_quantized(self):
        loaded = mock.Mock(name="bf16")
        fake = types.SimpleNamespace(from_pretrained=mock.Mock(return_value=loaded))

        with (
            mock.patch.dict(sys.modules, {"parakeet_mlx": fake}),
            mock.patch.object(backends, "cached_locally", return_value=False),
            mock.patch.object(backends, "_quantized", return_value="q8") as quantize,
        ):
            stt = backends.ParakeetSTT("org/parakeet")

        fake.from_pretrained.assert_called_once_with("org/parakeet")
        quantize.assert_called_once_with(loaded)
        self.assertEqual(stt.model, "q8")

    def test_parakeet_quantizes_linear_layers_that_fit_the_group_outside_attention(self):
        class Linear:
            def __init__(self, inputs):
                self.weight = np.zeros((4, inputs))

        fake_nn = types.SimpleNamespace(Linear=Linear, quantize=mock.Mock())
        fake_mx = types.SimpleNamespace(eval=mock.Mock())
        model = mock.Mock()
        mlx = types.SimpleNamespace(core=fake_mx, nn=fake_nn)

        with mock.patch.dict(
            sys.modules, {"mlx": mlx, "mlx.core": fake_mx, "mlx.nn": fake_nn}
        ):
            self.assertIs(backends._quantized(model), model)

        kwargs = fake_nn.quantize.call_args.kwargs
        picks = kwargs.pop("class_predicate")
        self.assertEqual(
            (fake_nn.quantize.call_args.args, kwargs),
            ((model,), {"group_size": 64, "bits": backends.PARAKEET_BITS}),
        )
        self.assertEqual(
            [
                picks(path, m)
                for path, m in (
                    ("encoder.layers.0.feed_forward1.linear1", Linear(1024)),
                    ("joint.joint_net.2", Linear(80)),
                    ("encoder.layers.0.self_attn.linear_q", Linear(1024)),
                    ("encoder.layers.0.conv", object()),
                )
            ],
            [True, False, False, False],
        )
        fake_mx.eval.assert_called_once_with(model.parameters())

    def test_the_pill_hears_delivering_just_before_the_paste(self):
        voice = app.VoiceToText(config.Config(save_history=False))
        voice.stt = mock.Mock(transcribe=lambda path: "raw words")
        voice.cleaner = mock.Mock(model_id="cleaner")
        voice.cleaner.cleanup.return_value = ("Clean words.", 0.1, 0.2)
        voice.processing = True
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        sent = []

        with (
            mock.patch.object(
                voice, "_send_live", side_effect=lambda event: sent.append(event["state"])
            ),
            mock.patch.object(
                voice, "paste_to_cursor", side_effect=lambda _text: sent.append("paste")
            ),
        ):
            voice.process_audio([np.ones((8, 1), dtype=np.float32)], 1.0)

        self.assertEqual(
            sent, ["transcribing", "cleaning", "delivering", "paste", "idle"]
        )

    def _process_ones(self, cfg: config.Config, samples: int) -> None:
        voice = app.VoiceToText(cfg)
        voice.stt = mock.Mock(transcribe=lambda path: "raw words")
        voice.processing = True
        with mock.patch.object(voice, "paste_to_cursor"):
            voice.process_audio([np.ones((samples, 1), dtype=np.float32)], 1.0)

    def test_the_last_recording_is_kept_as_a_private_wav(self):
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        self._process_ones(config.Config(cleanup_enabled=False), 8)
        self._process_ones(config.Config(cleanup_enabled=False), 24)  # replaces it

        kept = config.last_audio_path()
        rate, pcm = wavfile.read(kept)
        self.assertEqual(
            (rate, pcm.shape, pcm.dtype), (16000, (24,), np.dtype("int16"))
        )
        self.assertEqual(kept.stat().st_mode & 0o777, 0o600)
        self.assertFalse(kept.with_suffix(".wav.tmp").exists())

    def test_keep_last_audio_off_writes_no_wav_and_removes_an_old_one(self):
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        config.ensure_dirs()
        config.last_audio_path().write_bytes(b"stale")
        self._process_ones(
            config.Config(cleanup_enabled=False, keep_last_audio=False), 8
        )
        self.assertFalse(config.last_audio_path().exists())
        self.assertEqual(config.read_status()["state"], "idle")

    def test_chunk_feeder_sends_whole_chunks_and_flushes_the_rest(self):
        sent = []
        feeder = backends.ChunkFeeder(
            lambda chunk: sent.append(chunk), sample_rate=100, chunk_s=0.5
        )

        first = feeder.push(np.ones((30, 1), dtype=np.float32))
        second = feeder.push(np.full(30, 2.0, dtype=np.float32))
        third = feeder.push(np.zeros(10, dtype=np.float32))
        flushed = feeder.flush()
        again = feeder.flush()

        self.assertEqual(
            (first, second, third, flushed, again), (False, True, False, True, False)
        )
        feeder.push(np.ones(7, dtype=np.float32))
        remainder = feeder.take()
        self.assertEqual((remainder.shape, feeder.take().shape), ((7,), (0,)))
        self.assertEqual(
            len(sent), 2, "take() hands the remainder back, never sends it"
        )
        self.assertEqual([chunk.shape for chunk in sent], [(60,), (10,)])
        self.assertEqual(sent[0].tolist(), [1.0] * 30 + [2.0] * 30)
        self.assertEqual((feeder.sent_samples, feeder.chunks), (70, 2))

    def test_parakeet_stream_pads_a_push_shorter_than_one_hop(self):
        pushed: list[int] = []
        stream = mock.MagicMock()
        stream.add_audio.side_effect = lambda audio: pushed.append(len(audio))
        stream.result.text = " heard "
        model = mock.Mock()
        model.preprocessor_config.hop_length = 160
        model.encoder_config.subsampling_factor = 8
        model.transcribe_stream.return_value = stream
        fake_mx = types.SimpleNamespace(array=np.asarray)

        with mock.patch.dict(
            sys.modules, {"mlx": mock.Mock(core=fake_mx), "mlx.core": fake_mx}
        ):
            live = backends.ParakeetStream(model)
        text = live.feed(np.ones(100, dtype=np.float32))
        live.feed(np.ones(300, dtype=np.float32))
        final = live.finish(np.ones(50, dtype=np.float32))
        live.close()

        self.assertEqual(
            pushed,
            [160, 300, 50 + 1280],
            "sub-hop push padded to one hop; finish adds one subsampling block of silence",
        )
        self.assertEqual((text, final), ("heard", "heard"))
        stream.__enter__.assert_called_once()
        stream.__exit__.assert_called_once()

    def test_parakeet_preview_decodes_the_tail_alone_and_leaves_the_stream(self):
        stream = mock.MagicMock()
        model = mock.Mock()
        model.preprocessor_config.hop_length = 160
        model.encoder_config.subsampling_factor = 8
        model.transcribe_stream.return_value = stream
        model.generate.return_value = [mock.Mock(text=" tail words ")]
        fake_mx = types.SimpleNamespace(array=np.asarray)
        audio_module = types.SimpleNamespace(
            get_logmel=mock.Mock(side_effect=lambda pcm, cfg: ("mel", pcm.size))
        )

        with mock.patch.dict(
            sys.modules,
            {
                "mlx": mock.Mock(core=fake_mx),
                "mlx.core": fake_mx,
                "parakeet_mlx": mock.Mock(audio=audio_module),
                "parakeet_mlx.audio": audio_module,
            },
        ):
            live = backends.ParakeetStream(model)
            text = live.preview(np.ones(16000, dtype=np.float32))
            short = live.preview(np.ones(100, dtype=np.float32))

        self.assertEqual((text, short), ("tail words", ""))
        model.generate.assert_called_once_with(("mel", 16000))
        stream.add_audio.assert_not_called()
        self.assertEqual(live.text, "", "the streamed text is not the preview's")

    def test_parakeet_decode_runs_the_model_frees_its_buffers_and_skips_a_sub_hop_piece(self):
        model = mock.Mock()
        model.preprocessor_config.hop_length = 160
        model.generate.return_value = [mock.Mock(text=" piece words ")]
        fake_mx = types.SimpleNamespace(array=np.asarray, clear_cache=mock.Mock())
        audio_module = types.SimpleNamespace(
            get_logmel=mock.Mock(side_effect=lambda pcm, cfg: ("mel", pcm.size))
        )
        stt = object.__new__(backends.ParakeetSTT)  # no model download
        stt.model = model

        with mock.patch.dict(
            sys.modules,
            {
                "mlx": mock.Mock(core=fake_mx),
                "mlx.core": fake_mx,
                "parakeet_mlx": mock.Mock(audio=audio_module),
                "parakeet_mlx.audio": audio_module,
            },
        ):
            text = stt.decode(np.ones((16000, 1), dtype=np.float32))
            short = stt.decode(np.ones(100, dtype=np.float32))

        self.assertEqual((text, short), ("piece words", ""))
        model.generate.assert_called_once_with(("mel", 16000))
        model.transcribe_stream.assert_not_called()
        fake_mx.clear_cache.assert_called_once()  # after the decode: freed buffers go back

    @staticmethod
    def _speech_with_pauses(seconds: float, pauses_at: tuple[float, ...]) -> np.ndarray:
        """Steady 'speech' with one 100 ms silence starting at each of `pauses_at`."""
        audio = np.full(int(16000 * seconds), 0.5, dtype=np.float32)
        for at in pauses_at:
            audio[int(16000 * at) : int(16000 * at) + 1600] = 0.0
        return audio

    def test_pieces_are_cut_at_the_pause_nearest_each_mark_once_the_cut_is_known(self):
        audio = self._speech_with_pauses(70, (27.0, 58.0))
        decoded: list[int] = []
        pieces = backends.PieceDecoder(
            lambda piece: decoded.append(piece.size) or f"p{len(decoded)}", 16000
        )
        stepped_at: list[int] = []

        for second in range(70):
            pieces.add(audio[second * 16000 : (second + 1) * 16000])
            if pieces.step():
                stepped_at.append(second + 1)
        text = pieces.finish()

        # cut 1: the pause in 25-35 s, at 27.05 s, known at 35 s; cut 2: the pause
        # within 5 s of 27.05 + 30 s, at 58.05 s, known at 62.05 s; the rest on finish
        self.assertEqual(stepped_at, [35, 63])
        self.assertEqual(decoded, [432800, 496000, 1120000 - 928800])
        self.assertEqual(text, "p1 p2 p3")
        self.assertEqual(
            (pieces.pieces, pieces.decoded_samples, pieces.pending_samples),
            (3, 1120000, 0),
        )

    def test_a_piece_with_no_words_leaves_no_gap_in_the_text(self):
        replies = iter(["first", "  ", "third"])
        pieces = backends.PieceDecoder(lambda piece: next(replies), 16000)
        pieces.add(self._speech_with_pauses(70, (27.0, 58.0)))

        self.assertEqual(pieces.finish(), "first third")
        self.assertEqual(pieces.pieces, 3)

    @staticmethod
    def _coreml_with_window(window) -> coreml.CoreMLParakeet:
        """A CoreMLParakeet whose one-window decode is `window`; no model files."""
        model = object.__new__(coreml.CoreMLParakeet)
        model.window = window
        return model

    def test_coreml_cuts_long_audio_at_the_pause_nearest_each_12_s_mark(self):
        audio = self._speech_with_pauses(40, (10.0, 21.0, 31.5))
        sizes: list[int] = []
        model = self._coreml_with_window(
            lambda piece: sizes.append(piece.size) or f"w{len(sizes)}"
        )

        text = model.decode(audio)

        # each cut: the middle of the silent 0.1 s within 9-15 s of the last cut
        self.assertEqual(sizes, [160800, 176000, 168000, 135200])
        self.assertEqual(text, "w1 w2 w3 w4")

    def test_coreml_never_hands_a_window_more_than_15_s(self):
        noise = np.random.default_rng(0).uniform(-1, 1, 16000 * 100).astype(np.float32)
        for samples in (coreml.WINDOW, coreml.WINDOW + 1, noise.size):
            sizes: list[int] = []
            model = self._coreml_with_window(lambda piece: sizes.append(piece.size) or "")

            model.decode(noise[:samples])

            self.assertLessEqual(max(sizes), coreml.WINDOW, samples)
            self.assertEqual(sum(sizes), samples)

    def test_coreml_decodes_audio_under_one_window_in_one_piece(self):
        sizes: list[int] = []
        model = self._coreml_with_window(lambda piece: sizes.append(piece.size) or "hi")

        text = model.decode(np.full((16000 * 14, 1), 0.5, dtype=np.float32))

        self.assertEqual((text, sizes), ("hi", [16000 * 14]))

    @staticmethod
    def _tdt_fakes(script: list[tuple[int, int]]):
        """A joint replying from `script` in order and a prediction network whose
        output and state name the token and step; both record their calls."""
        replies = iter(script)
        joint_calls: list[tuple[int, str]] = []
        predict_calls: list[tuple[int, str]] = []

        def joint(t, out):
            joint_calls.append((t, out))
            return next(replies)

        def predict(token, state):
            predict_calls.append((token, state))
            return f"out:{token}", f"s{len(predict_calls)}"

        return joint, predict, joint_calls, predict_calls

    def test_tdt_greedy_follows_durations_and_steps_past_a_zero_length_blank(self):
        blank = coreml.BLANK
        joint, predict, joint_calls, predict_calls = self._tdt_fakes(
            [(5, 0), (6, 2), (blank, 0), (7, 1)]
        )

        tokens = coreml.tdt_greedy(4, joint, predict, "s0")

        self.assertEqual(tokens, [5, 6, 7])
        # 5 with duration 0 stays on frame 0; 6 jumps two frames; the blank's 0 is one
        self.assertEqual(
            joint_calls,
            [(0, f"out:{blank}"), (0, "out:5"), (2, "out:6"), (3, "out:6")],
        )
        # the blank starts the network off and is never fed back
        self.assertEqual(
            predict_calls, [(blank, "s0"), (5, "s1"), (6, "s2"), (7, "s3")]
        )

    def test_tdt_greedy_moves_on_after_max_symbols_tokens_on_one_frame(self):
        joint, predict, joint_calls, _ = self._tdt_fakes([(9, 0)] * 6 + [(1, 0)] * 20)

        tokens = coreml.tdt_greedy(2, joint, predict, None, max_symbols=3)

        self.assertEqual(tokens, [9] * 6)
        self.assertEqual([t for t, _ in joint_calls], [0, 0, 0, 1, 1, 1])

    def test_detokenize_joins_word_pieces_and_drops_unknown_ids(self):
        vocab = {1: "\u2581hel", 2: "lo", 3: "\u2581world"}

        self.assertEqual(coreml.detokenize([1, 2, 99, 3], vocab), "hello world")

    def test_coreml_window_feeds_each_model_its_inputs_and_threads_the_decoder_state(self):
        blank = coreml.BLANK
        seen: dict[str, list] = {"pre": [], "enc": [], "dec": [], "joint": []}

        def fake(name, reply):
            def predict(inputs):
                seen[name].append(inputs)
                return reply(inputs)

            return types.SimpleNamespace(predict=predict)

        frames = np.arange(4, dtype=np.float32).reshape(1, 1, 4)  # frame t holds t
        script = {0: (10, 1), 1: (blank, 1), 2: (11, 2)}  # frame 3 is skipped
        model = object.__new__(coreml.CoreMLParakeet)
        model.pre = fake("pre", lambda i: {"mel": "MEL", "mel_length": np.array([7])})
        model.enc = fake(
            "enc", lambda i: {"encoder": frames, "encoder_length": np.array([4])}
        )
        model.dec = fake(
            "dec",
            lambda i: {
                "decoder": i["targets"],
                "h_out": i["h_in"] + 1,
                "c_out": i["c_in"] + 2,
            },
        )
        model.joint = fake(
            "joint", lambda i: dict(zip(("token_id", "duration"), map(
                np.array, script[int(i["encoder_step"].item())]
            )))
        )
        model.vocab = {10: "\u2581hello", 11: "\u2581world"}
        pcm = np.full(16000, 0.25, dtype=np.float32)

        text = model.window(pcm)

        self.assertEqual(text, "hello world")
        (pre,) = seen["pre"]
        self.assertEqual(pre["audio_signal"].shape, (1, coreml.WINDOW))
        self.assertEqual(float(pre["audio_signal"][0, :16000].min()), 0.25)
        self.assertEqual(float(np.abs(pre["audio_signal"][0, 16000:]).max()), 0.0)
        self.assertEqual(pre["audio_length"].tolist(), [16000])
        (enc,) = seen["enc"]
        self.assertEqual((enc["mel"], enc["mel_length"].dtype), ("MEL", np.int32))
        self.assertEqual(
            [(int(d["targets"].item()), float(d["h_in"].max()), float(d["c_in"].max()))
             for d in seen["dec"]],
            [(blank, 0.0, 0.0), (10, 1.0, 2.0), (11, 2.0, 4.0)],
        )
        self.assertEqual(seen["dec"][0]["h_in"].shape, coreml.DECODER_STATE)
        self.assertEqual(
            [(int(j["encoder_step"].item()), int(j["decoder_step"].item()))
             for j in seen["joint"]],
            [(0, blank), (1, 10), (2, 10)],
        )

    def test_coreml_without_its_model_files_names_the_missing_ones(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in coreml.FILES[:3]:
                (folder / name).mkdir()

            with self.assertRaises(SystemExit) as caught:
                coreml.CoreMLParakeet(folder)

        message = str(caught.exception)
        self.assertIn("missing: JointDecisionv3.mlmodelc, parakeet_v3_vocab.json", message)
        self.assertIn("FluidInference/parakeet-tdt-0.6b-v3-coreml", message)

    def test_coreml_without_coremltools_says_to_reinstall(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in coreml.FILES:
                (folder / name).touch()

            with (
                mock.patch.dict(sys.modules, {"coremltools": None}),
                self.assertRaises(SystemExit) as caught,
            ):
                coreml.CoreMLParakeet(folder)

        self.assertIn("reinstall voice2text", str(caught.exception))

    def test_parakeet_coreml_decodes_and_cuts_held_pieces_on_core_ml_without_mlx(self):
        decoded: list[np.ndarray] = []
        windows: list[int] = []
        core_ml = mock.Mock(
            decode=lambda pcm: decoded.append(pcm) or "core ml words",
            window=lambda pcm: windows.append(pcm.size) or "w",
        )

        with (
            mock.patch.object(coreml, "CoreMLParakeet", return_value=core_ml) as load,
            mock.patch.object(coreml, "model_folder", return_value=Path("/models")) as folder,
            mock.patch.dict(sys.modules, {"parakeet_mlx": None, "mlx": None}),
        ):
            stt = backends.make_stt("parakeet-coreml")
            text = stt.decode(np.ones((16000, 1), dtype=np.float64))
            pieces = stt.pieces()
            pieces.add(np.ones(16000 * 20, dtype=np.float32))
            stepped = pieces.step()

        folder.assert_called_once_with(None)
        load.assert_called_once_with(Path("/models"))
        self.assertEqual(text, "core ml words")
        self.assertEqual([(a.shape, a.dtype) for a in decoded], [((16000,), np.float32)])
        # one window cut within 3 s of the 12 s mark, known once 15 s are in
        self.assertEqual((stepped, windows), (True, [16000 * 9 + 800]))
        self.assertEqual(
            (stt.streaming, stt.pieces_only, stt.sample_rate), (True, True, 16000)
        )
        self.assertFalse(hasattr(stt, "stream"))

    def test_coreml_model_folder_prefers_fluidaudio_then_downloads_only_its_files(self):
        with tempfile.TemporaryDirectory() as directory:
            fluid = Path(directory) / "fluid"
            fluid.mkdir()
            snapshot = Path(directory) / "snapshot"
            snapshot.mkdir()
            for name in coreml.FILES:
                (snapshot / name).touch()
            download = mock.Mock(return_value=str(snapshot))
            hub = mock.Mock(snapshot_download=download)
            with (
                mock.patch.object(coreml, "COREML_DIR", fluid),
                mock.patch.dict(sys.modules, {"huggingface_hub": hub}),
                mock.patch.object(backends, "load_cache_first", lambda repo, fetch: fetch()),
            ):
                configured = coreml.model_folder(Path("/mine"))
                fetched = coreml.model_folder()
                for name in coreml.FILES:
                    (fluid / name).touch()
                fluid_folder = coreml.model_folder()

        self.assertEqual(configured, Path("/mine"))
        self.assertEqual(fetched, Path(directory) / "snapshot")
        self.assertEqual(fluid_folder, fluid)
        download.assert_called_once()
        repo, patterns = download.call_args.args[0], download.call_args.kwargs["allow_patterns"]
        self.assertEqual(repo, coreml.COREML_REPO)
        self.assertEqual(len(patterns), len(coreml.FILES))
        self.assertTrue(all(p.endswith("/*") for p in patterns if ".mlmodelc" in p))

    def test_coreml_model_folder_retries_online_after_a_partial_download(self):
        with tempfile.TemporaryDirectory() as directory:
            partial, whole = Path(directory) / "partial", Path(directory) / "whole"
            for folder in (partial, whole):
                folder.mkdir()
            for name in coreml.FILES:
                (whole / name).touch()
            (partial / coreml.FILES[0]).touch()
            hub = mock.Mock(snapshot_download=mock.Mock(side_effect=[str(partial), str(whole)]))

            def cache_first(repo, fetch):  # load_cache_first: offline, then online on OSError
                try:
                    return fetch()
                except OSError:
                    return fetch()

            with (
                mock.patch.object(coreml, "COREML_DIR", Path(directory) / "none"),
                mock.patch.dict(sys.modules, {"huggingface_hub": hub}),
                mock.patch.object(backends, "load_cache_first", cache_first),
            ):
                self.assertEqual(coreml.model_folder(), whole)

    def test_parakeet_coreml_reads_its_files_from_a_configured_folder(self):
        with mock.patch.object(coreml, "CoreMLParakeet") as load:
            backends.ParakeetCoreMLSTT("~/models/parakeet-coreml")

        load.assert_called_once_with(Path.home() / "models/parakeet-coreml")

    def test_config_accepts_the_parakeet_coreml_backend(self):
        config._validate(config.Config(backend="parakeet-coreml"))  # no SystemExit

    def _streaming_stt(
        self, feeds: list, partial: str = "so far", final: str = "final words"
    ):
        """An STT with Parakeet's streaming surface: stream() -> feed()/text/close(),
        and decode(audio), which long recordings use piece by piece; it returns
        `final`, and the sizes it was given are on `stt.decoded`."""
        stream = mock.Mock()
        stream.text = ""

        def feed(chunk):
            feeds.append(chunk.size)
            stream.text = partial
            return partial

        def close():
            stream.closed = True
            return final

        def finish(audio=None):
            if audio is not None and np.asarray(audio).size:
                stream.feed(np.asarray(audio))  # via the mock, so overrides apply
            return stream.close()

        stream.feed.side_effect = feed
        stream.close.side_effect = close
        stream.finish.side_effect = finish
        stream.preview.return_value = ""
        stream.closed = False
        stt = mock.Mock(
            streaming=True, sample_rate=16000, stream=mock.Mock(return_value=stream)
        )
        stt.decoded = []
        stt.decode.side_effect = lambda audio: stt.decoded.append(audio.size) or final
        return stt, stream

    def test_streaming_feeds_the_recording_while_held_and_a_long_one_ends_in_pieces(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        chunk = int(16000 * backends.STREAM_CHUNK_S)

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        self.assertTrue(voice.can_stream())
        self.assertIsNotNone(voice.live)
        worker = app.threading.Thread(target=voice.process_next)
        worker.start()
        self.addCleanup(worker.join)
        try:
            voice.audio_callback(
                np.full((chunk, 1), 0.5, dtype=np.float32), chunk, None, None
            )
            for _ in range(50):
                partial_status = config.read_status() or {}
                if "words" in partial_status:  # written after the first feed
                    break
                app.time.sleep(0.05)
            voice.audio_callback(
                np.full((8000, 1), 0.5, dtype=np.float32), 8000, None, None
            )
            voice.record_start -= backends.STREAM_TAKEOVER_S  # a long dictation
            with mock.patch.object(voice, "paste_to_cursor") as paste:
                voice.stop_recording()
                worker.join(timeout=5)
        finally:
            voice.live = None

        self.assertFalse(worker.is_alive(), "processing thread finished after release")
        self.assertEqual(feeds, [chunk], "one chunk while held, no flush on release")
        stream.finish.assert_not_called()
        self.assertEqual(
            voice.stt.decoded, [chunk + 8000], "under one piece: one decode of it all"
        )
        self.assertEqual(
            {k: partial_status[k] for k in ("state", "words", "partial")},
            {"state": "recording", "words": 2, "partial": "so far"},
        )
        self.assertTrue(stream.closed)
        paste.assert_called_once_with("final words")
        self.assertFalse(voice.processing)
        self.assertEqual(config.read_status()["state"], "idle")
        record = config.read_history()[-1]
        self.assertEqual((record["raw"], record["streamed"]), ("final words", True))
        self.assertLess(record["stt_s"], 1.0)
        self.assertEqual(
            wavfile.read(config.last_audio_path())[1].shape, (chunk + 8000,)
        )  # the streamed recording's audio is kept too

    def _hold_and_feed(self, voice, seconds_after_chunk: list[float]):
        """Start a held recording on a worker thread, feed one stream chunk, then
        each extra stretch of audio, waiting for the worker to drain each."""
        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        worker = app.threading.Thread(target=voice.process_next)
        worker.start()
        self.addCleanup(worker.join)
        chunk = int(16000 * backends.STREAM_CHUNK_S)
        statuses = []
        for samples in [chunk] + [int(16000 * s) for s in seconds_after_chunk]:
            voice.audio_callback(
                np.full((samples, 1), 0.5, dtype=np.float32), samples, None, None
            )
            for _ in range(50):
                if voice.live.fed == len(voice.live.frames):
                    break
                app.time.sleep(0.02)
            app.time.sleep(0.25)  # one more pass of the worker's 0.1 s loop
            statuses.append(config.read_status().get("partial"))
        voice.record_start -= backends.STREAM_TAKEOVER_S
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()
            worker.join(timeout=5)
        voice.live = None
        self.assertFalse(worker.is_alive())
        return statuses, paste

    def test_a_preview_shows_the_unpushed_audio_every_second_between_pushes(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, live_transcript=True))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        previews: list[int] = []
        stream.preview.side_effect = lambda audio: previews.append(audio.size) or "tail"

        statuses, paste = self._hold_and_feed(voice, [1.0, 0.5, 0.5])

        self.assertEqual(
            previews, [16000, 32000], "after 1 s unpushed, then 1 s more, never sooner"
        )
        self.assertEqual(statuses, ["so far", "so far tail", "so far tail", "so far tail"])
        chunk = int(16000 * backends.STREAM_CHUNK_S)
        self.assertEqual(feeds, [chunk], "previews never reach the stream")
        paste.assert_called_once_with("final words")

    def test_no_preview_runs_while_the_live_transcript_is_off(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, stream = self._streaming_stt([])

        statuses, paste = self._hold_and_feed(voice, [1.0, 1.0])

        stream.preview.assert_not_called()
        self.assertEqual(statuses, ["so far", "so far", "so far"])
        paste.assert_called_once_with("final words")

    def test_live_transcript_is_read_from_config_and_validated(self):
        self.assertFalse(config.Config().live_transcript)
        config.write_config("[transcription]\nlive_transcript = true\n")
        self.assertTrue(config.load().live_transcript)
        config.write_config('[transcription]\nlive_transcript = "yes"\n')
        with self.assertRaises(SystemExit):
            config.load()

    def test_a_failing_preview_stops_previews_but_not_the_recording(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, live_transcript=True))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        stream.preview.side_effect = RuntimeError("metal out of memory")

        lines: list[str] = []
        sink = app.logger.add(lambda m: lines.append(str(m)), format="{message}")
        self.addCleanup(app.logger.remove, sink)

        statuses, paste = self._hold_and_feed(voice, [1.0, 1.0])

        self.assertEqual(stream.preview.call_count, 1, "off for the rest of the recording")
        self.assertIn(
            "Live preview off for this recording: metal out of memory\n", lines
        )
        self.assertEqual(statuses, ["so far", "so far", "so far"])
        paste.assert_called_once_with("final words")
        self.assertEqual(config.read_history()[-1]["streamed"], True)

    # 70 s with pauses at 27 s and 58 s: pieces end at 27.05 s and 58.05 s
    _PIECE_SIZES = (432800, 496000, 1120000 - 928800)

    def _hold_long(self, voice, expect: list[str | None]):
        """Hold a 70 s recording, fed as 0-5 s, 5-60 s and 60-70 s; after each slice
        wait for the worker to drain it and, where `expect` names one, for that
        partial. Returns the partial seen after each slice, the paste mock and
        the log lines."""
        lines: list[str] = []
        sink = app.logger.add(lambda m: lines.append(str(m)), format="{message}")
        self.addCleanup(app.logger.remove, sink)
        audio = self._speech_with_pauses(70, (27.0, 58.0))
        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        worker = app.threading.Thread(target=voice.process_next)
        worker.start()
        self.addCleanup(worker.join)
        statuses = []
        for (lo, hi), wanted in zip(((0, 5), (5, 60), (60, 70)), expect):
            frame = audio[lo * 16000 : hi * 16000].reshape(-1, 1)
            voice.audio_callback(frame, len(frame), None, None)
            for _ in range(100):
                partial = config.read_status().get("partial")
                drained = voice.live.fed == len(voice.live.frames)
                if drained and (wanted is None or partial == wanted):
                    break
                app.time.sleep(0.02)
            app.time.sleep(0.25)  # one more pass of the worker's 0.1 s loop
            statuses.append(config.read_status().get("partial"))
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()  # a moment of wall clock: the audio decides
            worker.join(timeout=5)
        voice.live = None
        self.assertFalse(worker.is_alive())
        return statuses, paste, lines

    def test_past_the_takeover_the_stream_closes_and_pieces_decode_while_held(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        order: list = []
        stream.close.side_effect = lambda: order.append("close") or "streamed"
        self._pieces_or_tail(voice, lambda audio: "tail", pieces=order)

        statuses, paste, lines = self._hold_long(voice, [None, None, None])

        self.assertEqual(feeds, [80000, 880000], "the stream stops at the takeover")
        self.assertEqual(order, ["close", *self._PIECE_SIZES], "closed, then each piece once")
        self.assertTrue(statuses[1].startswith("piece"), "partial from the pieces")
        self.assertTrue(
            any(line.startswith("Heard so far") and "70s" in line for line in lines),
            "with the live transcript off, a preview of the tail is logged as heard",
        )
        self.assertIn(
            "Past the takeover: decoding the rest in pieces\n", lines
        )
        self.assertTrue(
            any("after release, 3 pieces, 2 decoded while recording)" in line for line in lines)
        )
        paste.assert_called_once_with("piece piece piece")
        record = config.read_history()[-1]
        self.assertEqual((record["raw"], record["streamed"]), ("piece piece piece", True))

    def _pieces_only_stt(self, voice, decoded: list):
        """A Core ML-shaped STT: no stream(), pieces() of the default 30 s rule
        (its pieces answer 'p' and land on `decoded`), and decode() for previews."""
        stt = mock.Mock(
            spec=["streaming", "pieces_only", "sample_rate", "pieces", "decode"],
            streaming=True, pieces_only=True, sample_rate=16000,
        )
        stt.pieces.side_effect = lambda: backends.PieceDecoder(
            lambda piece: decoded.append(piece.size) or "p", 16000
        )
        stt.decode.return_value = "tail"
        voice.stt = stt
        return stt

    def test_a_pieces_only_backend_decodes_in_pieces_from_the_start_with_no_stream(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        decoded: list[int] = []
        self._pieces_only_stt(voice, decoded)

        statuses, paste, lines = self._hold_long(voice, [None, None, None])

        self.assertEqual(decoded, list(self._PIECE_SIZES), "each piece once, the last on release")
        self.assertEqual(statuses[1], "p tail", "the pieces so far plus a preview of the rest")
        self.assertTrue(
            any("after release, 3 pieces, 2 decoded while recording)" in line for line in lines)
        )
        self.assertNotIn("Past the takeover: decoding the rest in pieces\n", lines)
        paste.assert_called_once_with("p p p")
        record = config.read_history()[-1]
        self.assertEqual((record["raw"], record["streamed"]), ("p p p", True))

    def test_a_short_pieces_only_recording_is_one_decode_on_release(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        decoded: list[int] = []
        stt = self._pieces_only_stt(voice, decoded)
        lines: list[str] = []
        sink = app.logger.add(lambda m: lines.append(str(m)), format="{message}")
        self.addCleanup(app.logger.remove, sink)

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        worker = app.threading.Thread(target=voice.process_next)
        worker.start()
        self.addCleanup(worker.join)
        audio = np.full((16000 * 3, 1), 0.5, dtype=np.float32)
        voice.audio_callback(audio, len(audio), None, None)
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()
            worker.join(timeout=5)
        voice.live = None

        self.assertEqual(decoded, [16000 * 3])
        stt.decode.assert_not_called()  # no preview: under one push's worth of audio
        self.assertTrue(any("whole-file: one window)" in line for line in lines))
        paste.assert_called_once_with("p")
        self.assertFalse(config.read_history()[-1]["streamed"])

    def _pieces_or_tail(self, voice, tail, pieces: list | None = None):
        """decode() answers 'piece' for a piece (its size goes on `pieces`) and
        calls `tail` for a preview. The last preview while held sees exactly the
        audio the last piece will, so that size is a piece only after release."""
        first, second, last = self._PIECE_SIZES
        held = {}  # the recording, kept: release detaches it from voice.live

        def decode(audio):
            live = held.setdefault("live", voice.live)  # first decode: still held
            if audio.size in (first, second) or (
                audio.size == last and live.done.is_set()
            ):
                if pieces is not None:
                    pieces.append(audio.size)
                return "piece"
            return tail(audio)

        voice.stt.decode.side_effect = decode

    def test_past_the_takeover_the_live_transcript_previews_the_audio_after_the_pieces(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, live_transcript=True))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, _stream = self._streaming_stt([])
        self._pieces_or_tail(voice, lambda audio: "tail")

        statuses, paste, lines = self._hold_long(
            voice, [None, "piece tail", "piece piece tail"]
        )

        self.assertEqual(statuses[1:], ["piece tail", "piece piece tail"])
        self.assertFalse(
            any(line.startswith("Heard so far") and "70s" in line for line in lines),
            "live-transcript previews go to the status only, not the log",
        )
        paste.assert_called_once_with("piece piece piece")

    def test_a_failing_preview_past_the_takeover_stops_previews_but_not_the_pieces(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, _stream = self._streaming_stt([])
        previews: list[int] = []

        def tail(audio):
            previews.append(audio.size)
            raise RuntimeError("metal out of memory")

        self._pieces_or_tail(voice, tail)

        statuses, paste, lines = self._hold_long(voice, [None, None, None])

        self.assertEqual(len(previews), 1, "off for the rest of the recording")
        self.assertIn("Live preview off for this recording: metal out of memory\n", lines)
        self.assertEqual(statuses[1:], ["piece", "piece piece"])
        paste.assert_called_once_with("piece piece piece")

    def test_a_short_streamed_recording_is_decoded_whole_file_on_release(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        order: list[str] = []
        stream.close.side_effect = lambda: order.append("close") or "streamed words"
        voice.stt.decode = mock.Mock(
            side_effect=lambda audio: order.append("whole") or "whole-file words"
        )
        chunk = int(16000 * backends.STREAM_CHUNK_S)

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        voice.audio_callback(
            np.full((chunk, 1), 0.5, dtype=np.float32), chunk, None, None
        )
        voice.audio_callback(
            np.full((8000, 1), 0.5, dtype=np.float32), 8000, None, None
        )
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()  # a few milliseconds long: under the takeover
            self.assertTrue(voice.process_next(timeout=0))

        self.assertEqual(feeds, [chunk], "the 8000-sample remainder was never flushed")
        self.assertEqual(order, ["close", "whole"], "stream released before decoding")
        paste.assert_called_once_with("whole-file words")
        record = config.read_history()[-1]
        self.assertEqual(
            (record["raw"], record["streamed"]), ("whole-file words", False)
        )

    def test_a_cancelled_streaming_recording_never_opens_the_recogniser(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, stream = self._streaming_stt([])

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
            voice.cancel_recording()
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            self.assertTrue(voice.process_next(timeout=0))

        self.assertIsNone(voice.live)
        voice.stt.stream.assert_not_called()
        paste.assert_not_called()
        self.assertFalse(voice.processing)
        self.assertEqual(config.read_status()["state"], "idle")

    def test_a_streaming_failure_while_held_falls_back_to_whole_file_on_release(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt = mock.Mock(
            streaming=True,
            sample_rate=16000,
            stream=mock.Mock(side_effect=RuntimeError("metal out of memory")),
        )

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
            self.assertTrue(voice.process_next(timeout=0))  # the stream fails to open
            self.assertIsNone(voice.live, "dead job detached from the recording")
            self.assertTrue(voice.recording)
            self.assertEqual(config.read_status()["state"], "recording")
            voice.audio_callback(np.ones((8, 1), dtype=np.float32), 8, None, None)
            voice.stop_recording()

        self.assertTrue(voice.processing)
        frames, _duration = voice.jobs.get_nowait()
        self.assertEqual(
            len(frames), 1, "release queued the frames for whole-file decoding"
        )

    def test_a_streaming_failure_at_release_decodes_the_recording_whole_file(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        voice.stt.decode.side_effect = [  # the last piece fails, then the whole file
            RuntimeError("metal out of memory"),
            "whole-file words",
        ]
        chunk = int(16000 * backends.STREAM_CHUNK_S)

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        voice.audio_callback(
            np.full((chunk, 1), 0.5, dtype=np.float32), chunk, None, None
        )
        voice.audio_callback(
            np.full((8000, 1), 0.5, dtype=np.float32), 8000, None, None
        )
        voice.record_start -= backends.STREAM_TAKEOVER_S  # long: streamed text wanted
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()
            self.assertTrue(voice.process_next(timeout=0))

        self.assertEqual(feeds, [chunk], "nothing pushed after release")
        self.assertEqual(
            [c.args[0].shape for c in voice.stt.decode.call_args_list],
            [(chunk + 8000,), (chunk + 8000, 1)],
            "the piece, then the whole recording",
        )
        self.assertTrue(stream.closed, "stream released before the fallback decode")
        paste.assert_called_once_with("whole-file words")
        self.assertEqual(config.read_status()["state"], "idle")
        self.assertFalse(voice.processing)
        record = config.read_history()[-1]
        self.assertEqual(
            (record["raw"], record["streamed"]), ("whole-file words", False)
        )

    def test_the_whole_file_fallback_after_a_failed_push_keeps_the_audio_too(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, stream = self._streaming_stt([])
        stream.feed.side_effect = RuntimeError("metal out of memory")
        voice.stt.decode = mock.Mock(return_value="whole-file words")
        chunk = int(16000 * backends.STREAM_CHUNK_S)

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
        voice.audio_callback(
            np.full((chunk, 1), 0.5, dtype=np.float32), chunk, None, None
        )
        voice.record_start -= backends.STREAM_TAKEOVER_S
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.stop_recording()  # released before the worker fed anything
            self.assertTrue(
                voice.process_next(timeout=0)
            )  # the push fails after release

        paste.assert_called_once_with("whole-file words")
        self.assertEqual(wavfile.read(config.last_audio_path())[1].shape, (chunk,))

    def test_partials_reach_the_status_file_but_never_the_log(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        lines: list[str] = []
        sink = app.logger.add(
            lambda message: lines.append(str(message)), format="{message}"
        )
        self.addCleanup(app.logger.remove, sink)

        voice._show_partial("hello secret words", 16000 * 5)

        self.assertEqual(
            [line.strip() for line in lines], ["Heard so far: 3 words in 5s"]
        )
        self.assertEqual(config.read_status()["partial"], "hello secret words")

    def _pill_listener(self):
        """A datagram socket where the menu app's pill would listen."""
        config.ensure_dirs()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        listener.bind(str(config.live_socket_path()))
        listener.setblocking(False)
        self.addCleanup(listener.close)
        return listener

    def _pill_events(self, listener) -> list[dict]:
        events = []
        while True:
            try:
                events.append(json.loads(listener.recv(4096)))
            except BlockingIOError:
                return events

    def test_status_changes_reach_the_menu_apps_pill(self):
        voice = app.VoiceToText(config.Config(backend="parakeet", cleanup_enabled=False, mode="casual"))
        listener = self._pill_listener()

        voice._set_state("recording", partial="hello there")

        self.assertEqual(
            self._pill_events(listener),
            [
                {
                    "pid": os.getpid(),
                    "state": "recording",
                    "stt": "parakeet-v3",
                    "cleanup": "off",
                    "mode": "casual",
                    "streaming": False,
                    "live_transcript": False,
                    "reload": True,
                    "config": str(config.config_path()),
                    "error": "",
                    "warning": "",
                    "words": 2,
                    "partial": "hello there",
                }
            ],
        )

    def test_status_changes_work_with_no_menu_app_listening(self):
        voice = app.VoiceToText(config.Config(backend="parakeet", cleanup_enabled=False, mode="casual"))
        config.ensure_dirs()

        voice._set_state("recording")

        self.assertEqual(
            json.loads((config.run_dir() / "status.json").read_text()),
            {
                "pid": os.getpid(),
                "state": "recording",
                "stt": "parakeet-v3",
                "cleanup": "off",
                "mode": "casual",
                "streaming": False,
                "live_transcript": False,
                "reload": True,
                "config": str(config.config_path()),
                "error": "",
                "warning": "",
            },
        )

    def test_status_advertises_live_transcript_only_when_enabled_and_capture_can_stream(self):
        voice = app.VoiceToText(config.Config(backend="parakeet", cleanup_enabled=False, mode="casual"))
        listener = self._pill_listener()
        voice.stt, _stream = self._streaming_stt([])
        for mode, rate, backend_streams, live, available in (
            ("hacky", 16000, True, True, True),
            ("hacky", 16000, True, False, True),  # streams, but the transcript is off
            ("off", 16000, True, True, False),
            ("hacky", 48000, True, True, False),
            ("hacky", 16000, False, True, False),
        ):
            with self.subTest(
                mode=mode, rate=rate, backend_streams=backend_streams, live=live
            ):
                voice.cfg.streaming_mode = mode
                voice.cfg.sample_rate = rate
                voice.stt.streaming = backend_streams
                voice.cfg.live_transcript = live

                voice._set_state("idle")

                expected = {
                    "pid": os.getpid(),
                    "state": "idle",
                    "stt": "parakeet-v3",
                    "cleanup": "off",
                    "mode": "casual",
                    "streaming": available,
                    "live_transcript": available and live,
                    "reload": True,
                    "config": str(config.config_path()),
                    "error": "",
                    "warning": "",
                }
                self.assertEqual(self._pill_events(listener), [expected])
                self.assertEqual(
                    json.loads((config.run_dir() / "status.json").read_text()),
                    expected,
                )

    def test_input_level_reaches_the_pill_only_once_the_recording_shows(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        listener = self._pill_listener()
        voice.recording = True
        block = np.full((320, 1), 0.5, dtype=np.float32)

        voice.audio_callback(block, 320, None, None)  # still inside the hold
        hidden = self._pill_events(listener)
        voice.shown = True
        voice.audio_callback(block, 320, None, None)

        self.assertEqual(hidden, [])
        self.assertEqual(self._pill_events(listener), [{"level": 0.5}])

    def test_short_blocks_fold_into_the_loudest_level_per_interval(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        listener = self._pill_listener()
        voice.recording = voice.shown = True
        clock = [100.0]

        with mock.patch.object(app.time, "perf_counter", lambda: clock[0]):
            for value in (0.4, 0.1, 0.2):  # the first goes out; two held after it
                voice.audio_callback(
                    np.full((32, 1), value, dtype=np.float32), 32, None, None
                )
                clock[0] += app.LEVEL_INTERVAL_S / 4
            clock[0] += app.LEVEL_INTERVAL_S
            voice.audio_callback(
                np.full((32, 1), 0.3, dtype=np.float32), 32, None, None
            )

        self.assertEqual(self._pill_events(listener), [{"level": 0.4}, {"level": 0.3}])

    def test_a_streamed_recording_with_no_audio_returns_to_idle(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, stream = self._streaming_stt([])
        voice.stt.transcribe = mock.Mock()

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
            voice.record_start -= 1.0  # held, but the device produced no frames
            voice.stop_recording()
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            self.assertTrue(voice.process_next(timeout=0))

        self.assertEqual(config.read_status()["state"], "idle")
        self.assertFalse(voice.processing)
        self.assertTrue(stream.closed)
        voice.stt.transcribe.assert_not_called()
        paste.assert_not_called()

    def test_a_cancelled_streaming_job_does_not_touch_the_next_recording(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt, _stream = self._streaming_stt([])

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
            voice.cancel_recording()  # first tap of a double-tap
            voice.start_recording()  # second tap: hands-free recording begins
            stale = voice.jobs.get_nowait()
            self.assertTrue(stale.cancelled)
            voice.process_live(stale)

        self.assertTrue(voice.recording)
        self.assertEqual(config.read_status()["state"], "recording")
        self.assertFalse(voice.processing)

    def test_whisper_backend_keeps_the_whole_file_path(self):
        voice = app.VoiceToText(config.Config(backend="whisper", cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        # Same capture rate as Parakeet, so only the missing streaming path decides.
        voice.stt = mock.Mock(
            spec=["transcribe", "streaming", "sample_rate"],
            streaming=False,
            sample_rate=16000,
        )

        with mock.patch.object(app.sd, "InputStream"):
            voice.start_recording()
            self.assertIsNone(voice.live)
            voice.frames = [np.ones((8, 1), dtype=np.float32)]
            voice.stop_recording()
        with mock.patch.object(voice, "process_audio") as process:
            self.assertTrue(voice.process_next(timeout=0))

        self.assertFalse(voice.can_stream())
        frames, duration = process.call_args.args
        self.assertEqual(len(frames), 1)
        self.assertGreaterEqual(duration, 0)

    def test_streaming_is_off_when_the_capture_rate_is_not_the_models(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False, sample_rate=48000))
        voice.stt, _stream = self._streaming_stt([])

        self.assertFalse(voice.can_stream())

    def test_streaming_mode_is_read_from_config_and_validated(self):
        config.write_config('[transcription]\nstreaming_mode = "off"\n')

        self.assertEqual(config.load().streaming_mode, "off")
        self.assertEqual(config.Config().streaming_mode, "hacky")
        config.write_config('[transcription]\nstreaming_mode = "clean"\n')
        with self.assertRaises(SystemExit):
            config.load()

    def test_streaming_mode_flag_overrides_the_config(self):
        config.write_config('[transcription]\nstreaming_mode = "off"\n')
        seen: list[str] = []

        def voice(cfg):
            seen.append(cfg.streaming_mode)
            return types.SimpleNamespace(run=lambda: None)

        with (
            mock.patch.object(app, "check_and_request_permissions", return_value=False),
            mock.patch.object(app, "VoiceToText", side_effect=voice),
        ):
            cli.cmd_run(["--streaming-mode", "hacky"])
            cli.cmd_run([])
            cli.cmd_run(["--streaming-mode=off"])

        self.assertEqual(seen, ["hacky", "off", "off"])
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            cli.cmd_run(["--streaming-mode", "clean"])

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

    def test_history_is_a_private_sqlite_table_with_one_row_per_entry(self):
        config.append_history({"raw": "hello", "clean": "Hello.", "streamed": True})
        config.append_history({"raw": "again", "clean": "Again.", "novel": "x"})

        path = config.history_path()
        rows = config.read_history()

        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual([r["clean"] for r in rows], ["Hello.", "Again."])
        self.assertIs(rows[0]["streamed"], True)
        self.assertEqual(rows[1]["novel"], "x", "unknown keys ride in the extra column")
        self.assertTrue(rows[0]["ts"].endswith("+00:00"))
        self.assertTrue(rows[0]["version"] and rows[0]["host"], "filled in by append")
        with sqlite3.connect(path) as con:
            names = [r[1] for r in con.execute("PRAGMA table_info(transcriptions)")]
        self.assertEqual(names[:2], ["id", "ts"])
        self.assertEqual(set(names[1:]), {name for name, _ in config.HISTORY_COLUMNS})

    def test_the_jsonl_history_is_imported_once_and_left_in_place(self):
        legacy = config.legacy_history_path()
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_text(
            json.dumps({"ts": "2026-01-01T00:00:00+00:00", "raw": "a", "clean": "A."})
            + "\n"
            + json.dumps(
                {
                    "ts": "2026-01-02T00:00:00+00:00",
                    "source": "/x.wav",
                    "raw": "b",
                    "clean": "B.",
                }
            )
            + "\nnot json\n"
        )

        first = config.read_history()
        config.append_history({"raw": "c", "clean": "C."})
        second = config.read_history()

        self.assertEqual([r["clean"] for r in first], ["A.", "B."])
        self.assertEqual((first[0]["trigger"], first[0]["outcome"]), ("hold", "pasted"))
        self.assertEqual(
            (first[1]["trigger"], first[1]["outcome"]), ("file", "printed")
        )
        self.assertEqual([r["clean"] for r in second], ["A.", "B.", "C."])
        self.assertTrue(legacy.exists(), "the JSONL is the user's; never removed")

        # A v2t from before the database is still running and appends a line.
        with legacy.open("a") as f:
            f.write(
                json.dumps(
                    {"ts": "2026-01-03T00:00:00+00:00", "raw": "d", "clean": "D."}
                )
                + "\n"
            )
            f.write('{"ts": "2026-01-04T00:00:00+00:00", "raw": "half')  # mid-write

        third = config.read_history()

        self.assertEqual([r["clean"] for r in third], ["A.", "B.", "C.", "D."])
        self.assertEqual(
            [r["clean"] for r in config.read_history()], ["A.", "B.", "C.", "D."]
        )

    def test_an_interrupted_import_leaves_nothing_and_is_retried(self):
        legacy = config.legacy_history_path()
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_text(
            json.dumps({"ts": "2026-01-01T00:00:00+00:00", "raw": "a", "clean": "A."})
            + "\n"
            + json.dumps({"ts": "2026-01-02T00:00:00+00:00", "raw": "b", "clean": "B."})
            + "\n"
        )
        real_insert = config._insert_history
        calls = []

        def crash_on_second(con, record):
            calls.append(record["raw"])
            if len(calls) == 2:
                raise sqlite3.OperationalError("disk I/O error")
            real_insert(con, record)

        with mock.patch.object(config, "_insert_history", side_effect=crash_on_second):
            with self.assertRaises(sqlite3.OperationalError):
                config.read_history()

        self.assertTrue(config.history_path().exists(), "the file alone is no marker")
        with sqlite3.connect(config.history_path()) as con:
            self.assertEqual(
                con.execute("select count(*) from transcriptions").fetchone()[0], 0
            )
            self.assertIsNone(
                con.execute(
                    "select value from meta where key='legacy_offset'"
                ).fetchone()
            )

        self.assertEqual([r["clean"] for r in config.read_history()], ["A.", "B."])
        self.assertEqual([r["clean"] for r in config.read_history()], ["A.", "B."])

    def test_a_new_history_column_is_added_to_an_existing_database(self):
        config.append_history({"raw": "a", "clean": "A."})
        with sqlite3.connect(config.history_path()) as con:
            con.execute("ALTER TABLE transcriptions DROP COLUMN loud_frac")

        config.append_history({"raw": "b", "clean": "B.", "loud_frac": 0.5})

        self.assertEqual(config.read_history()[-1]["loud_frac"], 0.5)

    def test_audio_levels_tell_speech_from_a_dead_input(self):
        sr = 16000
        t = np.arange(3 * sr) / sr
        speech = (0.1 * np.sin(2 * np.pi * 200 * t)).astype(np.float32)
        dead = np.zeros(3 * sr, dtype=np.float32)
        dead[sr // 2] = 1.0  # the pop of a Bluetooth link opening
        dead[sr:] = np.random.default_rng(0).normal(0, 0.001, 2 * sr)

        live = app.audio_levels(speech, sr)
        silent = app.audio_levels(dead, sr)

        self.assertEqual(live["loud_frac"], 1.0, "every frame of a long run counts")
        self.assertEqual(app.level_warning(live, 3.0, "Mic"), "")
        short_runs = np.zeros(20 * 1600, dtype=np.float32)
        short_runs[0:3200] = 0.1  # two loud frames: a click, not speech
        short_runs[8000:12800] = 0.1  # three loud frames: counts, all three
        self.assertEqual(app.audio_levels(short_runs, sr)["loud_frac"], 3 / 20)
        self.assertLess(silent["loud_frac"], 0.02)
        self.assertEqual(silent["peak"], 1.0)
        self.assertGreater(silent["zero_frac"], 0.3)
        self.assertIn("from LABLABLA", app.level_warning(silent, 3.0, "LABLABLA"))
        self.assertEqual(app.level_warning(silent, 0.5, "LABLABLA"), "", "too short")
        self.assertEqual(app.audio_levels(np.zeros(0), sr)["loud_frac"], 0.0)

    def test_a_near_silent_dictation_is_pasted_and_warned_about(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt = mock.Mock(transcribe=mock.Mock(return_value="yeah yeah"))
        voice.input_device = "LABLABLA"
        voice.trigger = "latched"
        config.ensure_dirs()
        quiet = np.full((3 * 16000, 1), 0.002, dtype=np.float32)
        quiet[0, 0] = 0.9

        with (
            mock.patch.object(voice, "paste_to_cursor") as paste,
            mock.patch.object(app, "_notify") as notify,
        ):
            voice.process_audio([quiet], 3.0)

        paste.assert_called_once_with("yeah yeah")
        notify.assert_called_once()
        self.assertIn("from LABLABLA", notify.call_args.args[1])
        self.assertIn("from LABLABLA", config.read_status()["warning"])
        row = config.read_history()[-1]
        self.assertEqual(
            {
                k: row[k]
                for k in ("trigger", "device", "sample_rate", "outcome", "replacements")
            },
            {
                "trigger": "latched",
                "device": "LABLABLA",
                "sample_rate": 16000,
                "outcome": "pasted",
                "replacements": 0,
            },
        )
        self.assertIn("from LABLABLA", row["level_warning"])
        self.assertLess(row["loud_frac"], 0.02)

    def test_a_normal_dictation_records_levels_without_a_warning(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt = mock.Mock(transcribe=mock.Mock(return_value="hello"))
        config.ensure_dirs()
        sr = 16000
        speech = (
            (0.1 * np.sin(np.arange(2 * sr) * 0.1)).astype(np.float32).reshape(-1, 1)
        )

        with (
            mock.patch.object(voice, "paste_to_cursor"),
            mock.patch.object(app, "_notify") as notify,
        ):
            voice.process_audio([speech], 2.0)

        notify.assert_not_called()
        row = config.read_history()[-1]
        self.assertNotIn("level_warning", row)
        self.assertGreaterEqual(row["loud_frac"], 0.9)
        self.assertEqual(config.read_status()["warning"], "")

    def test_a_near_silent_recording_with_no_transcript_still_warns(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt = mock.Mock(transcribe=mock.Mock(return_value=""))
        voice.input_device = "LABLABLA"
        config.ensure_dirs()
        quiet = np.full((3 * 16000, 1), 0.002, dtype=np.float32)
        quiet[0, 0] = 0.9

        with mock.patch.object(app, "_notify") as notify:
            voice.process_audio([quiet], 3.0)

        notify.assert_called_once()
        self.assertIn("from LABLABLA", config.read_status()["warning"])
        row = config.read_history()[-1]
        self.assertEqual(row["outcome"], "error: no speech detected")
        self.assertIn("from LABLABLA", row["level_warning"])

    def test_a_transcription_crash_is_recorded_with_the_recording_facts(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.stt = mock.Mock(transcribe=mock.Mock(side_effect=RuntimeError("metal")))
        voice.input_device = "MacBook Pro Microphone"
        config.ensure_dirs()
        speech = np.full((2 * 16000, 1), 0.1, dtype=np.float32)

        voice.process_audio([speech], 2.0)

        row = config.read_history()[-1]
        self.assertEqual(row["outcome"], "error: RuntimeError: metal")
        self.assertEqual(row["device"], "MacBook Pro Microphone")
        self.assertEqual(row["loud_frac"], 1.0)
        self.assertEqual(config.read_status()["state"], "error")

    def test_a_dead_input_error_is_recorded_too(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.input_device = "Microsoft Teams Audio"
        config.ensure_dirs()

        with mock.patch.object(app.subprocess, "run"):
            voice.process_audio([np.zeros((16000, 1), dtype=np.float32)], 1.0)

        row = config.read_history()[-1]
        self.assertEqual(row["outcome"], "error: no audio captured")
        self.assertEqual(row["device"], "Microsoft Teams Audio")
        self.assertNotIn("raw", row)
        self.assertEqual(config.read_status()["state"], "error")

    def test_notifications_go_through_osascript_with_quotes_escaped(self):
        with mock.patch.object(app.subprocess, "run") as run:
            self.real_notify('v2t: "check"', 'peak 1.00 from "LABLABLA"')

        argv = run.call_args.args[0]
        self.assertEqual(argv[:2], ["osascript", "-e"])
        self.assertEqual(
            argv[2],
            'display notification "peak 1.00 from \\"LABLABLA\\"" '
            'with title "v2t: \\"check\\""',
        )

    def test_recording_captures_the_input_device_name(self):
        voice, _tap = self._tapper()
        with mock.patch.object(
            app.sd, "query_devices", return_value={"name": "USB PnP Sound Device"}
        ):
            voice.on_press("HOTKEY")

        self.assertEqual(voice.input_device, "USB PnP Sound Device")
        self.assertEqual(voice.trigger, "hold")

    def test_a_tap_keeps_the_last_dictations_warning_but_a_dictation_clears_it(self):
        voice, tap = self._tapper()
        voice.warning = "Near-silent audio from LABLABLA"

        tap(at=100.0, held=0.1)
        self.assertEqual(voice.warning, "Near-silent audio from LABLABLA")

        voice.on_press("HOTKEY")
        voice.hold_timer.fire()
        self.assertEqual(voice.warning, "")

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

    def test_config_set_without_a_file_starts_from_the_template_and_changes_one_line(self):
        config.set_value("cleanup.mode", "strict")

        written = config.config_path().read_text().splitlines()
        template = config.DEFAULT_TOML.splitlines()
        changed = [(old, new) for old, new in zip(template, written) if old != new]
        self.assertEqual(len(written), len(template))
        self.assertEqual(changed, [(
            'mode = "casual"        # casual (punctuation + fillers only, default) | strict (restructures)',
            'mode = "strict"        # casual (punctuation + fillers only, default) | strict (restructures)',
        )])
        self.assertEqual(stat.S_IMODE(config.config_path().stat().st_mode), 0o600)

    def test_config_set_adds_a_missing_key_to_its_section_and_a_missing_section_at_the_end(self):
        config.write_config('[cleanup]\nenabled = true\n\n[hotkey]\nkey = "fn"\n')

        config.set_value("cleanup.mode", "strict")
        config.set_value("behavior.keep_last_audio", "false")

        self.assertEqual(
            config.config_path().read_text(),
            '[cleanup]\nenabled = true\nmode = "strict"\n\n[hotkey]\nkey = "fn"\n\n'
            "[behavior]\nkeep_last_audio = false\n",
        )

    def test_config_set_parses_booleans_and_integers(self):
        config.set_value("transcription.live_transcript", "true")
        config.set_value("audio.sample_rate", "48000")

        self.assertEqual(
            {k: v for k, v in config.settings().items() if k in ("transcription.live_transcript", "audio.sample_rate")},
            {"transcription.live_transcript": True, "audio.sample_rate": 48000},
        )

    def test_config_set_refuses_bad_values_and_leaves_the_file_alone(self):
        config.write_config('[hotkey]\nkey = "fn"\n')
        for setting, value, message in (
            ("hotkey.key", "bogus", "invalid hotkey 'bogus'"),
            ("cleanup.enabled", "yes", "cleanup.enabled must be true or false"),
            ("audio.sample_rate", "fast", "audio.sample_rate must be an integer"),
            ("nope.key", "1", "unknown setting 'nope.key'"),
        ):
            with self.subTest(setting=setting), self.assertRaises(SystemExit) as refused:
                config.set_value(setting, value)
            self.assertIn(message, str(refused.exception))
        self.assertEqual(config.config_path().read_text(), '[hotkey]\nkey = "fn"\n')

    def test_config_set_finds_quoted_sections_and_keys(self):
        config.write_config('["cleanup"]\n\'enabled\' = true  # on\n"model" = \'my model # v1\'  # local\n')

        config.set_value("cleanup.enabled", "false")
        config.set_value("cleanup.model", "qwen")

        self.assertEqual(
            config.config_path().read_text(),
            '["cleanup"]\n\'enabled\' = false  # on\n"model" = "qwen"  # local\n',
        )

    def test_config_set_refuses_layouts_it_cannot_edit_and_leaves_the_file_alone(self):
        for text in ('cleanup.mode = "casual"\n', '[cleanup]\nmodel = """multi\nline"""\n'):
            config.write_config(text)
            setting = "cleanup.mode" if text.startswith("cleanup.") else "cleanup.model"
            with self.subTest(text=text), self.assertRaises(SystemExit) as refused:
                config.set_value(setting, "strict")
            self.assertIn(f"could not write {setting}", str(refused.exception))
            self.assertEqual(config.config_path().read_text(), text)

    def test_config_set_writes_any_unicode_path(self):
        config.set_value("transcription.model", "/models/whisper-🎙️-ünï")

        self.assertEqual(config.settings()["transcription.model"], "/models/whisper-🎙️-ünï")

    def test_config_setters_take_turns_so_neither_change_is_lost(self):
        config.write_config('[cleanup]\nmode = "casual"\n\n[hotkey]\nkey = "fn"\n')
        first_read, release = threading.Event(), threading.Event()
        real_set_line = config._set_line

        def slow_first_writer(text, section, key, literal):
            if section == "cleanup":  # the first setter has read the file; hold it there
                first_read.set()
                release.wait(2)
            return real_set_line(text, section, key, literal)

        with mock.patch.object(config, "_set_line", side_effect=slow_first_writer):
            first = threading.Thread(target=config.set_value, args=("cleanup.mode", "strict"))
            first.start()
            first_read.wait(2)
            second = threading.Thread(target=config.set_value, args=("hotkey.key", "cmd_r"))
            second.start()
            second.join(0.3)  # without the lock it reads the old file and finishes here
            release.set()
            first.join(2)
            second.join(2)

        self.assertEqual(
            {k: v for k, v in config.settings().items() if k in ("cleanup.mode", "hotkey.key")},
            {"cleanup.mode": "strict", "hotkey.key": "cmd_r"},
        )

    def test_config_set_writes_through_a_symlinked_config(self):
        target = Path(self.tempdir.name) / "dotfiles-config.toml"
        target.write_text('[hotkey]\nkey = "fn"\n')
        config.config_path().symlink_to(target)

        config.set_value("hotkey.key", "cmd_r")

        self.assertTrue(config.config_path().is_symlink())
        self.assertEqual(target.read_text(), '[hotkey]\nkey = "cmd_r"\n')

    def test_config_json_prints_paths_and_every_setting_after_a_set(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = cli.cmd_config(["set", "hotkey.key", "alt_r", "--json"])

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.getvalue()), {
            "home": self.tempdir.name,
            "config": str(config.config_path()),
            "settings": {
                "transcription.backend": "parakeet-coreml", "transcription.model": "",
                "transcription.streaming_mode": "hacky", "transcription.live_transcript": False,
                "cleanup.enabled": True, "cleanup.engine": "mlx", "cleanup.model": "",
                "cleanup.mode": "casual", "hotkey.key": "alt_r", "audio.sample_rate": 16000,
                "behavior.pause_music": False, "behavior.save_history": True,
                "behavior.keep_last_audio": True, "ollama.url": "http://localhost:11434",
            },
        })

    def test_config_set_needs_a_key_and_a_value(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as refused:
            cli.cmd_config(["set", "hotkey.key"])

        self.assertEqual(refused.exception.code, 2)
        self.assertFalse(config.config_path().exists())

    def test_setup_help_prints_usage_and_asks_nothing(self):
        output = io.StringIO()
        with (
            mock.patch("builtins.input", side_effect=AssertionError("prompted")),
            contextlib.redirect_stdout(output),
            self.assertRaises(SystemExit) as exit_,
        ):
            cli.cmd_setup(["--help"])

        self.assertEqual(exit_.exception.code, 0)
        self.assertIn("usage: v2t setup", output.getvalue())
        self.assertFalse(config.config_path().exists())

    def test_setup_without_answers_exits_cleanly_and_writes_nothing(self):
        errors = io.StringIO()
        with (
            mock.patch("builtins.input", side_effect=EOFError),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(errors),
        ):
            code = cli.cmd_setup([])

        self.assertEqual(code, 1)
        self.assertIn("v2t config --init", errors.getvalue())
        self.assertFalse(config.config_path().exists())

    def test_setup_quotes_the_whisper_extra_for_zsh(self):
        output = io.StringIO()
        with (
            mock.patch("builtins.input", side_effect=["3", "n"]),
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
            mock.patch.object(menubar, "user_app_path", return_value=destination),
            mock.patch.object(menubar, "SYSTEM_APPLICATIONS", Path(self.tempdir.name) / "Applications"),
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar, "signing_identity", return_value="-"),
            mock.patch.object(menubar.subprocess, "run", side_effect=compile_app),
            mock.patch.dict(os.environ, {"V2T_HOME": self.tempdir.name}, clear=True),
        ):
            installed = menubar.install()

        self.assertEqual(installed, destination)
        info = plistlib.loads((installed / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(
            info,
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "Voice2Text",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIdentifier": "com.lucharo.voice2text",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Voice2Text",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": menubar.__version__,
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSMicrophoneUsageDescription": "Voice2Text uses the microphone for fully local transcription.",
                "NSPrincipalClass": "NSApplication",
                "V2THome": self.tempdir.name,
                "V2TPythonExecutable": sys.executable,
            },
        )
        icon = installed / "Contents" / "Resources" / "AppIcon.icns"
        self.assertEqual(icon.read_bytes()[:4], b"icns")
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

    def test_menubar_install_refuses_beside_the_cask_install(self):
        system = Path(self.tempdir.name) / "Applications"
        executable = system / "Voice2Text.app" / "Contents" / "MacOS" / "Voice2Text"
        executable.parent.mkdir(parents=True)
        executable.touch()
        destination = Path(self.tempdir.name) / "user" / "Voice2Text.app"

        with (
            mock.patch.object(menubar, "user_app_path", return_value=destination),
            mock.patch.object(menubar, "SYSTEM_APPLICATIONS", system),
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar.subprocess, "run") as run,
            mock.patch.dict(os.environ, {"V2T_HOME": self.tempdir.name}, clear=True),
            self.assertRaisesRegex(SystemExit, "brew upgrade --cask voice2text"),
        ):
            menubar.install()

        run.assert_not_called()
        self.assertFalse(destination.exists())

    def test_menubar_build_without_baked_paths_is_portable(self):
        bundle = Path(self.tempdir.name) / "out" / "Voice2Text.app"
        bundle.parent.mkdir()
        commands = []

        def compile_app(command, **_kwargs):
            commands.append(command)
            if command[0] == "xcrun":
                Path(command[command.index("-o") + 1]).touch(mode=0o755)
            return mock.Mock(returncode=0)

        with (
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar.subprocess, "run", side_effect=compile_app),
            mock.patch.dict(os.environ, {"V2T_CONFIG": "/somewhere/config.toml"}),
        ):
            built = menubar.build(
                bundle,
                bake_paths=False,
                identity="Developer ID Application: Someone (TEAMID)",
            )

        self.assertEqual(built, bundle)
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(
            info,
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "Voice2Text",
                "CFBundleIconFile": "AppIcon",
                "CFBundleIdentifier": "com.lucharo.voice2text",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "Voice2Text",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": menubar.__version__,
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSMicrophoneUsageDescription": "Voice2Text uses the microphone for fully local transcription.",
                "NSPrincipalClass": "NSApplication",
            },
        )
        codesign = next(command for command in commands if command[0] == "codesign")
        self.assertEqual(codesign[:5], ["codesign", "--force", "--options", "runtime", "--timestamp"])
        self.assertEqual(
            codesign[codesign.index("--sign") + 1],
            "Developer ID Application: Someone (TEAMID)",
        )
        self.assertTrue(codesign[-1].endswith("/Voice2Text.app"))
        self.assertNotEqual(codesign[-1], str(bundle))  # staged, moved once signed

    def test_menubar_build_leaves_no_partial_bundle_when_signing_fails(self):
        bundle = Path(self.tempdir.name) / "out" / "Voice2Text.app"
        bundle.parent.mkdir()
        (bundle / "Contents").mkdir(parents=True)
        (bundle / "Contents" / "marker").write_text("previous build")

        def compile_then_fail(command, **_kwargs):
            if command[0] == "xcrun":
                Path(command[command.index("-o") + 1]).touch(mode=0o755)
                return mock.Mock(returncode=0)
            raise menubar.subprocess.CalledProcessError(1, command)

        with (
            mock.patch.object(menubar.sys, "platform", "darwin"),
            mock.patch.object(menubar.subprocess, "run", side_effect=compile_then_fail),
            self.assertRaises(menubar.subprocess.CalledProcessError),
        ):
            menubar.build(bundle, bake_paths=False, identity="-")

        self.assertEqual(sorted(p.name for p in (bundle / "Contents").iterdir()), ["marker"])
        self.assertEqual((bundle / "Contents" / "marker").read_text(), "previous build")
        self.assertEqual(sorted(p.name for p in bundle.parent.iterdir()), ["Voice2Text.app"])

    def test_menubar_app_path_prefers_the_cask_install(self):
        system = Path(self.tempdir.name) / "Applications"
        with mock.patch.object(menubar, "SYSTEM_APPLICATIONS", system):
            self.assertEqual(menubar.app_path(), menubar.user_app_path())

            executable = system / "Voice2Text.app" / "Contents" / "MacOS" / "Voice2Text"
            executable.parent.mkdir(parents=True)
            executable.touch()
            self.assertEqual(menubar.app_path(), system / "Voice2Text.app")

    def test_menubar_build_command_compiles_a_portable_bundle(self):
        output = io.StringIO()
        with (
            mock.patch.object(menubar, "build") as build,
            contextlib.redirect_stdout(output),
        ):
            build.return_value = Path(self.tempdir.name) / "Voice2Text.app"
            self.assertEqual(
                cli.cmd_menubar(["build", self.tempdir.name, "--identity", "Developer ID Application: X (T)"]),
                0,
            )

        build.assert_called_once_with(
            Path(self.tempdir.name) / "Voice2Text.app",
            bake_paths=False,
            identity="Developer ID Application: X (T)",
        )
        self.assertEqual(output.getvalue(), f"built {self.tempdir.name}/Voice2Text.app\n")

    def test_menubar_build_command_needs_a_destination(self):
        with (
            mock.patch.object(menubar, "build") as build,
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as raised,
        ):
            cli.cmd_menubar(["build"])

        self.assertEqual(raised.exception.code, 2)
        build.assert_not_called()

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

        record = config.read_history()[-1]
        self.assertEqual(
            record,
            {
                "id": record["id"],
                "ts": record["ts"],
                "trigger": "file",
                "source": str(path),
                "audio_s": 10.0,
                "backend": "parakeet-coreml",
                "model": backends.ParakeetCoreMLSTT.default_model,
                "mode": "casual",
                "stt_s": record["stt_s"],
                "cleanup_s": 0.0,
                "replacements": 0,
                "raw": "hey um there",
                "clean": "hey um there",
                "outcome": "printed",
                "host": record["host"],
                "version": record["version"],
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
        """An MLXCleanup with the model mocked: each call decodes the next reply.

        Tokens are words here: the tokenizer splits and joins on spaces.
        """
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.apply_chat_template.return_value = "prompt"
        cleaner.tokenizer.encode.side_effect = lambda text: text.split()
        cleaner.tokenizer.decode.side_effect = " ".join
        cleaner.last_stats = {}
        queue_ = list(replies)

        def decode(_prompt, _mode, _source, max_tokens):
            reply = queue_.pop(0)
            if reply is None:  # loops forever: runs into max_tokens
                return ["word"] * max_tokens, 0.0
            return reply.split(" "), 0.0

        cleaner._decode = decode
        return cleaner

    def test_cleanup_keeps_the_raw_chunk_when_the_model_hits_its_token_limit(self):
        cleaner = self._mlx_cleaner([None])

        text, _ttft, _total = cleaner.cleanup("hello um there friend", "casual")

        self.assertEqual(text, "hello um there friend")
        self.assertEqual(cleaner.last_stats, {"chunks": 1, "guarded": 0, "limited": 1, "restored": 0, "reverted": 0, "removed": 0})

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
        self.assertEqual(cleaner.last_stats, {"chunks": 1, "guarded": 0, "limited": 0, "restored": 0, "reverted": 0, "removed": 0})

    def test_keep_spoken_words_holds_each_edit_to_what_was_said(self):
        cases = [
            # a number in digits stays; a word changed beside it comes back
            ("send three red boxes tomorrow", "Send 3 blue boxes tomorrow.", "Send 3 red boxes tomorrow."),
            ("it says twenty five percent", "It said 25%.", "It says 25%."),
            ("send three red boxes tomorrow", "Send 3 boxes tomorrow.", "Send three red boxes tomorrow."),
            ("she says", "She said.", "She says."),
            ("ship it", "Ship it to Claude.", "Ship it."),
            # one of a repeated word the cleanup dropped whole comes back
            ("I can can attend on Friday", "I attend on Friday.", "I can attend on Friday."),
            # words put back at the end go before the full stop, capitals kept
            ("send it to me please", "Send it to me.", "Send it to me please."),
            ("it is fine", "It's fine.", "It is fine."),
            # dictionary words are the cleanup's to write
            ("we met clod yesterday", "We met Claude yesterday.", "We met Claude yesterday."),
        ]
        for raw, clean, expected in cases:
            with self.subTest(raw=raw):
                text, _counts = backends.keep_spoken_words(raw, clean, ["Claude"])
                self.assertEqual(text, expected)

    def test_parakeet_picks_the_loader_by_the_repos_file_layout(self):
        def cached(files):
            return lambda repo, name: f"/cache/{name}" if name in files else None

        for files, expected in ((["config.json"], "parakeet-mlx"), (["model_config.yaml"], "nemo")):
            hub = mock.Mock(try_to_load_from_cache=cached(files), snapshot_download=lambda repo: "/snap")
            with (
                self.subTest(files=files),
                mock.patch.dict(sys.modules, {"huggingface_hub": hub}),
                mock.patch.object(backends, "load_nemo_layout", return_value="nemo") as nemo,
            ):
                got = backends._load_parakeet("org/model", lambda repo: "parakeet-mlx")
            self.assertEqual(got, expected)
            if expected == "nemo":
                nemo.assert_called_once_with(Path("/snap"))

    def test_casual_cleanup_puts_back_words_it_dropped(self):
        raw = "um I think that we should ship the migration and then test it on friday"
        cleaner = self._mlx_cleaner(["I think we should ship the migration, then test it on Friday."])

        text, _ttft, _total = cleaner.cleanup(raw, "casual")

        self.assertEqual(text, "I think that we should ship the migration, and then test it on Friday.")
        self.assertEqual(cleaner.last_stats["restored"], 2)

    def test_cleanup_keeps_fillers_repeats_numbers_and_dictionary_fixes_out(self):
        text, counts = backends.keep_spoken_words(
            "uh PR three five nine is is done by clot", "PR #359 is done by Claude.", ["Claude"]
        )

        self.assertEqual(text, "PR #359 is done by Claude.")
        self.assertEqual(counts, {"restored": 0, "reverted": 0, "removed": 0})

    def test_cleanup_grammar_edits_and_added_words_are_undone(self):
        text, counts = backends.keep_spoken_words(
            "she says it is fine", "She said it's really fine."
        )

        self.assertEqual(text, "She says it is fine.")
        self.assertEqual(counts, {"restored": 0, "reverted": 3, "removed": 0})

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
        """A VoiceToText whose audio stream is mocked, plus a helper to tap the hotkey.

        The hold timer is a fake: `voice.hold_timer.fire()` stands for the key
        still being down after HOLD_S.
        """
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        voice.hotkey = "HOTKEY"
        stream = mock.patch.object(app.sd, "InputStream")
        self.addCleanup(stream.stop)
        stream.start()

        class Timer:
            def __init__(self, _interval, function):
                self.fire = function
                self.cancelled = False

            def start(self):
                pass

            def cancel(self):
                self.cancelled = True

        timer = mock.patch.object(app.threading, "Timer", Timer)
        self.addCleanup(timer.stop)
        timer.start()
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

    def test_escape_cancels_hold_and_undo_resumes_the_captured_audio(self):
        voice, _tap = self._tapper()
        voice.on_press("HOTKEY")
        voice.hold_timer.fire()
        audio = np.full((16, 1), 0.5, dtype=np.float32)
        voice.audio_callback(audio, len(audio), None, None)
        voice.on_press(types.SimpleNamespace(name="esc"))
        voice.on_release("HOTKEY")

        self.assertTrue(voice.escape_consumed)
        self.assertFalse(voice.recording)
        self.assertFalse(voice.latched)
        self.assertTrue(voice.jobs.empty())
        self.assertEqual(config.read_status()["state"], "cancelled")
        np.testing.assert_array_equal(voice.cancelled_audio[0][0], audio)

        voice.request_undo()
        voice.process_next(timeout=0)

        self.assertTrue(voice.recording)
        self.assertTrue(voice.latched)
        self.assertIsNone(voice.cancelled_audio)
        self.assertEqual(config.read_status()["state"], "recording")
        np.testing.assert_array_equal(voice.frames[0], audio)
        voice.audio_callback(audio / 2, len(audio), None, None)
        voice.on_press("HOTKEY")
        voice.on_release("HOTKEY")
        frames, _duration = voice.jobs.get_nowait()
        np.testing.assert_array_equal(np.concatenate(frames), np.concatenate([audio, audio / 2]))
        self.assertFalse(voice.latched)

    def test_escape_cancels_a_queued_whole_file_job_without_decoding(self):
        voice, _tap = self._tapper()
        voice.stt = types.SimpleNamespace(transcribe=mock.Mock(return_value="late text"))
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.stop_recording()
        voice.on_press(types.SimpleNamespace(name="esc"))
        saved = voice.cancelled_audio
        voice.on_press(types.SimpleNamespace(name="esc"))
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.process_next(timeout=0)
        self.assertIs(voice.cancelled_audio, saved)
        self.assertFalse(voice.processing)
        self.assertEqual(config.read_status()["state"], "cancelled")
        voice.stt.transcribe.assert_not_called()
        paste.assert_not_called()

    def test_escape_during_whole_file_decode_blocks_the_late_paste(self):
        voice, _tap = self._tapper()
        def decode(_path):
            voice.on_press(types.SimpleNamespace(name="esc"))
            return "late text"
        voice.stt = types.SimpleNamespace(transcribe=decode)
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.stop_recording()
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.process_next(timeout=0)
        paste.assert_not_called()
        self.assertFalse(voice.processing)
        self.assertIsNotNone(voice.cancelled_audio)
        self.assertEqual(config.read_status()["state"], "cancelled")

    def test_escape_during_cleanup_blocks_the_late_paste(self):
        voice, _tap = self._tapper()
        voice.stt = types.SimpleNamespace(transcribe=lambda _path: "raw words")
        def cleanup(_text, _mode):
            voice.on_press(types.SimpleNamespace(name="esc"))
            return "clean words", 0.0, 0.0
        voice.cleaner = types.SimpleNamespace(cleanup=cleanup)
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.stop_recording()
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.process_next(timeout=0)
        paste.assert_not_called()
        self.assertIsNotNone(voice.cancelled_audio)
        self.assertEqual(config.read_status()["state"], "cancelled")

    def test_escape_during_streaming_drains_the_cancelled_job_before_undo(self):
        voice, _tap = self._tapper()
        voice.stt, stream = self._streaming_stt([])
        def feed(_samples):
            voice.on_press(types.SimpleNamespace(name="esc"))
            voice.request_undo()
        stream.feed = feed
        voice.start_recording()
        samples = int(voice.cfg.sample_rate * backends.STREAM_CHUNK_S)
        voice.audio_callback(np.ones((samples, 1), dtype=np.float32), samples, None, None)
        with mock.patch.object(voice, "paste_to_cursor") as paste:
            voice.process_next(timeout=0)
        paste.assert_not_called()
        self.assertFalse(voice.processing)
        self.assertIsNone(voice.cancelled_job)
        self.assertEqual(config.read_status()["state"], "cancelled")
        # The next poll accepts Undo only after the cancelled model call returns.
        voice.stt = None  # resume without starting another streaming worker here
        voice.process_next(timeout=0)
        self.assertTrue(voice.recording)
        self.assertTrue(voice.latched)
        self.assertEqual(len(voice.frames[0]), samples)

    def test_escape_after_paste_has_started_is_not_reported_as_cancelled(self):
        voice, _tap = self._tapper()
        voice.stt = types.SimpleNamespace(transcribe=lambda _path: "words")
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.stop_recording()
        with mock.patch.object(voice, "paste_to_cursor", side_effect=lambda _text: voice.on_press(types.SimpleNamespace(name="esc"))):
            voice.process_next(timeout=0)
        self.assertFalse(voice.escape_consumed)
        self.assertIsNone(voice.cancelled_audio)
        self.assertEqual(config.read_status()["state"], "idle")

    def test_escape_when_idle_passes_through_and_does_not_stop_the_engine(self):
        voice, _tap = self._tapper()
        voice.on_press(types.SimpleNamespace(name="esc"))
        self.assertFalse(voice.escape_consumed)
        self.assertFalse(voice.stopping)

    def test_failed_undo_keeps_the_cancelled_audio_for_another_attempt(self):
        voice, _tap = self._tapper()
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.on_press(types.SimpleNamespace(name="esc"))
        saved = voice.cancelled_audio
        with mock.patch.object(app.sd, "InputStream", side_effect=RuntimeError("device gone")), mock.patch.object(app.subprocess, "run"):
            voice.undo_cancelled()
        self.assertIs(voice.cancelled_audio, saved)
        self.assertFalse(voice.recording)
        self.assertFalse(voice.latched)

    CMD, SHIFT = 1 << 20, 1 << 17

    def _quartz(self):
        """Quartz as the listener sees it; an event is a keycode or (keycode, flags)."""
        return types.SimpleNamespace(
            kCGEventFlagMaskSecondaryFn=1 << 23, kCGKeyboardEventKeycode=9,
            kCGEventKeyUp=11, kCGEventFlagMaskCommand=self.CMD,
            kCGEventFlagMaskShift=self.SHIFT, kCGEventFlagMaskControl=1 << 18,
            kCGEventFlagMaskAlternate=1 << 19,
            CGEventGetIntegerValueField=lambda event, _field: event[0] if isinstance(event, tuple) else event,
            CGEventGetFlags=lambda event: event[1] if isinstance(event, tuple) else 0,
        )

    def test_the_cancelled_pill_goes_away_when_the_undo_window_closes(self):
        voice, _tap = self._tapper()
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.on_press(types.SimpleNamespace(name="esc"))
        self.assertEqual(config.read_status()["state"], "cancelled")

        voice.undo_timer.fire()

        self.assertEqual(config.read_status()["state"], "idle")
        self.assertIsNone(voice.cancelled_audio, "the held audio is dropped")
        self.assertIsNone(voice.undo_timer)
        voice.request_undo()
        voice.process_next(timeout=0)
        self.assertFalse(voice.recording, "nothing left to undo")

    def test_the_undo_window_waits_for_a_cancelled_job_to_drain(self):
        voice, _tap = self._tapper()
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.on_press(types.SimpleNamespace(name="esc"))
        first = voice.undo_timer
        voice.processing = True  # the cancelled inference has not returned yet

        first.fire()

        self.assertEqual(config.read_status()["state"], "cancelled")
        self.assertIsNotNone(voice.cancelled_audio)
        self.assertIsNot(voice.undo_timer, first, "looks again shortly")

    def test_cmd_z_undoes_only_while_a_cancelled_dictation_is_recoverable(self):
        voice, _tap = self._tapper()
        class Listener:
            _MODIFIER_FLAGS = {}
            def __init__(self, **options):
                self.options = options
        escape = types.SimpleNamespace(name="esc", value=types.SimpleNamespace(vk=53))
        keyboard = types.SimpleNamespace(
            Listener=Listener, KeyCode=types.SimpleNamespace(from_vk=lambda value: value),
            Key=types.SimpleNamespace(esc=escape),
        )
        with mock.patch.dict(sys.modules, {"pynput": types.SimpleNamespace(keyboard=keyboard), "Quartz": self._quartz()}):
            listener = app._listener(
                voice.on_press, voice.on_release, voice.consume_escape, voice.take_undo_shortcut
            )
        intercept = listener.options["darwin_intercept"]
        cmd_z, cmd_shift_z = (app.Z_VK, self.CMD), (app.Z_VK, self.CMD | self.SHIFT)

        self.assertEqual(intercept(10, cmd_z), cmd_z, "idle: the app's own undo")
        voice.start_recording()
        voice.frames = [np.ones((16, 1), dtype=np.float32)]
        voice.on_press(escape)
        intercept(11, 53)
        self.assertEqual(intercept(10, (app.Z_VK, 0)), (app.Z_VK, 0), "plain z passes")
        self.assertEqual(intercept(10, cmd_shift_z), cmd_shift_z, "redo passes")
        self.assertIsNone(intercept(10, cmd_z))
        self.assertTrue(voice.undo_requested.is_set())
        self.assertIsNone(intercept(10, cmd_z), "autorepeat swallowed")
        self.assertIsNone(intercept(11, (app.Z_VK, 0)), "key-up swallowed, Cmd already up")
        voice.undo_timer.fire()  # the window closes
        self.assertEqual(intercept(10, cmd_z), cmd_z)

    def test_listener_swallows_only_escape_consumed_by_the_dictation(self):
        voice, _tap = self._tapper()
        class Listener:
            _MODIFIER_FLAGS = {}
            def __init__(self, **options):
                self.options = options
        escape = types.SimpleNamespace(name="esc", value=types.SimpleNamespace(vk=53))
        keyboard = types.SimpleNamespace(
            Listener=Listener, KeyCode=types.SimpleNamespace(from_vk=lambda value: value),
            Key=types.SimpleNamespace(esc=escape),
        )
        with mock.patch.dict(sys.modules, {"pynput": types.SimpleNamespace(keyboard=keyboard), "Quartz": self._quartz()}):
            listener = app._listener(voice.on_press, voice.on_release, voice.consume_escape)
        intercept = listener.options["darwin_intercept"]
        listener.options["on_press"](escape)
        self.assertEqual(intercept(10, 53), 53)  # idle: let the target app see Esc
        voice.start_recording()
        listener.options["on_press"](escape)
        self.assertIsNone(intercept(10, 53))
        listener.options["on_press"](escape)  # autorepeat after cancellation finished
        self.assertIsNone(intercept(10, 53))
        self.assertIsNone(intercept(11, 53))  # matching key-up is swallowed too
        listener.options["on_press"](escape)  # next physical press while idle
        self.assertEqual(intercept(10, 53), 53)
        self.assertEqual(intercept(10, 0), 0)  # unrelated keys always pass through

    def test_cancelled_audio_survives_a_short_tap_and_a_modifier_chord(self):
        voice, tap = self._tapper()
        for chord in (False, True):
            with self.subTest(chord=chord):
                voice.start_recording()
                audio = np.ones((16, 1), dtype=np.float32)
                voice.frames = [audio]
                voice.cancel_dictation()
                saved = voice.cancelled_audio
                if chord:
                    voice.on_press("HOTKEY")
                    voice.on_press("ARROW")
                    voice.on_release("HOTKEY")
                else:
                    tap(at=101.0, held=0.1)
                self.assertIs(voice.cancelled_audio, saved)
                self.assertEqual(config.read_status()["state"], "cancelled")
                voice.undo_cancelled()
                self.assertTrue(voice.recording)
                self.assertIsNone(voice.cancelled_audio)
                np.testing.assert_array_equal(voice.frames[0], audio)
                voice.cancel_recording()

    def test_a_short_tap_is_discarded_not_transcribed(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=0.1)

        self.assertFalse(voice.recording)
        self.assertFalse(voice.processing)
        self.assertTrue(voice.jobs.empty())
        self.assertEqual(config.read_status()["state"], "idle")

    def test_a_press_records_at_once_but_shows_only_after_the_hold(self):
        voice, _tap = self._tapper()
        set_state = mock.patch.object(voice, "_set_state", wraps=voice._set_state)
        self.addCleanup(set_state.stop)
        states = set_state.start()

        voice.on_press("HOTKEY")

        self.assertTrue(voice.recording, "the microphone is open from the press")
        self.assertFalse(voice.shown)
        states.assert_not_called()

        voice.hold_timer.fire()

        self.assertTrue(voice.shown)
        self.assertEqual(config.read_status()["state"], "recording")

    def test_a_short_tap_leaves_no_trace(self):
        voice, tap = self._tapper()
        set_state = mock.patch.object(voice, "_set_state", wraps=voice._set_state)
        self.addCleanup(set_state.stop)
        states = set_state.start()

        tap(at=100.0, held=0.4)

        self.assertTrue(voice.hold_timer is None)
        self.assertNotIn("recording", [c.args[0] for c in states.call_args_list])

    def test_a_chord_with_the_hotkey_cancels_and_is_not_a_tap(self):
        voice, tap = self._tapper()
        app.time.perf_counter.return_value = 100.0

        voice.on_press("HOTKEY")
        timer = voice.hold_timer
        voice.on_press("enter")

        self.assertFalse(voice.recording)
        self.assertTrue(timer.cancelled)

        app.time.perf_counter.return_value = 100.1
        voice.on_release("HOTKEY")
        tap(at=100.3, held=0.1)

        self.assertFalse(voice.latched, "chord + tap is not a double-tap")
        self.assertFalse(voice.recording)
        self.assertTrue(voice.jobs.empty())

    def test_typing_while_latched_keeps_recording(self):
        voice, tap = self._tapper()

        tap(at=100.0, held=0.1)
        tap(at=100.3, held=0.1)
        voice.on_press("a")

        self.assertTrue(voice.latched)
        self.assertTrue(voice.recording)

    def test_the_fn_key_is_a_modifier_for_the_listener(self):
        class KeyCode:
            def __init__(self, vk):
                self.vk = vk

            @classmethod
            def from_vk(cls, vk):
                return cls(vk)

            def __eq__(self, other):
                return self.vk == other.vk

            def __hash__(self):
                return hash(self.vk)

        class Listener:
            _MODIFIER_FLAGS = {KeyCode(0x36): 1 << 20}

            def __init__(self, on_press, on_release):
                self.callbacks = (on_press, on_release)

        pynput = types.ModuleType("pynput")
        pynput.keyboard = types.SimpleNamespace(
            Listener=Listener, KeyCode=KeyCode, Key=mock.Mock()
        )
        quartz = types.SimpleNamespace(kCGEventFlagMaskSecondaryFn=1 << 23)

        with mock.patch.dict(sys.modules, {"pynput": pynput, "Quartz": quartz}):
            listener = app._listener("press", "release")
            self.assertEqual(app._resolve_hotkey("fn"), KeyCode(app.FN_VK))

        self.assertEqual(listener.callbacks, ("press", "release"))
        self.assertEqual(listener._MODIFIER_FLAGS[KeyCode(0x3F)], 1 << 23)
        self.assertEqual(listener._MODIFIER_FLAGS[KeyCode(0x36)], 1 << 20)
        self.assertEqual(app.FN_VK, 0x3F)

    def test_globe_key_warning_only_when_the_key_is_not_free(self):
        def run(_argv, **_kwargs):
            return app.subprocess.CompletedProcess(_argv, 0, stdout="0\n", stderr="")

        with mock.patch.object(app.subprocess, "run", side_effect=run):
            self.assertEqual(app.globe_key_warning(), "")

        def run_default(_argv, **_kwargs):
            return app.subprocess.CompletedProcess(
                _argv, 1, stdout="", stderr="missing"
            )

        with mock.patch.object(app.subprocess, "run", side_effect=run_default):
            self.assertIn(app.GLOBE_KEY_FIX, app.globe_key_warning())

        with mock.patch.object(
            app.subprocess, "run", side_effect=FileNotFoundError("defaults")
        ):
            self.assertEqual(app.globe_key_warning(), "", "not macOS: no warning")

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

    def test_cleanup_examples_teach_digits_and_hash_prefixed_references(self):
        for mode, examples in backends.EXAMPLES.items():
            cleaned = " ".join(clean for _raw, clean in examples)
            self.assertIn("PR #359", cleaned, mode)
            self.assertIn("issue #42", cleaned, mode)
            self.assertIn("0.1", cleaned, mode)
            self.assertIn("digits", backends.PROMPTS[mode], mode)

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
        cleaner.tokenizer.decode.side_effect = " ".join
        cleaner._decode = lambda *_args: (["Hello,", "there."], 0.0)

        text, ttft, total = cleaner.cleanup("hello um there", "strict")

        self.assertEqual(text, "Hello, there.")
        self.assertIsNotNone(ttft)
        self.assertGreaterEqual(total, ttft)
        cleaner.tokenizer.apply_chat_template.assert_called_once_with(
            backends.cleanup_messages("hello um there", "strict"),
            add_generation_prompt=True,
            enable_thinking=False,
        )

    class _ToyDecoder:
        """A greedy "model" over its whole history: it copies SOURCE, inserts 99 at
        every seventh output position and ends after 25 tokens. Any token a rollback
        leaves behind changes what it predicts next."""

        SOURCE = list(range(10, 40))
        EOS = 0

        def __init__(self, prompt):
            self.prompt_len = len(prompt)
            self.history = list(prompt)
            self.feeds = self.rollbacks = 0
            self.next = self._pick()

        def _pick(self):
            n = len(self.history) - self.prompt_len
            if n >= 25:
                return self.EOS
            if n % 7 == 6:
                return 99
            copied = [t for t in self.history[self.prompt_len :] if t != 99]
            return self.SOURCE[len(copied) % len(self.SOURCE)]

        def feed(self, tokens):
            self.feeds += 1
            picks = []
            for token in tokens:
                self.history.append(token)
                picks.append(self._pick())
            return picks

        def checkpoint(self):
            return len(self.history)

        def rollback(self, cp, fed):
            assert len(self.history) - cp == fed, "a rollback undoes exactly what was fed"
            self.rollbacks += 1
            del self.history[cp:]

    def test_lookup_decoding_returns_the_greedy_tokens_in_fewer_model_calls(self):
        greedy = self._ToyDecoder([1, 2, 3])
        lookup = self._ToyDecoder([1, 2, 3])
        source, eos = self._ToyDecoder.SOURCE, {self._ToyDecoder.EOS}

        expected = backends.lookup_decode(greedy, source, eos, 100, draft=0)
        tokens = backends.lookup_decode(lookup, source, eos, 100)

        self.assertEqual(tokens, expected)
        self.assertEqual(len(expected), 25)
        self.assertIn(99, expected)
        self.assertLess(lookup.feeds, greedy.feeds)
        self.assertGreater(lookup.rollbacks, 0, "some guesses crossed an inserted 99")

    def test_lookup_decoding_stops_at_max_tokens(self):
        source, eos = self._ToyDecoder.SOURCE, {self._ToyDecoder.EOS}

        expected = backends.lookup_decode(self._ToyDecoder([1]), source, eos, 10, draft=0)
        tokens = backends.lookup_decode(self._ToyDecoder([1]), source, eos, 10)

        self.assertEqual(tokens, expected)
        self.assertEqual(len(tokens), 10)

    def test_lookup_decoding_stops_at_an_end_token_inside_a_guess(self):
        class EndsAtZero(self._ToyDecoder):
            SOURCE = [5, 6, 7, 8, 0, 9, 10, 11, 12, 13]

            def _pick(self):  # copies SOURCE, so the guess and the model both hit 0
                n = len(self.history) - self.prompt_len
                return self.SOURCE[n] if n < len(self.SOURCE) else 0

        source = [5, 6, 7, 8, 0, 9, 10]

        tokens = backends.lookup_decode(EndsAtZero([5, 6, 7]), source, {0}, 50)

        self.assertEqual(tokens, [5, 6, 7, 8])

    def test_lookup_draft_follows_the_latest_match(self):
        source = [1, 2, 3, 4, 1, 2, 3, 5, 6]

        self.assertEqual(backends.lookup_draft([9, 1, 2, 3], source, 8, 3), [5, 6])
        self.assertEqual(backends.lookup_draft([2, 3], source, 8, 3), [])
        self.assertEqual(backends.lookup_draft([1, 2, 3], source, 0, 3), [])

    def test_mlx_cleanup_decodes_with_lookup_from_the_dictation(self):
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.vocabulary = ()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.eos_token_ids = [self._ToyDecoder.EOS]
        decoders = []

        def make(_model, _prefix, _cache, prompt):
            decoders.append(self._ToyDecoder(prompt))
            return decoders[-1]

        source = self._ToyDecoder.SOURCE
        with (
            mock.patch.object(backends, "_MLXDecoder", make),
            mock.patch.object(cleaner, "_prefix", return_value=([], None)) as prefix,
        ):
            tokens, ttft = cleaner._decode([1, 2, 3], "casual", source, 100)

        self.assertEqual(tokens, backends.lookup_decode(self._ToyDecoder([1, 2, 3]), source, {0}, 100, draft=0))
        self.assertLess(decoders[0].feeds, len(tokens), "guessed tokens skipped model calls")
        self.assertGreaterEqual(ttft, 0)
        prefix.assert_called_once_with("casual")

    def test_mlx_cleanup_rebuilds_a_prefix_the_prompt_no_longer_starts_with(self):
        cleaner = object.__new__(backends.MLXCleanup)
        cleaner.model = object()
        cleaner.tokenizer = mock.Mock()
        cleaner.tokenizer.eos_token_ids = [self._ToyDecoder.EOS]
        cleaner._prefix_key = ("casual", ())
        built = []

        def prefix(mode):
            built.append(cleaner._prefix_key)
            cleaner._prefix_key = (mode, ())
            return ([7, 7], None) if len(built) == 1 else ([1, 2], None)

        with (
            mock.patch.object(backends, "_MLXDecoder", lambda _m, p, _c, prompt: self._ToyDecoder(prompt)),
            mock.patch.object(cleaner, "_prefix", side_effect=prefix),
        ):
            cleaner._decode([1, 2, 3], "casual", self._ToyDecoder.SOURCE, 10)

        self.assertEqual(built, [("casual", ()), None], "the stale key was dropped, then rebuilt")

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

    def test_dictionary_apply_rewrites_a_transcript_and_reports_what_fired(self):
        config.write_dictionary(
            ["Parakeet"], [("Alpha Kive", "alphaXiv"), ("Gorel", "org-rl")]
        )
        transcript = Path(self.tempdir.name) / "raw.txt"
        transcript.write_text("Look at the Alpha Kive post, then alpha kive again.\n")

        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.cmd_dictionary(["apply", str(transcript)])

        self.assertEqual(code, 0)
        self.assertEqual(
            out.getvalue(), "Look at the alphaXiv post, then alphaXiv again.\n"
        )
        self.assertEqual(
            err.getvalue(), "1 of 2 replacements fired: Alpha Kive => alphaXiv\n"
        )

    def test_dictionary_apply_reports_a_missing_file_instead_of_raising(self):
        config.write_dictionary([], [("a", "b")])

        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = cli.cmd_dictionary(["apply", "~/definitely-missing-transcript.txt"])

        self.assertEqual(code, 1)
        self.assertEqual(
            err.getvalue(),
            f"no such file: {Path.home() / 'definitely-missing-transcript.txt'}\n",
        )

    def test_dictionary_apply_reads_stdin_when_no_file_is_given(self):
        config.write_dictionary([], [("whisper flow", "Wispr Flow")])

        out = io.StringIO()
        with (
            mock.patch.object(sys, "stdin", io.StringIO("I use whisper flow daily")),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = cli.cmd_dictionary(["apply"])

        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), "I use Wispr Flow daily")

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
