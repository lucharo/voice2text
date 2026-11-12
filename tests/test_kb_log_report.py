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
        ev = [{"t": 0, "e": "appear"}, {"t": 1, "e": "host", "kind": "text", "chars": 0}]
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
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "autocorrect", "from": "marimo", "to": "merino"},
              {"t": 1, "e": "ins", "text": "merino "}] + [{"t": 2, "e": "del"}] * 7 + [{"t": 3, "e": "ins", "text": "marimo "}]
        r = rep.analyse(ev)
        self.assertEqual((dict(r.corrections_reverted), r.misses), ({"retyped": 1}, []))

    def test_trackpad_move_left_then_retype_is_the_right_word(self):
        # "form word ", cursor back over " word " (6), delete "form" and type "from": a miss of form, not of word
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "ins", "text": "form word "}, {"t": 2, "e": "cursor", "by": -6}]
        ev += [{"t": 3, "e": "del"}] * 4 + [{"t": 4, "e": "ins", "text": "from "}]
        self.assertEqual(rep.analyse(ev).misses, [("form", "from")])

    def test_deleting_a_joined_emoji_takes_it_whole(self):
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "ins", "text": "form 👩🏽‍💻"}]
        ev += [{"t": 2, "e": "del"}] * 6 + [{"t": 3, "e": "ins", "text": "from "}]  # the emoji, space and "form"
        self.assertEqual(rep.analyse(ev).misses, [("form", "from")])

    def test_deleting_a_tag_flag_takes_it_whole(self):
        flag = "\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f"  # England
        self.assertEqual(rep.drop_last_character("a " + flag), "a ")

    def test_shift_between_offer_and_pick_is_one_revert(self):
        ev = [{"t": 0, "e": "autocorrect", "from": "teh", "to": "The"},
              {"t": 1, "e": "act", "a": "delete"}, {"t": 1, "e": "revert-offer", "from": "teh", "to": "The"},
              {"t": 2, "e": "act", "a": "shift"}, {"t": 3, "e": "pick", "slot": 0, "word": "teh"},
              {"t": 3, "e": "revert", "from": "teh", "to": "The", "how": "bar"}]
        self.assertEqual(dict(rep.analyse(ev).corrections_reverted), {"bar": 1})

    def test_deleting_a_full_stop_after_a_swipe_keeps_the_swipe(self):
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "swipe", "candidates": [{"w": "hello", "s": 0}], "applied": True},
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

    def test_a_restart_forgets_the_last_tap_and_waiting_lifts(self):
        ev = [{"t": 9_000_000, "e": "up", "verdict": "tap", "ms": 40}, {"t": 9_000_100, "e": "up", "verdict": "swipe", "ms": 50},
              {"t": 1_000, "e": "up", "verdict": "swipe", "ms": 600},
              {"t": 1_100, "e": "swipe", "candidates": [{"w": "a", "s": 0}], "applied": False}]
        s = rep.analyse(ev).swipes
        self.assertEqual((s[0].ms, s[0].after_tap_ms), (600, None))

    def test_a_typed_line_separator_and_a_torn_character(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "keyboard.jsonl").write_bytes('{"t":1,"e":"key","text":"\u2028"}\n'.encode() + b'{"t":2,"e":"key","text":"\xc3')
            self.assertEqual([e["text"] for e in rep.read_events(Path(d))], ["\u2028"])

    def test_offer_left_then_original_retyped_is_one_taking_back(self):
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "autocorrect", "from": "teh", "to": "The"},
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

    def test_a_later_independent_change_after_a_bar_revert_is_a_miss(self):
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "autocorrect", "from": "teh", "to": "The"}, {"t": 1, "e": "ins", "text": "The "},
              {"t": 2, "e": "revert", "from": "teh", "to": "The", "how": "bar"}] + [{"t": 2, "e": "del"}] * 4 + [{"t": 2, "e": "ins", "text": "teh "}]
        ev += [{"t": 3, "e": "ins", "text": "The "}] + [{"t": 4, "e": "del"}] * 4 + [{"t": 5, "e": "ins", "text": "Teh "}]
        r = rep.analyse(ev)
        self.assertEqual((dict(r.corrections_reverted), r.misses), ({"bar": 1}, [("The", "Teh")]))

    def test_a_skip_drops_lifts_whose_decode_went_unrecorded(self):
        ev = [{"t": 0, "e": "up", "verdict": "swipe", "ms": 90}, {"t": 1, "e": "skip", "reason": "card"}, {"t": 2, "e": "resume"},
              {"t": 900, "e": "up", "verdict": "swipe", "ms": 700}, {"t": 1000, "e": "swipe", "candidates": [{"w": "b", "s": 0}], "applied": False}]
        self.assertEqual([s.ms for s in rep.analyse(ev).swipes], [700])

    def test_an_empty_swipe_leaves_the_last_swipe_open(self):
        ev = [{"t": 0, "e": "host", "chars": 0}, {"t": 1, "e": "swipe", "candidates": [{"w": "hello", "s": 0}], "applied": True},
              {"t": 2, "e": "ins", "text": "hello"}, {"t": 2, "e": "swiped", "word": "hello", "alternatives": []},
              {"t": 3, "e": "swipe", "candidates": [], "applied": False}, {"t": 4, "e": "del"}]
        self.assertEqual([s.outcome for s in rep.analyse(ev).swipes], ["deleted", "empty"])

    def test_offer_left_alone_counts_as_not_taken(self):
        ev = [{"t": 0, "e": "autocorrect", "from": "fo", "to": "for"},
              {"t": 1, "e": "act", "a": "delete"}, {"t": 1, "e": "revert-offer", "from": "fo", "to": "for"},
              {"t": 2, "e": "key", "text": "m"}]
        self.assertEqual(dict(rep.analyse(ev).corrections_reverted), {"offered, left": 1})

    def test_touches_near_a_screen_edge_are_timed_apart_from_the_rest(self):
        # a 402 pt keyboard: "a" at x 25 and delete at x 380 are within 30 pt of an edge, "t" and a delete at x 365 are not
        ev = [{"t": 0, "e": "appear", "width": 402},
              {"t": 100, "e": "down", "n": 1, "key": "letters-t", "p": [170, 30], "fingers": 1},
              {"t": 160, "e": "up", "n": 1, "key": "letters-t", "p": [170, 30], "verdict": "tap", "ms": 60},
              {"t": 180, "e": "key", "text": "t"},
              {"t": 300, "e": "down", "n": 2, "key": "letters-a", "p": [25, 80], "fingers": 1},
              {"t": 360, "e": "up", "n": 2, "key": "letters-a", "p": [25, 80], "verdict": "tap", "ms": 60},
              {"t": 398, "e": "key", "text": "a"},
              {"t": 500, "e": "down", "n": 3, "key": "delete", "p": [365, 130], "fingers": 1},
              {"t": 519, "e": "act", "a": "delete"},
              {"t": 560, "e": "up", "n": 3, "key": "delete", "p": [365, 130], "verdict": "tap", "ms": 60},
              # held near the edge: the first delete is timed, its repeats are not
              {"t": 700, "e": "down", "n": 4, "key": "delete", "p": [380, 130], "fingers": 1},
              {"t": 796, "e": "act", "a": "delete"}, {"t": 900, "e": "act", "a": "delete"},
              {"t": 950, "e": "up", "n": 4, "key": "delete", "p": [380, 130], "verdict": "tap", "ms": 250},
              # space is not a character key
              {"t": 1000, "e": "down", "n": 5, "key": "space", "p": [240, 190], "fingers": 1},
              {"t": 1060, "e": "up", "n": 5, "key": "space", "p": [240, 190], "verdict": "tap", "ms": 60},
              {"t": 1080, "e": "act", "a": "space"}]
        r = rep.analyse(ev)
        self.assertEqual(r.key_delivery, {"edge": [38], "middle": [20]})
        self.assertEqual(r.delete_delivery, {"edge": [96], "middle": [19]})
        self.assertEqual(rep.json_report(r)["touch_delivery_ms"],
                         {"keys": {"middle": {"median": 20, "n": 1}, "edge": {"median": 38, "n": 1}},
                          "delete": {"middle": {"median": 19, "n": 1}, "edge": {"median": 96, "n": 1}}})
        self.assertIn("delete, touch to delete: elsewhere median 19 ms (1), within 30 pt of a screen edge median 96 ms (1)", rep.text_report(r))

    def test_keys_typed_by_a_rollover_are_not_timed(self):
        # finger 2 lifts first: its lift types finger 1's "t" (the rollover), then its own "h"
        for order in (("rollover", "up"), ("up", "rollover")):
            lines = {"rollover": {"t": 150, "e": "rollover", "n": 1, "key": "letters-t", "p": [170, 30], "by": 2},
                     "up": {"t": 150, "e": "up", "n": 2, "key": "letters-h", "p": [240, 90], "verdict": "tap", "ms": 30}}
            ev = [{"t": 0, "e": "appear", "width": 402},
                  {"t": 100, "e": "down", "n": 1, "key": "letters-t", "p": [170, 30], "fingers": 1},
                  {"t": 120, "e": "down", "n": 2, "key": "letters-h", "p": [240, 90], "fingers": 2},
                  lines[order[0]], lines[order[1]],
                  {"t": 170, "e": "key", "text": "t"}, {"t": 185, "e": "key", "text": "h"},
                  {"t": 300, "e": "up", "n": 1, "key": "letters-t", "p": [170, 30], "verdict": "rolled", "ms": 200},
                  # the next plain tap is timed again
                  {"t": 400, "e": "down", "n": 3, "key": "letters-e", "p": [95, 40], "fingers": 1},
                  {"t": 460, "e": "up", "n": 3, "key": "letters-e", "p": [95, 40], "verdict": "tap", "ms": 60},
                  {"t": 481, "e": "key", "text": "e"}]
            self.assertEqual(rep.analyse(ev).key_delivery, {"edge": [], "middle": [21]}, order)

    def test_touches_are_not_timed_without_the_keyboards_width(self):
        ev = [{"t": 300, "e": "down", "n": 2, "key": "letters-a", "p": [25, 80], "fingers": 1},
              {"t": 360, "e": "up", "n": 2, "key": "letters-a", "p": [25, 80], "verdict": "tap", "ms": 60},
              {"t": 398, "e": "key", "text": "a"}]
        r = rep.analyse(ev)
        self.assertEqual((r.key_delivery, r.delete_delivery), ({"edge": [], "middle": []}, {"edge": [], "middle": []}))
        self.assertNotIn("Touch delivery", rep.text_report(r))

    def test_bar_time_is_from_a_character_key_to_its_bar(self):
        ev = [{"t": 0, "e": "appear", "width": 402},
              {"t": 100, "e": "key", "text": "t"}, {"t": 100, "e": "ins", "text": "t"},
              {"t": 103, "e": "bar", "words": ["t", "the", "to"], "kinds": ["typed", "completion", "completion"], "bold": None},
              {"t": 200, "e": "key", "text": "h"}, {"t": 200, "e": "ins", "text": "h"},
              {"t": 212, "e": "bar", "words": ["th", "the", "this"], "kinds": ["typed", "completion", "completion"], "bold": None},
              # a bar that follows a space, not a character key, is not timed
              {"t": 300, "e": "act", "a": "space"}, {"t": 300, "e": "ins", "text": " "},
              {"t": 340, "e": "bar", "words": ["a", "the", "my"], "kinds": ["prediction"] * 3, "bold": None}]
        r = rep.analyse(ev)
        self.assertEqual(r.bar_ms, [3, 12])
        self.assertEqual(rep.json_report(r)["bar_ms"], {"median": 7.5, "p95": 3, "over_frame": 1, "n": 2})
        self.assertIn("over 8 ms 1 of 2 (50%)", rep.text_report(r))

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
