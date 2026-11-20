"""Install and inspect voice2text skills for supported coding agents."""

from __future__ import annotations

from dataclasses import dataclass
from importlib import resources
import os
from pathlib import Path
import shutil
import tempfile

MARKER = "<!-- voice2text -->"
# The same line when add_line also put a blank line before it, so remove_line takes
# that blank line too and leaves one the file already had.
MARKER_WITH_BLANK = "<!-- voice2text +blank -->"
_MARK = "<!-- voice2text"  # what both start with
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
    return any(_MARK in line for line in _read_text(path).splitlines())


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


def _read_text(path: Path) -> str:
    """The file's text, any bytes that are not UTF-8 kept as they are (surrogateescape)."""
    return path.read_bytes().decode("utf-8", errors="surrogateescape")


def _write_text(path: Path, text: str) -> None:
    """Writes `text` (encoded back with surrogateescape, so other bytes survive) to a
    temporary file beside the real target, then renames it over: a failure leaves the
    original whole. A symlinked instructions file is written through to its target."""
    target = path.resolve()
    data = text.encode("utf-8", errors="surrogateescape")
    mode = target.stat().st_mode & 0o7777 if target.exists() else 0o644
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def add_line(harness_id: str) -> None:
    harness = _lookup_harness(harness_id)
    harness.instructions.parent.mkdir(parents=True, exist_ok=True)
    text = _read_text(harness.instructions) if harness.instructions.exists() else ""
    if any(_MARK in line for line in text.splitlines()):
        return
    line = LINE
    if text:
        if not text.endswith("\n"):
            text += "\n"
        if not text.endswith("\n\n"):
            text += "\n"
            line = LINE.replace(MARKER, MARKER_WITH_BLANK)
    _write_text(harness.instructions, text + line + "\n")


def remove_line(harness_id: str) -> None:
    """Drops every line carrying the marker, and the blank line before it only when
    add_line put it there; the rest of the file stays as it was."""
    harness = _lookup_harness(harness_id)
    if not harness.instructions.exists():
        return
    lines = _read_text(harness.instructions).splitlines(keepends=True)
    if not any(_MARK in line for line in lines):
        return
    kept: list[str] = []
    for line in lines:
        if _MARK in line:
            if MARKER_WITH_BLANK in line and kept and not kept[-1].strip():
                kept.pop()
            continue
        kept.append(line)
    _write_text(harness.instructions, "".join(kept))
