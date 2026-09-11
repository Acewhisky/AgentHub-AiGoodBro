#!/usr/bin/env python3
import pathlib
import platform
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class LocalCLILoginCoordinatorTests(unittest.TestCase):
    def test_official_login_state_machine_with_synthetic_capabilities(self):
        sources = [
            ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift",
            ROOT / "Sources/CodexUsageWidget/Domain/LocalCLILoginWorkflow.swift",
            ROOT / "Sources/CodexUsageWidget/Services/LocalCLILoginCoordinator.swift",
            ROOT / "tests/LocalCLILoginCoordinatorFixture.swift",
        ]
        with tempfile.TemporaryDirectory(prefix="local-cli-login-coordinator-") as directory:
            output = pathlib.Path(directory) / "fixture"
            sdk = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")
            if not sdk.is_dir():
                sdk = pathlib.Path(subprocess.check_output(
                    ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
            compiled = subprocess.run([
                "xcrun", "swiftc", "-target", f"{platform.machine()}-apple-macos13.0",
                "-sdk", str(sdk), "-module-cache-path", str(pathlib.Path(directory) / "ModuleCache"),
                "-parse-as-library", "-o", str(output), *(str(source) for source in sources),
            ], cwd=ROOT, text=True, capture_output=True, timeout=180, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            ran = subprocess.run([str(output)], cwd=ROOT, text=True, capture_output=True,
                                 timeout=30, check=False)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertEqual(ran.stdout.strip(), "local-cli-login-coordinator-fixture: ok")


if __name__ == "__main__":
    unittest.main()
