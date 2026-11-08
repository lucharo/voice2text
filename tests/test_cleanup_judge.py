"""The cleanup judge's bookkeeping: replies it refuses, the budget, and scores given to models by text."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "utils/asr_grid"))
import cleanup_judge as cj

GOOD = {c: 4 for c in cj.CRITERIA}


class Check(unittest.TestCase):
    def test_every_label_once_scores_in_range_and_a_known_winner(self):
        ok = {"versions": [{"label": "A", **GOOD}, {"label": "B", **GOOD}], "best": "B"}

        self.assertEqual([cj.check(g, ["A", "B"]) for g in (
            ok,
            {**ok, "versions": ok["versions"][:1]},
            {**ok, "versions": [ok["versions"][0], {"label": "A", **GOOD}]},
            {**ok, "versions": [ok["versions"][0], {"label": "B", **GOOD, "faithful": 6}]},
            {**ok, "best": "C"},
        )], [None, "labels ['A'] for ['A', 'B']", "labels ['A', 'A'] for ['A', 'B']", "a score outside 1-5",
             "best 'C' is not a label"])


class Run(unittest.TestCase):
    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.out = Path(d.name)
        patches = [mock.patch.object(cj, "OUT", self.out), mock.patch.object(cj, "azure_key", return_value="k"),
                   mock.patch("builtins.print")]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_judge(self, outs, replies, budget=5.0):
        calls = []

        def ask(key, raw, versions):
            calls.append([t for _, t in versions])
            labels = [lab for lab, _ in versions]
            reply = replies.pop(0)
            return reply(labels) if callable(reply) else reply, {"input_tokens": 1000, "output_tokens": 100}

        with mock.patch.object(cj, "outputs", lambda s: outs if s == "earnings22" else {}), \
             mock.patch.object(cj, "ask", ask):
            cj.run(mock.Mock(sets=["earnings22"], budget=budget, limit=None))
        return calls

    @staticmethod
    def fine(labels):
        return {"versions": [{"label": lab, **GOOD, "punctuation": 5 - i} for i, lab in enumerate(labels)],
                "best": labels[0]}

    def test_a_model_that_matches_an_existing_output_gets_its_scores_without_a_new_call(self):
        outs = {"c1": {"raw": "so uh hi", "m1": "So, hi."}}
        self.run_judge(outs, [self.fine])
        outs["c1"]["m2"] = "So, hi."  # a new model, same text

        calls = self.run_judge(outs, [])

        with mock.patch.object(cj, "outputs", lambda s: outs if s == "earnings22" else {}), \
             mock.patch("builtins.print") as p:
            cj.report(mock.Mock(sets=["earnings22"]))
        table = "\n".join(str(c.args[0]) for c in p.call_args_list if c.args)
        self.assertEqual(calls, [])
        self.assertIn("| m2 |", table)

    def test_the_report_reads_only_the_judgment_of_the_current_outputs(self):
        outs = {"c1": {"raw": "so uh hi", "m1": "So, hi."}}
        self.run_judge(outs, [lambda labels: {"versions": [{"label": lab, **GOOD, "punctuation": 1} for lab in labels],
                                              "best": labels[0]}])
        outs["c1"]["m1"] = "So hi."  # m1 changed: judged again, and only that judgment counts
        self.run_judge(outs, [lambda labels: {"versions": [{"label": lab, **GOOD, "punctuation": 5} for lab in labels],
                                              "best": labels[0]}])

        with mock.patch.object(cj, "outputs", lambda s: outs if s == "earnings22" else {}), \
             mock.patch("builtins.print") as p:
            cj.report(mock.Mock(sets=["earnings22"]))
        rows = [str(c.args[0]) for c in p.call_args_list if c.args and str(c.args[0]).startswith("| m1 |")]
        self.assertEqual(rows[0].split(" | ")[1], "5.00")

    def test_a_refused_reply_is_billed_but_asked_again_next_run(self):
        outs = {"c1": {"raw": "so uh hi", "m1": "So, hi."}}

        self.run_judge(outs, [{"versions": [], "best": "A"}])
        again = self.run_judge(outs, [self.fine])

        bill = [json.loads(line) for line in (self.out / "spend.jsonl").read_text().splitlines()]
        self.assertEqual([b["rejected"] is None for b in bill], [False, True])
        self.assertEqual(len(again), 1)

    def test_the_run_stops_before_a_call_that_could_pass_the_budget(self):
        outs = {f"c{i}": {"raw": "so uh hi", "m1": "So, hi."} for i in range(3)}
        one = cj.worst_case("so uh hi", sorted({"so uh hi", "So, hi."}))

        # room for one worst case; the first call's real cost (1,000 in, 100 out: $0.003) leaves too little
        calls = self.run_judge(outs, [self.fine] * 3, budget=one + 0.001)

        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
