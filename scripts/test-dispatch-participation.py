#!/usr/bin/env python3
"""Typecheck Next and interpret isolated Swift tests; never builds or launches the app."""

import argparse
import os
import pathlib
import plistlib
import platform
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--tests-only", action="store_true")
    mode.add_argument("--typecheck-only", action="store_true")
    options = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    sdk = os.environ.get("CAMNEXT_CHECK_SDK_PATH")
    if not sdk:
        developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        compat = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk")
        sdk = str(compat) if developer == str(compat.parents[1]) and compat.exists() else subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
    with tempfile.TemporaryDirectory(prefix="camnext-dispatch-check-") as temporary:
        work = pathlib.Path(temporary)
        env = {**os.environ, "MACOSX_DEPLOYMENT_TARGET": "13.0", "CAMNEXT_DISPATCH_TEST_ROOT": temporary}
        flags = ["-target", platform.machine() + "-apple-macos13.0", "-sdk", sdk,
                 "-module-cache-path", str(work / "ModuleCache")]

        def run(command):
            result = subprocess.run(command, cwd=repo, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = result.stdout
            for private, label in [(str(repo), "<repo>"), (temporary, "<temporary-check-directory>"),
                                   (str(pathlib.Path.home()), "<home>")]:
                output = output.replace(private, label)
            print(output, end="", flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)

        if not options.tests_only:
            sources = sorted(str(path.relative_to(repo)) for path in (repo / "Sources/CodexUsageWidget").rglob("*.swift"))
            with (pathlib.Path(sdk) / "SDKSettings.plist").open("rb") as settings:
                modern_sdk = int(plistlib.load(settings)["Version"].split(".")[0]) >= 26
            feature_flags = ["-D", "CAMNEXT_HAS_LIQUID_GLASS"] if modern_sdk else []
            print(f"Typechecking {len(sources)} Swift sources; no app build or launch.", flush=True)
            run(["xcrun", "swiftc", "-typecheck", "-parse-as-library", *flags, *feature_flags, *sources,
                 "-framework", "Cocoa", "-framework", "Carbon", "-framework", "Security", "-framework", "SwiftUI"])
            print("PASS: full source typecheck", flush=True)

        if not options.typecheck_only:
            service = repo / "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift"
            tests = repo / "tests/DispatchParticipationSyncTests.swift"
            script = work / "dispatch-tests.swift"
            script.write_text(service.read_text() + "\n" + tests.read_text())
            print("Interpreting offline Swift tests in a temporary directory.", flush=True)
            run(["xcrun", "swift", *flags, str(script)])


if __name__ == "__main__":
    main()
