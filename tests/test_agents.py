from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from v2t import agents, cli


class AgentsTests(unittest.TestCase):
    def _home_case(self):
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        patcher = mock.patch.dict(os.environ, {"HOME": tempdir.name}, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        return Path(tempdir.name)

    def test_status_on_empty_home(self):
        home = self._home_case()

        result = agents.status()

        self.assertEqual(result["line"], agents.LINE)
        self.assertEqual(result["skills"], ["v2t-dictionary", "v2t-transcribe"])
        harnesses = {item["id"]: item for item in result["harnesses"]}
        self.assertEqual(set(harnesses), {"claude", "codex", "pi"})
        self.assertFalse(harnesses["claude"]["present"])
        self.assertFalse(harnesses["codex"]["present"])
        self.assertFalse(harnesses["pi"]["present"])
        self.assertEqual(harnesses["claude"]["skills_dir"], str(home / ".claude" / "skills"))
        self.assertEqual(harnesses["codex"]["instructions"], str(home / ".codex" / "AGENTS.md"))
        for harness in harnesses.values():
            self.assertFalse(harness["line_present"])
            self.assertEqual(
                harness["skills"],
                [
                    {"name": "v2t-dictionary", "state": "missing"},
                    {"name": "v2t-transcribe", "state": "missing"},
                ],
            )

    def test_install_status_outdated_then_reinstall(self):
        home = self._home_case()

        agents.install_skills("codex")
        installed = {item["id"]: item for item in agents.status()["harnesses"]}["codex"]
        self.assertEqual([skill["state"] for skill in installed["skills"]], ["installed", "installed"])

        skill_file = home / ".agents" / "skills" / "v2t-dictionary" / "SKILL.md"
        skill_file.write_text(skill_file.read_text(encoding="utf-8") + "\nchanged\n", encoding="utf-8")
        outdated = {item["id"]: item for item in agents.status()["harnesses"]}["codex"]
        self.assertEqual(
            {skill["name"]: skill["state"] for skill in outdated["skills"]},
            {"v2t-dictionary": "outdated", "v2t-transcribe": "installed"},
        )

        agents.install_skills("codex")
        reinstalled = {item["id"]: item for item in agents.status()["harnesses"]}["codex"]
        self.assertEqual([skill["state"] for skill in reinstalled["skills"]], ["installed", "installed"])

    def test_remove_skills_leaves_other_skills_alone(self):
        home = self._home_case()
        other = home / ".agents" / "skills" / "other-skill"
        other.mkdir(parents=True)
        (other / "README.md").write_text("keep me\n", encoding="utf-8")

        agents.install_skills("codex")
        agents.remove_skills("codex")

        self.assertTrue(other.is_dir())
        self.assertTrue((other / "README.md").is_file())
        self.assertFalse((home / ".agents" / "skills" / "v2t-dictionary").exists())
        self.assertFalse((home / ".agents" / "skills" / "v2t-transcribe").exists())

    def test_add_line_twice_and_remove_line_restores_original_text(self):
        home = self._home_case()
        instructions = home / ".pi" / "agent" / "AGENTS.md"
        original = "alpha\nbeta\n"
        instructions.parent.mkdir(parents=True, exist_ok=True)
        instructions.write_text(original, encoding="utf-8")

        agents.add_line("pi")
        agents.add_line("pi")

        self.assertEqual(instructions.read_text(encoding="utf-8"), original + "\n" + agents.LINE.replace(agents.MARKER, agents.MARKER_WITH_BLANK) + "\n")

        agents.remove_line("pi")

        self.assertEqual(instructions.read_text(encoding="utf-8"), original)

    def test_remove_line_keeps_a_blank_line_the_file_already_ended_with(self):
        home = self._home_case()
        instructions = home / ".claude" / "CLAUDE.md"
        instructions.parent.mkdir(parents=True, exist_ok=True)
        instructions.write_text("alpha\n\n", encoding="utf-8")

        agents.add_line("claude")
        added = instructions.read_text(encoding="utf-8")
        agents.remove_line("claude")

        self.assertEqual(added, "alpha\n\n" + agents.LINE + "\n")
        self.assertEqual(instructions.read_text(encoding="utf-8"), "alpha\n\n")

    def test_bytes_that_are_not_utf8_survive_adding_and_removing_the_line(self):
        home = self._home_case()
        instructions = home / ".codex" / "AGENTS.md"
        instructions.parent.mkdir(parents=True, exist_ok=True)
        original = b"caf\xe9 latin-1\n"
        instructions.write_bytes(original)

        agents.add_line("codex")
        self.assertTrue(instructions.read_bytes().startswith(original))
        agents.remove_line("codex")

        self.assertEqual(instructions.read_bytes(), original)

    def test_cli_json_before_the_action_still_prints_json(self):
        self._home_case()
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout):
            cli.main(["agents", "--json", "install", "line", "pi"])

        self.assertTrue(json.loads(stdout.getvalue())["harnesses"])

    def test_cli_install_line_json_reports_pi_line_present(self):
        self._home_case()
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout):
            rc = cli.main(["agents", "install", "line", "pi", "--json"])

        self.assertEqual(rc, 0)
        result = json.loads(stdout.getvalue())
        pi = next(item for item in result["harnesses"] if item["id"] == "pi")
        self.assertTrue(pi["line_present"])
        self.assertEqual(result["line"], agents.LINE)


if __name__ == "__main__":
    unittest.main()
