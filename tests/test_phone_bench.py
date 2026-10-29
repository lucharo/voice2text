"""The Mac side of the iPhone bench: job checks, item counts, result copies that only grow, progress and ETA."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "utils/phone_bench"))
import phone_common as pc
import phone_sync

JOB = {"name": "j", "set": "cleanup", "block": 2, "arms": [
    {"id": "a", "runtime": "anemll", "model": "m1"}, {"id": "b", "runtime": "mlx", "model": "m2"}]}


def write(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


class LoadJob(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def load(self, job: dict) -> dict:
        p = Path(self.dir.name) / "job.json"
        p.write_text(json.dumps(job))
        return pc.load_job(p)

    def test_valid_job_loads_unchanged(self):
        self.assertEqual(self.load(JOB), JOB)

    def test_every_problem_is_reported_at_once(self):
        bad = {**JOB, "block": 0, "offset": -1, "order": "random", "arms": [
            {"id": "a", "runtime": "parakeet-coreml"}, {"id": "a", "runtime": "mlx"}, {"id": "log", "runtime": "tpu"}]}
        with self.assertRaises(SystemExit) as e:
            self.load(bad)
        want = [
            "block must be a positive integer",
            "offset must be an integer >= 0",
            "order must be one of ('abba', 'alternate', 'sequential')",
            "arms need unique ids",
            "arm id log is reserved for the job log",
            "arm a: runtime parakeet-coreml runs on the speech set, not cleanup",
            "arm a: runtime mlx needs a model",
            "arm log: unknown runtime 'tpu'",
        ]
        self.assertEqual(str(e.exception).split(": ", 1)[1].split("; "), want)


class ItemCount(unittest.TestCase):
    def test_offset_limit_and_rounds_match_the_app(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "clips").mkdir()
            (Path(d) / "clips/manifest.tsv").write_text("".join(f"x/{i}\tx{i}.wav\t1.0\n" for i in range(10)))
            job = {**JOB, "set": "speech", "offset": 7, "limit": 5, "rounds": 3}
            self.assertEqual(pc.item_count(job, Path(d)), 9)  # 3 items left after offset 7, 3 rounds

    def test_unstaged_resources_give_none(self):
        self.assertIsNone(pc.item_count(JOB, Path("/nonexistent")))


class CopyFrom(unittest.TestCase):
    """devicectl is the external dependency; it is replaced by a stand-in that writes the phone's copy."""

    def run_copy(self, phone: bytes | None, local: bytes | None) -> tuple[str, bytes, dict[str, bytes]]:
        """Returns what copy_from reported, the local file after, and any diverged copies kept beside it."""
        with tempfile.TemporaryDirectory() as d:
            dest = Path(d) / "r.jsonl"
            if local is not None:
                dest.write_bytes(local)

            def fake(*args, timeout=0):
                if phone is None:
                    return subprocess.CompletedProcess(args, 1, "", "no such file")
                Path(args[args.index("--destination") + 1]).write_bytes(phone)
                return subprocess.CompletedProcess(args, 0, "", "")

            with mock.patch.object(pc, "devicectl", fake):
                what = pc.copy_from("udid", "r.jsonl", dest)
            beside = {p.name.split(".diverged-")[0]: p.read_bytes() for p in Path(d).glob("r.diverged-*.jsonl")}
            return what, dest.read_bytes() if dest.exists() else b"", beside

    def test_phone_copy_extending_local_replaces_it(self):
        self.assertEqual(self.run_copy(b"1\n2\n", b"1\n"), ("copied", b"1\n2\n", {}))

    def test_identical_copy_is_unchanged(self):
        self.assertEqual(self.run_copy(b"1\n", b"1\n"), ("unchanged", b"1\n", {}))

    def test_diverging_phone_copy_is_kept_beside_local(self):
        # a restarted job as long as the old one: neither copy may be lost
        self.assertEqual(self.run_copy(b"9\n9\n", b"1\n2\n"), ("diverged", b"1\n2\n", {"r": b"9\n9\n"}))

    def test_missing_on_phone_leaves_nothing_behind(self):
        self.assertEqual(self.run_copy(None, None), ("absent", b"", {}))


class ReadRows(unittest.TestCase):
    def test_row_cut_mid_character_is_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            p.write_bytes(b'{"id": "a"}\n' + '{"clean": "caf\u00e9"}'.encode()[:-3])
            self.assertEqual(pc.read_rows(p), [{"id": "a"}])


class Progress(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.out = Path(self.dir.name)

    def test_counts_rate_eta_and_state(self):
        t0 = 1_000_000.0
        write(self.out / "j.log.jsonl", [
            {"event": "start", "items": 10, "t": t0},
            {"event": "block_start", "arm": "a", "block": 1, "i": 2, "of": 10, "t": t0 + 1},
            {"event": "app", "state": "background", "t": t0 + 2}])
        # arm a: 6 items a minute apart, one repeated after a relaunch and one cut short mid-write
        write(self.out / "j.a.jsonl", [{"event": "clean", "id": f"i{k}", "t": t0 + 60 * k} for k in range(6)]
              + [{"event": "clean", "id": "i5", "t": t0 + 300, "errors": ["boom"], "thermal": 1, "battery": 0.5, "charging": False}])
        with open(self.out / "j.a.jsonl", "a") as f:
            f.write('{"event": "clean", "id": "i6", "t"')
        s = phone_sync.progress(JOB, self.out, t0 + 400)
        self.assertEqual(s, {
            "job": "j", "at": t0 + 400, "done": 6, "total": 20, "ended": False,
            "arms": {"a": {"done": 6, "errors": 1}, "b": {"done": 0, "errors": 0}},
            "per_min": 1.0, "eta": t0 + 300 + 14 * 60,
            "last_row": {"event": "clean", "t": t0 + 300, "thermal": 1, "battery": 0.5, "charging": False},
            "block": {"arm": "a", "block": 1, "i": 2, "of": 10},
            "app_state": "background"})

    def test_end_after_the_latest_start_marks_the_job_ended(self):
        write(self.out / "j.log.jsonl", [{"event": "start", "items": 1, "t": 1}, {"event": "end", "t": 2}])
        self.assertTrue(phone_sync.progress(JOB, self.out, 3)["ended"])

    def test_end_from_an_earlier_launch_does_not_count(self):
        write(self.out / "j.log.jsonl", [{"event": "start", "t": 1}, {"event": "end", "t": 2}, {"event": "start", "t": 3}])
        self.assertFalse(phone_sync.progress(JOB, self.out, 4)["ended"])


class Finished(unittest.TestCase):
    def test_watch_stops_only_with_the_end_row_and_every_result_here(self):
        cases = [(True, 20, 20), (True, 19, 20), (False, 20, 20), (True, 20, None)]
        got = [phone_sync.finished({"ended": e, "done": d, "total": t}) for e, d, t in cases]
        self.assertEqual(got, [True, False, False, False])


if __name__ == "__main__":
    unittest.main()
