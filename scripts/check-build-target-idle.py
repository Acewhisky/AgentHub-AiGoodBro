#!/usr/bin/env python3
"""Refuse to replace a bundle whose executable still belongs to a live process."""

import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("Build guard: one target executable is required.", file=sys.stderr)
        return 2
    target = Path(sys.argv[1]).resolve()
    try:
        processes = subprocess.run(
            ["/bin/ps", "-ww", "-axo", "pid=,comm="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        print("Build guard: process state could not be verified.", file=sys.stderr)
        return 1
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[1].startswith("/"):
            continue
        if Path(fields[1]).resolve() == target:
            print(
                "Build guard: the target app is running. Use a separate "
                "BUILD_DIR or quit that app before building.",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
