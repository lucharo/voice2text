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

    def test_a_bar_after_a_delete_is_not_timed_as_the_last_characters(self):
        # two full stops leave the bar as it was (no bar line); the delete that follows brings predictions back
        ev = [{"t": 0, "e": "appear", "width": 402},
              {"t": 100, "e": "key", "text": "."}, {"t": 100, "e": "ins", "text": "."},
              {"t": 250, "e": "act", "a": "delete"}, {"t": 250, "e": "del"},
              {"t": 252, "e": "bar", "words": ["a", "the", "my"], "kinds": ["prediction"] * 3, "bold": None}]
        self.assertEqual(rep.analyse(ev).bar_ms, [])

    def test_reads_a_folder_oldest_file_first_and_skips_a_torn_line(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "keyboard.1.jsonl").write_text('{"t":1,"e":"key","text":"a"}\n')
            Path(d, "keyboard.jsonl").write_text('{"t":2,"e":"key","text":"b"}\n{"t":3,"e":"ke')
            self.assertEqual([e["text"] for e in rep.read_events(Path(d))], ["a", "b"])

    def test_text_and_json_reports_run(self):
        r = rep.analyse(self.events())
        self.assertIn("likely taps read as a swipe: 1", rep.text_report(r))
        self.assertEqual(json.loads(json.dumps(rep.json_report(r)))["tap_vs_swipe"]["likely_misreads"], 1)


# the iPhone keyboard 402 pt wide (Layout.swift, checked against KeyboardLayout on 12 Nov 2026): letter keys
# 34.2 pt wide, centres as printed by KeyboardLayout(width: 402)
CENTRES = {"q": (20.1, 29), "a": (40.2, 83), "h": (241.2, 83), "g": (201.0, 83), "t": (180.9, 29), "e": (100.5, 29)}
APPEAR = {"t": 0, "e": "appear", "width": 402, "form": "phone", "layout": "en", "wall": "2026-11-12T10:00:00Z"}


def exercise(t, end, target, typed, wall="2026-11-12T10:00:10Z"):
    return {"t": t, "e": "exercise", "end": end, "wall": wall, "id": "en-01", "target": target, "typed": typed}


def tapped(t, word, at=None, n0=1):
    """A word tapped key by key: down where the finger landed (`at`: letter -> point, else the key's centre),
    the tap, the key and its insertion."""
    out = []
    for i, ch in enumerate(word):
        p = list((at or {}).get(i, CENTRES.get(ch.lower(), (200, 100))))
        out += [{"t": t, "e": "down", "n": n0 + i, "key": f"letters-{ch.lower()}", "p": p, "fingers": 1},
                {"t": t + 40, "e": "up", "n": n0 + i, "key": f"letters-{ch.lower()}", "p": [p[0] + 1, p[1] + 1], "verdict": "tap", "ms": 40},
                {"t": t + 41, "e": "key", "text": ch, "p": [p[0] + 1, p[1] + 1]}, {"t": t + 42, "e": "ins", "text": ch}]
        t += 150
    return out, t


def space(t):
    return [{"t": t, "e": "act", "a": "space"}, {"t": t + 1, "e": "ins", "text": " "}]


class ExerciseTests(unittest.TestCase):
    def test_words_that_ended_up_different_are_listed_target_then_typed(self):
        x = rep.analyse([exercise(0, 1, "She's back from Lisbon.", "She’s back form lisbon")]).exercises
        self.assertEqual((x.sentences, x.words, x.wrong), (1, 4, [("from", "form"), ("Lisbon", "lisbon")]))

    def test_a_sentence_with_a_word_missing_is_one_pair(self):
        x = rep.analyse([exercise(0, 1, "Sit by the window.", "Sit bythe window")]).exercises
        self.assertEqual(x.wrong, [("Sit by the window.", "Sit bythe window")])

    def test_autocorrections_are_placed_on_the_sentences_words(self):
        ev = [APPEAR, {"t": 900, "e": "host", "kind": "text", "chars": 0}]
        # as the keyboard logs a correction: the space, the word replaced, the autocorrect line, then the space put in
        e, t = tapped(1000, "teh")
        ev += e + [{"t": t, "e": "act", "a": "space"}] + [{"t": t, "e": "del"}] * 3 + [{"t": t, "e": "ins", "text": "the"},
                                                                                     {"t": t, "e": "autocorrect", "from": "teh", "to": "the"}, {"t": t, "e": "ins", "text": " "}]
        e, t = tapped(t + 100, "fox")
        ev += e + [{"t": t, "e": "act", "a": "space"}] + [{"t": t, "e": "del"}] * 3 + [{"t": t, "e": "ins", "text": "for"},
                                                                                     {"t": t, "e": "autocorrect", "from": "fox", "to": "for"}, {"t": t, "e": "ins", "text": " "}]
        x = rep.analyse(ev + [exercise(950, t + 500, "the fox", "the for ")]).exercises
        self.assertEqual(dict(x.corrections), {"to target": 1, "other word": 1})

    def test_an_autocorrection_after_the_cursor_moved_is_not_placed(self):
        ev = [APPEAR, {"t": 900, "e": "host", "kind": "text", "chars": 0}, {"t": 950, "e": "cursor", "by": -1}]
        e, t = tapped(1000, "teh")
        ev += e + [{"t": t, "e": "act", "a": "space"}, {"t": t, "e": "autocorrect", "from": "teh", "to": "the"}]
        x = rep.analyse(ev + [exercise(900, t + 500, "the", "the ")]).exercises
        self.assertEqual(dict(x.corrections), {"not placed": 1})

    def test_events_after_the_sentences_time_are_left_out(self):
        ev = [APPEAR]
        e, t = tapped(100, "teh")
        ev += e + [{"t": t, "e": "act", "a": "space"}, {"t": t, "e": "autocorrect", "from": "teh", "to": "the"}]
        x = rep.analyse(ev + [exercise(10, 50, "the", "the")]).exercises
        self.assertEqual((dict(x.corrections), dict(x.offsets)), ({}, {}))

    def test_taps_on_the_right_letter_give_the_offset_from_the_keys_centre_in_key_widths(self):
        # "hat": h landed 17.1 pt right of its centre (half a key) and 6.84 pt up; a and t on their centres
        e, t = tapped(1000, "hat", at={0: (241.2 + 17.1, 83 - 6.84)})
        x = rep.analyse([APPEAR] + e + space(t) + [exercise(900, t + 500, "hat", "hat ")]).exercises
        got = {k: [(round(dx, 6), round(dy, 6)) for dx, dy in v] for k, v in x.offsets.items()}
        self.assertEqual(got, {"h": [(0.5, -0.2)], "a": [(0, 0)], "t": [(0, 0)]})

    def test_a_tap_that_typed_another_letter_is_counted_by_meant_and_hit(self):
        e, t = tapped(1000, "tge")
        x = rep.analyse([APPEAR] + e + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        self.assertEqual((dict(x.hits), sorted(x.offsets)), ({("h", "g"): 1}, ["e", "t"]))

    def test_a_word_with_a_delete_gives_no_offsets_or_hits(self):
        e, t = tapped(1000, "tg")
        e2, t = tapped(t + 200, "he", n0=10)
        ev = [APPEAR] + e + [{"t": t - 300, "e": "act", "a": "delete"}, {"t": t - 300, "e": "del"}] + e2
        x = rep.analyse(ev + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        self.assertEqual((dict(x.hits), dict(x.offsets)), ({}, {}))

    def test_a_word_continued_after_deleting_back_into_it_is_left_out(self):
        # "tge " then delete the space, e and g, and type "he ": the letters belong to the first word, not to "at"
        e, t = tapped(1000, "tge")
        ev = [APPEAR] + e + space(t) + [{"t": t + 10, "e": "act", "a": "delete"}, {"t": t + 10, "e": "del"}] * 3
        e2, t = tapped(t + 200, "he", n0=10)
        e3, t = tapped(t + 200, "at", n0=20)
        ev += e2 + space(t - 300) + e3 + space(t)
        x = rep.analyse(ev + [exercise(900, t + 500, "the at", "the at ")]).exercises
        offsets = {k: [(round(dx, 6), round(dy, 6)) for dx, dy in v] for k, v in x.offsets.items()}
        self.assertEqual((dict(x.hits), offsets), ({("h", "g"): 1}, {"t": [(0, 0), (0, 0)], "e": [(0, 0)], "a": [(0, 0)]}))

    def test_the_same_uptime_in_another_boot_is_left_out(self):
        e, t = tapped(1000, "tge")
        x = rep.analyse([APPEAR] + e + space(t) + [exercise(900, t + 500, "the", "the ", wall="2026-11-14T08:00:00Z")]).exercises
        self.assertEqual(dict(x.hits), {})

    def test_a_sentence_typed_with_a_word_left_out_attributes_no_taps(self):
        # "mind we" for "mind if we": "we" sits where "if" was meant, and is the same length
        e, t = tapped(1000, "mind")
        e2, t = tapped(t + 100, "we", n0=10)
        ev = [APPEAR] + e + space(t - 200) + e2 + space(t)
        x = rep.analyse(ev + [exercise(900, t + 500, "mind if we", "mind we ")]).exercises
        self.assertEqual((dict(x.hits), dict(x.offsets)), ({}, {}))

    def test_a_window_is_matched_within_its_own_boot(self):
        # two boots whose uptime windows overlap: the other boot's second sentence started later in uptime than
        # this boot's, and its first one earlier
        e, t = tapped(1000, "tge")
        ev = [APPEAR] + e + space(t)
        other = [exercise(100, 200, "cat", "cat", wall="2026-11-14T07:58:20Z"), exercise(950, t + 500, "dog", "dog", wall="2026-11-14T07:58:20.85Z")]
        x = rep.analyse(ev + [exercise(900, t + 500, "the", "the ")] + other).exercises
        self.assertEqual(dict(x.hits), {("h", "g"): 1})

    def test_a_letter_typed_into_emoji_search_does_not_lend_its_touch_to_the_document(self):
        # "t" typed into emoji search at (0, 0), then "the" typed in the field on its keys' centres
        search = [{"t": 950, "e": "down", "n": 90, "key": "letters-t", "p": [0, 0], "fingers": 1},
                  {"t": 960, "e": "up", "n": 90, "key": "letters-t", "p": [0, 0], "verdict": "tap", "ms": 10},
                  {"t": 961, "e": "key", "text": "t", "p": [0, 0], "search": True}]
        e, t = tapped(1000, "the")
        x = rep.analyse([APPEAR] + search + e + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        self.assertEqual(x.offsets["t"], [(0, 0)])

    def test_text_dictated_into_the_sentence_leaves_the_typed_words_unplaced(self):
        # "Did you see " dictated (logged by length only), then "the" typed and "teh" corrected
        dictated = [{"t": 950, "e": "dictation", "chars": 12, "words": 3}, {"t": 951, "e": "ins", "chars": 12}]
        e, t = tapped(1000, "tge")
        ev = [APPEAR] + dictated + e + [{"t": t, "e": "act", "a": "space"}] + [{"t": t, "e": "del"}] * 3 + [
            {"t": t, "e": "ins", "text": "the"}, {"t": t, "e": "autocorrect", "from": "tge", "to": "the"}, {"t": t, "e": "ins", "text": " "}]
        x = rep.analyse(ev + [exercise(900, t + 500, "Did you see the", "Did you see the ")]).exercises
        self.assertEqual((dict(x.hits), dict(x.offsets), dict(x.corrections)), ({}, {}, {"not placed": 1}))

    def test_a_keyboard_resized_mid_sentence_measures_taps_on_its_new_keys(self):
        # the keyboard narrows to 375 pt: t, h and e centred on its keys there
        narrow = {"t": 950, "e": "page", "page": "letters", "form": "phone", "width": 375}
        c, _ = rep.phone_letter_centres(375)
        e, t = tapped(1000, "the", at={i: c[ch] for i, ch in enumerate("the")})
        x = rep.analyse([APPEAR, narrow] + e + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        got = {k: [(round(dx, 6), round(dy, 6)) for dx, dy in v] for k, v in x.offsets.items()}
        self.assertEqual(got, {"t": [(0, 0)], "h": [(0, 0)], "e": [(0, 0)]})

    def test_taps_on_an_ipad_keyboard_give_no_offsets(self):
        pad = {"t": 950, "e": "page", "page": "letters", "form": "pad", "width": 820}
        e, t = tapped(1000, "the")
        x = rep.analyse([APPEAR, pad] + e + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        self.assertEqual(dict(x.offsets), {})

    def test_a_tap_keeps_the_keyboard_it_landed_on(self):
        # "t" tapped on the 402 pt keyboard, which then narrows before "he": t is measured on the keyboard it hit
        e, t = tapped(1000, "t")
        c, _ = rep.phone_letter_centres(375)
        e2, t = tapped(t + 50, "he", at={0: c["h"], 1: c["e"]}, n0=10)
        narrow = {"t": t - 400, "e": "page", "page": "letters", "form": "phone", "width": 375}
        x = rep.analyse([APPEAR] + e + [narrow] + e2 + space(t) + [exercise(900, t + 500, "the", "the ")]).exercises
        got = {k: [(round(dx, 6), round(dy, 6)) for dx, dy in v] for k, v in x.offsets.items()}
        self.assertEqual(got, {"t": [(0, 0)], "h": [(0, 0)], "e": [(0, 0)]})

    def test_a_keyboard_resized_while_a_finger_is_down_measures_the_tap_where_it_landed(self):
        # the keyboard narrows between "t" going down and lifting: its landing point is on the 402 pt keys
        e, t = tapped(1000, "t")
        narrow = {"t": 1020, "e": "page", "page": "letters", "form": "phone", "width": 375}
        x = rep.analyse([APPEAR, e[0], narrow] + e[1:] + space(t) + [exercise(900, t + 500, "t", "t ")]).exercises
        self.assertEqual({k: [(round(dx, 6), round(dy, 6)) for dx, dy in v] for k, v in x.offsets.items()}, {"t": [(0, 0)]})

    def test_exercise_lines_after_the_keyboards_do_not_read_as_a_restart(self):
        keys = [{"t": 5_000_000 + 200 * i, "e": "key", "text": "a"} for i in range(6)]
        r = rep.analyse(keys + [exercise(1_000, 2_000, "a", "a"), exercise(3_000, 4_000, "b", "b")])
        self.assertEqual((len(r.kps), r.span_s, r.exercises.sentences), (1, 1.0, 2))

    def test_a_folder_holds_the_exercise_files_too(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "keyboard.jsonl").write_text('{"t":2,"e":"key","text":"b"}\n')
            Path(d, "exercises.1.jsonl").write_text(json.dumps(exercise(1, 3, "a", "a")) + "\n")
            Path(d, "exercises.jsonl").write_text(json.dumps(exercise(4, 5, "b", "b")) + "\n")
            self.assertEqual([e["t"] for e in rep.read_events(Path(d))], [2, 1, 4])

    def test_text_and_json_reports_carry_the_exercise(self):
        e, t = tapped(1000, "tge", at={0: (180.9 - 3.42, 29)})
        r = rep.analyse([APPEAR] + e + space(t) + [exercise(900, t + 500, "the", "tge ")])
        self.assertIn("    t  -0.10  +0.00  (1)\n", rep.text_report(r) + "\n")
        self.assertIn("    h  g  1", rep.text_report(r))
        self.assertEqual(json.loads(json.dumps(rep.json_report(r)))["exercises"], {
            "sentences": 1, "words": 1, "wrong_words": [{"target": "the", "typed": "tge"}],
            "autocorrect": {"to_target": 0, "other_word": 0, "not_placed": 0}, "kps_median": 7.33,  # 4 keys (t g e, space) from 1041 to 1450 ms
            "offsets": {"e": {"dx": 0.0, "dy": 0.0, "n": 1}, "t": {"dx": -0.1, "dy": 0.0, "n": 1}},
            "hits": [{"meant": "h", "hit": "g", "n": 1}]})
        self.assertIsNone(rep.json_report(rep.analyse([APPEAR]))["exercises"])


if __name__ == "__main__":
    unittest.main()
