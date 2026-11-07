"""The scoring and the decision rule of the iPhone cleanup prompt search (#126)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "utils/phone_bench"))
import prompt_search as ps
from v2t import backends


class Render(unittest.TestCase):
    def test_todays_candidate_is_the_prompt_the_app_sends(self):
        prompt = ps.render(ps.TODAY, ["Claude", "roborev"])

        # ios/App/Cleaner.swift: messages(...)[0] as instructions, "Dictation: …\nCleaned:", max(64, 3 x words)
        self.assertEqual(prompt, {
            "instructions": backends.cleanup_messages("x", "casual", ["Claude", "roborev"])[0]["content"],
            "frame": "Dictation: {text}\nCleaned:", "cap": 3, "min_cap": 64, "chunk_words": 120})

    def test_knobs_change_only_their_part(self):
        today = ps.render(ps.TODAY, [])["instructions"]
        joined = ps.render({**ps.TODAY, "join": True}, [])["instructions"]
        shown = ps.render({**ps.TODAY, "examples": 1, "frame": "tagged"}, [])

        self.assertEqual(joined, today.replace(backends.PROMPTS["casual"], backends.PROMPTS["casual"] + ps.JOIN_RULE))
        raw, clean = backends.EXAMPLES["casual"][0]
        self.assertEqual(shown["instructions"], today + f"\n\nExamples:\n<dictation>{raw}</dictation> {clean}")

    def test_custom_rules_replace_the_casual_rules_and_keep_the_dictionary(self):
        prompt = ps.render({**ps.TODAY, "custom": "Tidy this."}, ["Claude"])["instructions"]

        self.assertEqual(prompt, backends.cleanup_messages("x", "casual", ["Claude"])[0]["content"]
                         .replace(backends.PROMPTS["casual"], "Tidy this."))


class Guards(unittest.TestCase):
    def test_each_chunk_gets_the_apps_guards(self):
        ins = ["so I think we should meet", "can you send it", "the plan is fine"]
        outs = ["", "Sure, I will send it to you right now, no problem at all, okay.", "The plan is fine."]

        text, st = ps.guarded(ins, outs, [])

        # empty -> heard words; an answer over 1.3x -> heard words; a faithful one -> kept as cleaned
        self.assertEqual(text, "so I think we should meet can you send it The plan is fine.")
        self.assertEqual(st, {"chunks": 3, "reverts": 2, "answers": 1})

    def test_a_dropped_word_comes_back(self):
        text, _ = ps.guarded(["send me the report"], ["Send me report."], [])

        self.assertEqual(text, "Send me the report.")


class Items(unittest.TestCase):
    def test_a_cut_full_stop_counts_against_the_same_candidates_whole_file_text(self):
        def item(kind, out):
            return ps.per_item({"chunk_in": [out], "chunk_out": [out], "chunk_s": [1.0]},
                               {"kind": kind, "cuts": 1}, [])

        scored = ps.pair_cuts({
            # the cut left "home. And"; cleanup also split the run-on sentence, in both versions
            "pieces/n/1": item("pieces", "I went home. And then I slept. It rained all night."),
            "whole/n/1": item("whole", "I went home and then I slept. It rained all night."),
            "pieces/n/2": item("pieces", "No twin yet."),
        })

        self.assertEqual({k: v.get("extra_ends") for k, v in scored.items()},
                         {"pieces/n/1": 1, "whole/n/1": None, "pieces/n/2": None})

    def test_e22_scores_words_and_formatting_against_the_reference(self):
        meta = {"kind": "e22", "ref": "Revenue grew 5%."}
        row = {"chunk_in": ["revenue grew five percent"], "chunk_out": ["Revenue grew 5%."], "chunk_s": [0.5]}

        got = ps.per_item(row, meta, [])

        self.assertEqual({k: got[k] for k in ("wer_err", "wer_n", "fmt_err", "fmt_n")},
                         {"wer_err": 0, "wer_n": 3, "fmt_err": 0, "fmt_n": 5})


class ScoreGeneration(unittest.TestCase):
    def test_a_job_s_rows_are_scored_with_the_guards_and_paired_by_dictation(self):
        with tempfile.TemporaryDirectory() as d:
            out, res = Path(d) / "ps", Path(d) / "jobs"
            (res / "g0").mkdir(parents=True)
            out.mkdir()
            (out / "vocabulary.json").write_text("[]")
            (out / "meta.jsonl").write_text("".join(json.dumps(m) + "\n" for m in [
                {"id": "pieces/n/1", "kind": "pieces", "cuts": 1}, {"id": "whole/n/1", "kind": "whole"}]))
            rows = [{"event": "start"},
                    {"event": "clean", "id": "pieces/n/1", "chunk_in": ["i went home. and slept"],
                     "chunk_out": ["I went home. And slept."], "chunk_s": [1.0]},
                    {"event": "clean", "id": "whole/n/1", "chunk_in": ["i went home and slept"],
                     "chunk_out": ["I went home and slept."], "chunk_s": [1.0]}]
            (res / "g0" / f"g0.{ps.cand_id(ps.TODAY)}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))

            with mock.patch.object(ps, "OUT", out), mock.patch.dict(ps.RESULTS, {"root": res}):
                scored = ps.score_generation("g0", [ps.TODAY])

        self.assertEqual(scored[ps.cand_id(ps.TODAY)]["pieces/n/1"]["extra_ends"], 1)


def items(n_e22=40, n_pieces=40, fmt_err=2, extra=1, heard_err=0, wer_err=0, s=1.0):
    """Per-item numbers for a candidate: n Earnings22 items and n dictations, all alike."""
    out = {f"e22/{i}": {"wer_err": wer_err, "wer_n": 10, "fmt_err": fmt_err, "fmt_n": 12, "heard_err": 0,
                        "heard_n": 10, "chunks": 1, "reverts": 0, "answers": 0, "errors": 0, "seconds": [s]}
           for i in range(n_e22)}
    out |= {f"pieces/n/{i}": {"heard_err": heard_err, "heard_n": 20, "ends": 3 + extra, "extra_ends": extra, "cuts": 2,
                              "chunks": 1, "reverts": 0, "answers": 0, "errors": 0, "seconds": [s]} for i in range(n_pieces)}
    out |= {f"whole/n/{i}": {"heard_err": 0, "heard_n": 20, "ends": 3, "chunks": 1, "reverts": 0, "answers": 0,
                             "errors": 0, "seconds": [s]} for i in range(n_pieces)}
    return out


class Verdict(unittest.TestCase):
    def test_better_formatting_with_the_same_words_replaces_the_best(self):
        self.assertTrue(ps.verdict(items(), items(fmt_err=1))[0])

    def test_fewer_cut_breaks_with_the_same_words_replaces_the_best(self):
        self.assertTrue(ps.verdict(items(), items(extra=0))[0])

    def test_losing_spoken_words_is_refused_however_well_it_formats(self):
        self.assertFalse(ps.verdict(items(), items(fmt_err=0, extra=0, heard_err=2))[0])
        self.assertFalse(ps.verdict(items(), items(fmt_err=0, extra=0, wer_err=1))[0])

    def test_better_on_one_formatting_score_and_worse_on_the_other_is_refused(self):
        self.assertFalse(ps.verdict(items(), items(fmt_err=0, extra=2))[0])

    def test_a_tie_wins_only_by_being_faster(self):
        self.assertTrue(ps.verdict(items(), items(s=0.8))[0])
        self.assertFalse(ps.verdict(items(), items())[0])

    def test_faster_does_not_buy_worse_formatting(self):
        self.assertFalse(ps.verdict(items(), items(fmt_err=3, s=0.8))[0])


class Bootstrap(unittest.TestCase):
    def test_a_dictation_resamples_as_one_group(self):
        # one dictation, its rows for two recognisers moving opposite ways: a single group, so every
        # resample is the whole set and the interval collapses to the point
        row = {"heard_n": 10, "ends": 1, "seconds": []}
        a = {f"whole/{r}/d1": {**row, "heard_err": 0} for r in ("n", "p")}
        b = {"whole/n/d1": {**row, "heard_err": 2}, "whole/p/d1": {**row, "heard_err": 0}}

        point, lo, hi = ps.paired(a, b, "heard")

        self.assertEqual((point, lo, hi), (10.0, 10.0, 10.0))
        self.assertEqual([ps.group(i) for i in ("e22/x1", "pieces/n/d1", "whole/p/d1")], ["e22/x1", "d1", "d1"])


class Loop(unittest.TestCase):
    BEST = {**ps.TODAY, "join": True}
    PROPOSALS = [{**ps.TODAY, "custom": f"Rules {i}."} for i in range(5)] + [ps.TODAY]

    def run_loop(self, budget, per_gen):
        runs = []
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "search-t.json").write_text(json.dumps(
                {"best": self.BEST, "tried": [ps.cand_id(self.BEST)], "generations": [], "spent": 1}))
            (out / "p.json").write_text(json.dumps(self.PROPOSALS))
            args = mock.Mock(tag="t", budget=budget, per_gen=per_gen, engine="phone", block=5, propose=str(out / "p.json"))
            with (mock.patch.object(ps, "OUT", out),
                  mock.patch.object(ps, "run_generation", lambda name, split, cands, *_: runs.append(cands)),
                  mock.patch.object(ps, "score_generation", lambda name, cands: {ps.cand_id(c): items() for c in cands}),
                  mock.patch("builtins.print")):
                ps.loop(args)
            return runs, json.loads((out / "search-t.json").read_text())

    def test_proposals_the_job_had_no_room_for_wait_for_the_next(self):
        runs, st = self.run_loop(budget=5, per_gen=4)

        self.assertEqual(runs, [[ps.TODAY, self.BEST] + self.PROPOSALS[:4]])
        self.assertEqual(st["pending"], [self.PROPOSALS[4]])

    def test_the_baselines_are_never_new_candidates(self):
        # today's prompt is both a proposal and a neighbour of the best; it runs once, as a baseline
        runs, st = self.run_loop(budget=7, per_gen=6)

        self.assertEqual(runs, [[ps.TODAY, self.BEST] + self.PROPOSALS[:5] + [{**self.BEST, "examples": 2}]])
        self.assertEqual(st["pending"], [])


class Neighbours(unittest.TestCase):
    def test_every_one_knob_change_not_yet_run(self):
        tried = {ps.cand_id({**ps.TODAY, "join": True})}

        got = ps.neighbours(ps.TODAY, tried)

        want = [{**ps.TODAY, k: v} for k, vs in ps.KNOBS.items() for v in vs if ps.TODAY[k] != v and (k, v) != ("join", True)]
        self.assertEqual(got, want)


if __name__ == "__main__":
    unittest.main()
