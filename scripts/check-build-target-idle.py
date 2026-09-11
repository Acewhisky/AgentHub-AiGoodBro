#!/usr/bin/env python3
"""Refuse to replace a bundle whose executable still belongs to a live process.

macOS `ps -ww -axo pid=,comm=` reports the untruncated executable path.
Identity is that path (resolved) and, when the file exists, its device/inode.
Full command lines (`command=`) are not read: splitting argv0 on spaces
breaks executables whose path contains spaces, and exposes process arguments.

Basename-only listings cannot be proved to be the target and fail closed.
"""

from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

PS_ARGV = ("/bin/ps", "-ww", "-axo", "pid=,comm=")

RUNNING_MESSAGE = (
    "Build guard: the target app is running. Quit that app before "
    "building or installing, or use a separate BUILD_DIR when building."
)
AMBIGUOUS_MESSAGE = (
    "Build guard: process identity is ambiguous for the target executable. "
    "Quit matching processes or relaunch the app from its absolute path "
    "before building or installing."
)
UNVERIFIED_MESSAGE = "Build guard: process state could not be verified."
USAGE_MESSAGE = "Build guard: one target executable is required."
INVALID_TARGET_MESSAGE = "Build guard: target is not a regular file."


@dataclass(frozen=True)
class ProcessRow:
    pid: int
    executable: str


@dataclass(frozen=True)
class GuardDecision:
    status: int
    message: str
    matching_pids: tuple[int, ...] = ()
    ambiguous_pids: tuple[int, ...] = ()


def parse_process_table(stdout: str) -> list[ProcessRow]:
    rows: list[ProcessRow] = []
    for line in stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        executable = fields[1]
        if not executable:
            continue
        rows.append(ProcessRow(int(fields[0]), executable))
    return rows


def file_identity(path: Path) -> tuple[int, int] | None:
    try:
        stat_result = path.stat()
    except OSError:
        return None
    return (stat_result.st_dev, stat_result.st_ino)


def classify_image(
    executable: str,
    resolved_target: Path,
    target_identity: tuple[int, int] | None,
) -> str:
    """Return match, ambiguous, or unrelated for one process executable path."""
    image = executable.strip()
    if not image:
        return "unrelated"
    image_name = Path(image).name
    if image.startswith("/"):
        candidate = Path(image)
        try:
            resolved_candidate = candidate.resolve()
        except OSError:
            resolved_candidate = None
        if resolved_candidate is not None and resolved_candidate == resolved_target:
            return "match"
        candidate_identity = file_identity(candidate)
        if (
            target_identity is not None
            and candidate_identity is not None
            and candidate_identity == target_identity
        ):
            return "match"
        return "unrelated"
    if image_name and image_name == resolved_target.name:
        return "ambiguous"
    return "unrelated"


def evaluate_guard(target: Path, rows: list[ProcessRow]) -> GuardDecision:
    """Decide whether `target` is idle enough to replace."""
    try:
        resolved_target = target.resolve()
    except OSError:
        return GuardDecision(1, UNVERIFIED_MESSAGE)
    if target.exists() and not target.is_file():
        return GuardDecision(2, INVALID_TARGET_MESSAGE)

    target_identity = file_identity(target)
    matching: list[int] = []
    ambiguous: list[int] = []
    seen_match: set[int] = set()
    seen_ambiguous: set[int] = set()

    for row in rows:
        kind = classify_image(row.executable, resolved_target, target_identity)
        if kind == "match":
            if row.pid not in seen_match:
                matching.append(row.pid)
                seen_match.add(row.pid)
        elif kind == "ambiguous":
            if row.pid not in seen_match and row.pid not in seen_ambiguous:
                ambiguous.append(row.pid)
                seen_ambiguous.add(row.pid)

    if matching:
        return GuardDecision(1, RUNNING_MESSAGE, tuple(matching), tuple(ambiguous))
    if ambiguous:
        return GuardDecision(1, AMBIGUOUS_MESSAGE, (), tuple(ambiguous))
    return GuardDecision(0, "", (), ())


def read_process_table() -> str:
    return subprocess.run(
        list(PS_ARGV),
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1 or not args[0] or args[0].startswith("-"):
        print(USAGE_MESSAGE, file=sys.stderr)
        return 2
    target = Path(args[0])
    if target.exists() and not target.is_file():
        print(INVALID_TARGET_MESSAGE, file=sys.stderr)
        return 2
    try:
        processes = read_process_table()
    except (OSError, subprocess.CalledProcessError):
        print(UNVERIFIED_MESSAGE, file=sys.stderr)
        return 1
    decision = evaluate_guard(target, parse_process_table(processes))
    if decision.message:
        print(decision.message, file=sys.stderr)
    return decision.status


if __name__ == "__main__":
    sys.exit(main())
