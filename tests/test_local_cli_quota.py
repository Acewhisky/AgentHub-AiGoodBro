#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift"
READER = ROOT / "Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift"
BOUNDED_READER = ROOT / "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift"
FIXTURE = ROOT / "tests/LocalCLIQuotaFixture.swift"
SDK = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")


class LocalCLIQuotaTests(unittest.TestCase):
    def test_actual_swift_sources_with_synthetic_fixture(self):
        self.assertTrue(SDK.is_dir(), f"required synthetic-test SDK missing: {SDK}")
        with tempfile.TemporaryDirectory(prefix="local-cli-quota-test-") as temporary:
            output = Path(temporary) / "fixture"
            cache = Path(temporary) / "module-cache"
            cache.mkdir()
            compile_result = subprocess.run(
                [
                    "swiftc",
                    "-sdk", str(SDK),
                    "-target", "arm64-apple-macosx13.0",
                    "-module-cache-path", str(cache),
                    str(DOMAIN),
                    str(BOUNDED_READER),
                    str(READER),
                    str(FIXTURE),
                    "-o", str(output),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run(
                [str(output)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertEqual(run_result.stdout.strip(), "PASS local-cli-quota fixture")

    def test_fixed_protocol_and_privacy_contracts(self):
        source = READER.read_text(encoding="utf-8")
        self.assertIn("https://cli-chat-proxy.grok.com/v1/billing?format=credits", source)
        self.assertIn("https://api.kimi.com/coding/v1/usages", source)
        self.assertIn("https://api.anthropic.com/api/oauth/usage", source)
        self.assertIn("https://opencode.ai/zen/go/v1/usage", source)
        self.assertIn('root["opencode-go"]', source)
        self.assertNotIn("HTTPCookieStorage.shared", source)
        self.assertNotIn("security ", source)
        self.assertNotIn("Swift.print(", source)
        self.assertNotIn("DebugLogger", source)
        self.assertNotIn("Data(contentsOf:", source)
        self.assertIn("DispatchParticipationSync.readBoundedRegularFile", source)
        self.assertIn("completionHandler(nil)", source)
        self.assertIn("didReceive chunk: Data", source)
        self.assertIn("SecItemCopyMatching", source)
        self.assertIn("kSecUseAuthenticationUIFail", source)
        self.assertIn('kSecAttrService: "Claude Code-credentials"', source)

    def test_fixture_contains_only_synthetic_credentials(self):
        fixture = FIXTURE.read_bytes()
        digest = hashlib.sha256(fixture).hexdigest()
        self.assertEqual(len(digest), 64)
        text = fixture.decode("utf-8")
        self.assertNotIn("sk-ant-", text)
        self.assertNotIn("sk-proj-", text)
        self.assertNotIn("/Users/", text)
        self.assertGreaterEqual(text.count("synthetic"), 10)


if __name__ == "__main__":
    unittest.main()
