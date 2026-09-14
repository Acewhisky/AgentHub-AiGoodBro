#!/usr/bin/env python3
"""Offline public-feed schema, URL and refresh-contract checks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AIHotTopicsTests(unittest.TestCase):
    def test_public_feed_contract(self):
        with tempfile.TemporaryDirectory(prefix="aihot-topics-fixture-") as temporary:
            binary = Path(temporary) / "fixture"
            command = [
                "xcrun", "swiftc", "-module-cache-path", str(Path(temporary) / "modules"),
                str(ROOT / "Sources/CodexUsageWidget/Services/AIHotTopics.swift"),
                str(ROOT / "tests/AIHotTopicsFixture.swift"), "-o", str(binary),
            ]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "aihot-topics-fixture: ok")


if __name__ == "__main__":
    unittest.main()
