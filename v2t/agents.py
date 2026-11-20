"""Install and inspect voice2text skills for supported coding agents."""

from __future__ import annotations

from dataclasses import dataclass
from importlib import resources
from pathlib import Path
import shutil

MARKER = "<!-- voice2text -->"
LINE = (
    "I dictate with voice2text (v2t), so my messages can contain misheard words: "
    "when you spot one, offer to add it to my v2t dictionary with the v2t-dictionary "
    f"skill. {MARKER}"
)


@dataclass(frozen=True)
class Harness:
    id: str
    name: str
    root_parts: tuple[str, ...]
    skills_parts: tuple[str, ...]
    instructions_parts: tuple[str, ...]

    @property
    def root(self) -> Path:
        return Path.home().joinpath(*self.root_parts)

    @property
    def skills_dir(self) -> Path:
        return Path.home().joinpath(*self.skills_parts)

    @property
    def instructions(self) -> Path:
        return Path.home().joinpath(*self.instructions_parts)


HARNESSES = (
    Harness(
        id="claude",
        name="Claude Code",
        root_parts=(".claude",),
        skills_parts=(".claude", "skills"),
        instructions_parts=(".claude", "CLAUDE.md"),
    ),
    Harness(
        id="codex",
        name="Codex",
        root_parts=(".codex",),
        skills_parts=(".agents", "skills"),
        instructions_parts=(".codex", "AGENTS.md"),
    ),
    Harness(
        id="pi",
        name="Pi",
        root_parts=(".pi", "agent"),
        skills_parts=(".pi", "agent", "skills"),
        instructions_parts=(".pi", "agent", "AGENTS.md"),
    ),
)


def _skill_root():
    return resources.files("v2t") / "skills"


def _packaged_skills():
    return sorted((entry for entry in _skill_root().iterdir() if entry.is_dir()), key=lambda entry: entry.name)


def _skill_names() -> list[str]:
    return [entry.name for entry in _packaged_skills()]


def _lookup_harness(harness_id: str) -> Harness:
    for harness in HARNESSES:
        if harness.id == harness_id:
            return harness
    known = ", ".join(harness.id for harness in HARNESSES)
    raise SystemExit(f"unknown harness {harness_id!r}; expected one of: {known}")


def _contains_marker(path: Path) -> bool:
    if not path.exists():
        return False
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    return any(MARKER in line for line in text.splitlines())


def _read_bytes(node) -> bytes:
    with node.open("rb") as handle:
        return handle.read()


def _tree_signature(node, prefix: tuple[str, ...] = ()) -> dict[str, tuple[str, bytes | None]]:
    signature: dict[str, tuple[str, bytes | None]] = {}
    for child in sorted(node.iterdir(), key=lambda item: item.name):
        rel = "/".join(prefix + (child.name,))
        if child.is_dir():
            signature[rel] = ("dir", None)
            signature.update(_tree_signature(child, prefix + (child.name,)))
        elif child.is_file():
            signature[rel] = ("file", _read_bytes(child))
        else:
            signature[rel] = ("other", None)
    return signature


def _skill_state(skill, destination: Path) -> str:
    if not destination.exists():
        return "missing"
    if not destination.is_dir():
        return "outdated"
    return "installed" if _tree_signature(skill) == _tree_signature(destination) else "outdated"


def status() -> dict:
    skills = _packaged_skills()
    return {
        "line": LINE,
        "skills": [skill.name for skill in skills],
        "harnesses": [
            {
                "id": harness.id,
                "name": harness.name,
                "present": harness.root.exists(),
                "skills_dir": str(harness.skills_dir),
                "instructions": str(harness.instructions),
                "skills": [
                    {
                        "name": skill.name,
                        "state": _skill_state(skill, harness.skills_dir / skill.name),
                    }
                    for skill in skills
                ],
                "line_present": _contains_marker(harness.instructions),
            }
            for harness in HARNESSES
        ],
    }


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    if path.exists():
        shutil.rmtree(path)


def _copy_tree(source, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir():
            _copy_tree(child, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(_read_bytes(child))


def install_skills(harness_id: str) -> None:
    harness = _lookup_harness(harness_id)
    harness.skills_dir.mkdir(parents=True, exist_ok=True)
    for skill in _packaged_skills():
        destination = harness.skills_dir / skill.name
        _remove_path(destination)
        _copy_tree(skill, destination)


def remove_skills(harness_id: str) -> None:
    harness = _lookup_harness(harness_id)
    for name in _skill_names():
        _remove_path(harness.skills_dir / name)


def _ends_with_blank_line(text: str) -> bool:
    if not text or not text.endswith("\n"):
        return False
    lines = text.splitlines()
    return not lines or lines[-1] == ""


def add_line(harness_id: str) -> None:
    harness = _lookup_harness(harness_id)
    harness.instructions.parent.mkdir(parents=True, exist_ok=True)
    text = ""
    if harness.instructions.exists():
        text = harness.instructions.read_text(encoding="utf-8", errors="surrogateescape")
    if any(MARKER in line for line in text.splitlines()):
        return
    if text:
        if not text.endswith("\n"):
            text += "\n"
        if not _ends_with_blank_line(text):
            text += "\n"
    text += LINE + "\n"
    harness.instructions.write_text(text, encoding="utf-8")


def remove_line(harness_id: str) -> None:
    """Drops every line carrying MARKER, with the blank line add_line put before it,
    and leaves the rest of the file as it was."""
    harness = _lookup_harness(harness_id)
    if not harness.instructions.exists():
        return
    lines = harness.instructions.read_text(encoding="utf-8", errors="surrogateescape").splitlines(keepends=True)
    if not any(MARKER in line for line in lines):
        return
    kept: list[str] = []
    for line in lines:
        if MARKER in line:
            if kept and not kept[-1].strip():
                kept.pop()
            continue
        kept.append(line)
    harness.instructions.write_text("".join(kept), encoding="utf-8")
