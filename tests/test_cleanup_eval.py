"""Formatting scores for cleanup output (utils/asr_grid/cleanup_eval.py)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "utils/asr_grid"))
import cleanup_eval as ce


class Compare(unittest.TestCase):
    def test_marks_and_capitals_are_scored_on_the_words_both_have(self):
        got = ce.compare("Revenue grew 5%, and we're happy. Next?", "revenue grew 5% and we're happy, next?")

        self.assertEqual({k: v for k, v in got.items() if v}, {
            "matched": 7, "fn,": 1, "fp,": 1, "fn.": 1, "tp?": 1,  # a comma moved, a full stop became a comma
            "cap_fn": 2, "digits_ref": 1, "digits_hit": 1})

    def test_a_number_spelled_out_misses_the_digits(self):
        got = ce.compare("We sold 42 units.", "We sold forty two units.")

        self.assertEqual((got["digits_ref"], got["digits_hit"], got["tp."]), (1, 0, 1))

    def test_each_digit_in_the_output_counts_once(self):
        got = ce.compare("From 5 to 5 then 5.", "From 5 to five then five.")

        self.assertEqual((got["digits_ref"], got["digits_hit"]), (3, 1))


    def test_a_grouped_number_is_one_number_and_its_comma_no_punctuation(self):
        got = ce.compare("We sold 1,000 units, mostly.", "We sold 1 000 units, mostly.")

        self.assertEqual((got["digits_ref"], got["digits_hit"], got["tp,"], got["fp,"]), (1, 0, 1, 0))

    def test_a_sign_or_leading_point_is_part_of_the_number(self):
        flipped = ce.compare("Change was -5.", "Change was 5.")
        point = ce.compare("Down .5 today.", "Down 5 today.")
        ranged = ce.compare("Pages 3-5.", "Pages 3-5.")

        self.assertEqual([(c["digits_ref"], c["digits_hit"]) for c in (flipped, point, ranged)], [(1, 0), (1, 0), (2, 2)])

    def test_quotes_stay_outside_the_word_so_its_capital_counts(self):
        got = ce.compare("'Hello,' she said.", "'hello,' she said.")

        self.assertEqual((got["matched"], got["cap_fn"], got["tp,"]), (3, 1, 1))


class Leftovers(unittest.TestCase):
    def test_fillers_and_repeats_are_counted_before_and_after(self):
        got = ce.leftovers("um um the the plan uh is is fine", "The plan is is fine")

        # "um um" is two fillers, not a repeat
        self.assertEqual(dict(got), {"fill_raw": 3, "rep_raw": 2, "fill_out": 0, "rep_out": 1})


class Summary(unittest.TestCase):
    def test_f1_per_mark_and_empty_counts_give_none(self):
        s = ce.summary(ce.compare("Yes, no.", "Yes, no?") + ce.leftovers("yes no", "yes no"))

        self.assertEqual((round(s["comma_f1"]), s["stop_f1"], s["question_f1"], s["fillers_left"], s["digits"]),
                         (100, 0.0, 0.0, None, None))


if __name__ == "__main__":
    unittest.main()
