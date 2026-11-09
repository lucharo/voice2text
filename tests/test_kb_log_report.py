"""ios/tools/kb_log_report.py on a hand-written log with one of each thing it counts."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("kb_log_report", Path(__file__).resolve().parents[1] / "ios/tools/kb_log_report.py")
rep = importlib.util.module_from_spec(spec)
sys.modules["kb_log_report"] = rep  # dataclasses look their module up
spec.loader.exec_module(rep)


def typed(t, word):
    """A word typed key by key, as the keyboard logs it: key then ins per letter."""
    out = []
    for ch in word:
        out += [{"t": t, "e": "down", "n": 1, "key": f"letters-{ch}", "fingers": 1},
                {"t": t + 40, "e": "up", "n": 1, "verdict": "tap", "ms": 40},
                {"t": t + 40, "e": "key", "text": ch}, {"t": t + 41, "e": "ins", "text": ch}]
        t += 150
    return out, t


class ReportTests(unittest.TestCase):
    def events(self):
        ev = [{"t": 0, "e": "appear"}, {"t": 1, "e": "host", "kind": "text", "before": ""}]
        # "teh " autocorrected to "The ", delete, original picked back
        e, t = typed(10, "teh")
        ev += e
        ev += [{"t": t, "e": "act", "a": "space"}, {"t": t, "e": "autocorrect", "from": "teh", "to": "The"},
               {"t": t, "e": "del"}, {"t": t, "e": "del"}, {"t": t, "e": "del"}, {"t": t, "e": "ins", "text": "The"}, {"t": t, "e": "ins", "text": " "},
               {"t": t + 300, "e": "act", "a": "delete"}, {"t": t + 300, "e": "revert-offer", "from": "teh", "to": "The"}, {"t": t + 300, "e": "del"},
               {"t": t + 600, "e": "bar", "words": ["teh", "the"], "kinds": ["typed", "correction"], "bold": None},
               {"t": t + 700, "e": "pick", "slot": 0, "word": "teh", "emoji": False},
               {"t": t + 700, "e": "revert", "from": "teh", "to": "The", "how": "bar"}]
        for _ in "The":
            ev.append({"t": t + 700, "e": "del"})
        ev += [{"t": t + 700, "e": "ins", "text": "teh "}]
        # "form " finished, deleted, retyped as "from "
        e, t = typed(t + 1000, "form")
        ev += e
        ev.append({"t": t, "e": "ins", "text": " "})
        ev += [{"t": t + 100 + i, "e": "del"} for i in range(5)]
        e, t = typed(t + 400, "from")
        ev += e
        ev.append({"t": t, "e": "ins", "text": " "})
        # a swipe 200 ms after a tap, deleted at once: a likely misread
        ev += [{"t": t + 300, "e": "up", "n": 9, "verdict": "swipe", "ms": 100},
               {"t": t + 301, "e": "swipe", "candidates": [{"w": "to", "s": -1.5}, {"w": "too", "s": -3}], "applied": True},
               {"t": t + 302, "e": "ins", "text": "to"}, {"t": t + 302, "e": "swiped", "word": "to", "alternatives": ["too"]},
               {"t": t + 900, "e": "del"}, {"t": t + 900, "e": "del"}]
        # a deliberate swipe, kept, then a middle-slot pick, an emoji pick, and a rollover
        ev += [{"t": t + 2000, "e": "up", "n": 10, "verdict": "swipe", "ms": 600},
               {"t": t + 2001, "e": "swipe", "candidates": [{"w": "hello", "s": -0.5}], "applied": True},
               {"t": t + 2002, "e": "ins", "text": "hello"}, {"t": t + 2002, "e": "swiped", "word": "hello", "alternatives": []},
               {"t": t + 2500, "e": "ins", "text": " "},
               {"t": t + 2600, "e": "bar", "words": ["a", "the", "😀"], "kinds": ["prediction", "prediction", "emoji"], "bold": None},
               {"t": t + 2700, "e": "pick", "slot": 1, "word": "the", "emoji": False},
               {"t": t + 2800, "e": "pick", "slot": 2, "word": "😀", "emoji": True},
               {"t": t + 2900, "e": "down", "n": 11, "fingers": 1}, {"t": t + 2950, "e": "down", "n": 12, "fingers": 2},
               {"t": t + 3000, "e": "rollover", "n": 11, "by": 12},
               {"t": t + 3100, "e": "dictation", "chars": 12, "words": 2}, {"t": t + 3100, "e": "ins", "chars": 12},
               {"t": t + 3200, "e": "skip", "reason": "password"}]
        return ev

    def test_counts(self):
        r = rep.analyse(self.events())
        self.assertEqual(r.corrections, 1)
        self.assertEqual(dict(r.corrections_reverted), {"bar": 1})
        self.assertEqual(r.misses, [("form", "from")])
        self.assertEqual([s.outcome for s in r.swipes], ["deleted", "kept"])
        self.assertEqual([s.word for s in rep.misreads(r)], ["to"])
        self.assertEqual(dict(r.picks), {"left": 1, "middle": 1, "right": 1})
        self.assertEqual((r.picks_as_typed, r.picks_emoji), (1, 1))
        self.assertEqual((r.rollovers, r.multi_finger_downs), (1, 1))
        self.assertEqual(dict(r.skipped_fields), {"password": 1})
        self.assertEqual(r.keys, 12)
        self.assertEqual(len(r.kps), 1)  # no gap over 2 s

    def test_correction_deleted_and_typed_again_is_retyped_not_a_miss(self):
        ev = [{"t": 0, "e": "host", "before": ""}, {"t": 1, "e": "autocorrect", "from": "marimo", "to": "merino"},
              {"t": 1, "e": "ins", "text": "merino "}] + [{"t": 2, "e": "del"}] * 7 + [{"t": 3, "e": "ins", "text": "marimo "}]
        r = rep.analyse(ev)
        self.assertEqual((dict(r.corrections_reverted), r.misses), ({"retyped": 1}, []))

    def test_trackpad_move_left_then_retype_is_the_right_word(self):
        # "form word ", cursor back over " word " (6), delete "form" and type "from": a miss of form, not of word
        ev = [{"t": 0, "e": "host", "before": ""}, {"t": 1, "e": "ins", "text": "form word "}, {"t": 2, "e": "cursor", "by": -6}]
        ev += [{"t": 3, "e": "del"}] * 4 + [{"t": 4, "e": "ins", "text": "from "}]
        self.assertEqual(rep.analyse(ev).misses, [("form", "from")])

    def test_deleting_a_joined_emoji_takes_it_whole(self):
        ev = [{"t": 0, "e": "host", "before": ""}, {"t": 1, "e": "ins", "text": "form 👩🏽‍💻"}]
        ev += [{"t": 2, "e": "del"}] * 6 + [{"t": 3, "e": "ins", "text": "from "}]  # the emoji, space and "form"
        self.assertEqual(rep.analyse(ev).misses, [("form", "from")])

    def test_shift_between_offer_and_pick_is_one_revert(self):
        ev = [{"t": 0, "e": "autocorrect", "from": "teh", "to": "The"},
              {"t": 1, "e": "act", "a": "delete"}, {"t": 1, "e": "revert-offer", "from": "teh", "to": "The"},
              {"t": 2, "e": "act", "a": "shift"}, {"t": 3, "e": "pick", "slot": 0, "word": "teh"},
              {"t": 3, "e": "revert", "from": "teh", "to": "The", "how": "bar"}]
        self.assertEqual(dict(rep.analyse(ev).corrections_reverted), {"bar": 1})

    def test_deleting_a_full_stop_after_a_swipe_keeps_the_swipe(self):
        ev = [{"t": 0, "e": "host", "before": ""}, {"t": 1, "e": "swipe", "candidates": [{"w": "hello", "s": 0}], "applied": True},
              {"t": 2, "e": "ins", "text": "hello"}, {"t": 2, "e": "swiped", "word": "hello", "alternatives": []},
              {"t": 3, "e": "ins", "text": "."}, {"t": 4, "e": "del"}]
        self.assertEqual([s.outcome for s in rep.analyse(ev).swipes], ["kept"])

    def test_two_swipes_before_the_first_decode_keep_their_own_timings(self):
        ev = [{"t": 0, "e": "up", "verdict": "swipe", "ms": 500}, {"t": 600, "e": "up", "verdict": "swipe", "ms": 100},
              {"t": 700, "e": "swipe", "candidates": [{"w": "a", "s": 0}], "applied": False},
              {"t": 800, "e": "swipe", "candidates": [{"w": "b", "s": 0}], "applied": False}]
        self.assertEqual([s.ms for s in rep.analyse(ev).swipes], [500, 100])

    def test_a_phone_restart_splits_the_clock(self):
        keys = lambda t0: [{"t": t0 + 200 * i, "e": "key", "text": "a"} for i in range(6)]  # noqa: E731
        r = rep.analyse(keys(5_000_000) + keys(1_000))
        self.assertEqual(len(r.kps), 2)
        self.assertTrue(all(k > 0 for k in r.kps))
        self.assertAlmostEqual(r.span_s, 2.0)

    def test_a_typed_line_separator_and_a_torn_character(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "keyboard.jsonl").write_bytes('{"t":1,"e":"key","text":"\u2028"}\n'.encode() + b'{"t":2,"e":"key","text":"\xc3')
            self.assertEqual([e["text"] for e in rep.read_events(Path(d))], ["\u2028"])

    def test_offer_left_then_original_retyped_is_one_taking_back(self):
        ev = [{"t": 0, "e": "host", "before": ""}, {"t": 1, "e": "autocorrect", "from": "teh", "to": "The"},
              {"t": 1, "e": "ins", "text": "The "}, {"t": 2, "e": "act", "a": "delete"},
              {"t": 2, "e": "revert-offer", "from": "teh", "to": "The"}, {"t": 2, "e": "del"}]
        ev += [{"t": 3, "e": "act", "a": "delete"}, {"t": 3, "e": "del"}] * 3 + [{"t": 4, "e": "key", "text": "T"}, {"t": 4, "e": "ins", "text": "Teh "}]
        r = rep.analyse(ev)
        self.assertEqual((dict(r.corrections_reverted), r.misses), ({"retyped": 1}, []))

    def test_a_swipe_in_emoji_search_does_not_shift_the_next_swipes_timing(self):
        ev = [{"t": 0, "e": "up", "verdict": "swipe", "ms": 90}, {"t": 1, "e": "swipe", "ignored": "emoji search"},
              {"t": 900, "e": "up", "verdict": "swipe", "ms": 700},
              {"t": 1000, "e": "swipe", "candidates": [{"w": "b", "s": 0}], "applied": False}]
        self.assertEqual([s.ms for s in rep.analyse(ev).swipes], [700])

    def test_offer_left_alone_counts_as_not_taken(self):
        ev = [{"t": 0, "e": "autocorrect", "from": "fo", "to": "for"},
              {"t": 1, "e": "act", "a": "delete"}, {"t": 1, "e": "revert-offer", "from": "fo", "to": "for"},
              {"t": 2, "e": "key", "text": "m"}]
        self.assertEqual(dict(rep.analyse(ev).corrections_reverted), {"offered, left": 1})

    def test_reads_a_folder_oldest_file_first_and_skips_a_torn_line(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "keyboard.1.jsonl").write_text('{"t":1,"e":"key","text":"a"}\n')
            Path(d, "keyboard.jsonl").write_text('{"t":2,"e":"key","text":"b"}\n{"t":3,"e":"ke')
            self.assertEqual([e["text"] for e in rep.read_events(Path(d))], ["a", "b"])

    def test_text_and_json_reports_run(self):
        r = rep.analyse(self.events())
        self.assertIn("likely taps read as a swipe: 1", rep.text_report(r))
        self.assertEqual(json.loads(json.dumps(rep.json_report(r)))["tap_vs_swipe"]["likely_misreads"], 1)


if __name__ == "__main__":
    unittest.main()
