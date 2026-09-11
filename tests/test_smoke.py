"""Small behavior checks for v2t's user-facing mechanics."""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import queue
import signal
import sqlite3
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.io import wavfile

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

    def _streaming_stt(
        self, feeds: list, partial: str = "so far", final: str = "final words"
    ):
        """An STT with Parakeet's streaming surface: stream() -> feed()/text/close()."""
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
        stream.closed = False
        return mock.Mock(
            streaming=True, sample_rate=16000, stream=mock.Mock(return_value=stream)
        ), stream

    def test_streaming_feeds_the_recording_while_held_and_finalises_on_release(self):
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
        self.assertEqual(
            feeds, [chunk, 8000], "one chunk while held, the remainder on release"
        )
        stream.finish.assert_called_once()  # the release push also flushes the tail
        self.assertEqual(stream.finish.call_args.args[0].size, 8000)
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

    def test_a_short_streamed_recording_is_decoded_whole_file_on_release(self):
        voice = app.VoiceToText(config.Config(cleanup_enabled=False))
        lock = config.acquire_instance_lock()
        self.addCleanup(lock.close)
        feeds: list[int] = []
        voice.stt, stream = self._streaming_stt(feeds)
        order: list[str] = []
        stream.close.side_effect = lambda: order.append("close") or "streamed words"
        voice.stt.transcribe = mock.Mock(
            side_effect=lambda path: order.append("whole") or "whole-file words"
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
        original_feed = stream.feed.side_effect

        def feed(chunk):
            if feeds:  # the final push, the remainder flushed on release
                raise RuntimeError("metal out of memory")
            return original_feed(chunk)

        stream.feed.side_effect = feed
        voice.stt.transcribe = mock.Mock(return_value="whole-file words")
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

        self.assertEqual(feeds, [chunk], "the flush raised")
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
        voice.stt.transcribe = mock.Mock(return_value="whole-file words")
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

        self.assertGreater(live["loud_frac"], 0.9)
        self.assertEqual(app.level_warning(live, 3.0, "Mic"), "")
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
            app._notify('v2t: "check"', 'peak 1.00 from "LABLABLA"')

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

        record = config.read_history()[-1]
        self.assertEqual(
            record,
            {
                "id": record["id"],
                "ts": record["ts"],
                "trigger": "file",
                "source": str(path),
                "audio_s": 10.0,
                "backend": "parakeet",
                "model": backends.PARAKEET_DEFAULT,
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
