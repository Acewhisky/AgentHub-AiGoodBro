#!/usr/bin/env python3
"""Isolated macOS fixture; no GUI, credentials or live account paths."""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('TERMINAL_RECEIPT_TEST_OUTPUT', ROOT / 'task-test-outputs/revision-0912v2'))
OUT.mkdir(parents=True, exist_ok=True)
records = []
inputs = ['Sources/CodexUsageWidget/Services/TerminalLaunchSession.swift', 'Sources/CodexUsageWidget/Services/LocalCLITerminalLauncher.swift', 'Sources/CodexUsageWidget/Services/UsageStore.swift', 'Sources/CodexUsageWidget/Services/DispatchActivityStore.swift', 'tests/TerminalReceiptSafetyFixture.swift']
(OUT / 'verification-inputs.json').write_text(json.dumps({p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in inputs}, indent=2) + '\n')
def run(args, env):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    output = (result.stdout + result.stderr).replace(str(ROOT), '<repo>')
    if env.get('TMPDIR'): output = output.replace(env['TMPDIR'], '<temp>/')
    output = output.replace(str(Path.home()), '<home>')
    records.append({'command': [str(a).replace(str(ROOT), '<repo>') for a in args], 'exit_code': result.returncode, 'output': output})
    (OUT / 'verification.json').write_text(json.dumps(records, indent=2) + '\n')
    print(output, end='')
    if result.returncode: sys.exit(result.returncode)

with tempfile.TemporaryDirectory(prefix='terminal-fixture-', dir=OUT) as folder:
    temp = Path(folder).resolve()
    env = dict(os.environ, TMPDIR=str(temp)+'/', CLANG_MODULE_CACHE_PATH=str(temp/'cache'), TERMINAL_FIXTURE_ROOT=str(temp/'state'), PYTHONDONTWRITEBYTECODE='1')
    source = (ROOT/'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
    start = source.index('    @discardableResult\n    private func updateTerminalActivity(')
    end = source.index('\n    func copyTerminalCommand(', start)
    methods = source[start:end]
    harness = '''
import Foundation
import Darwin
@MainActor final class MonitorHarness {
    var terminalMonitors: [String: Task<Void, Never>] = [:]
    var accountManagerMessage = ""
    func recordOperationsIssue(id: String, summary: String) {}
    func begin(_ session: TerminalLaunchSession, lease: String) { monitorTerminal(session, lease: lease, accountName: "fixture") }
    func waitFor(_ lease: String, expected: String) async throws {
        for _ in 0..<100 {
            let url = DispatchActivityStore.live.directory.appendingPathComponent(DispatchActivityStore.stateName)
            let state = try DispatchActivityStore.decode(Data(contentsOf: url))
            if state.leases.first(where: { $0.leaseId == lease })?.state == expected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "monitor-state-" + expected, code: 1)
    }
''' + methods + '\n}\n'
    launcher = (ROOT/'Sources/CodexUsageWidget/Services/LocalCLITerminalLauncher.swift').read_text()
    wait_start = launcher.index('    static func waitForExit(')
    wait_end = launcher.index('\n    private static func shellCommand(', wait_start)
    harness += '\nenum LocalCLITerminalLauncher {\n    enum Failure: Error { case timedOut }\n' + launcher[wait_start:wait_end] + '\n}\n'
    (temp/'Monitor.swift').write_text(harness)
    exe = temp/'fixture'
    run(['python3', 'scripts/check-build-target-idle.py', str(exe)], env)
    run(['xcrun', 'swiftc', '-parse-as-library', 'Sources/CodexUsageWidget/Services/TerminalLaunchSession.swift', 'Sources/CodexUsageWidget/Services/DispatchActivityStore.swift', 'tests/TerminalReceiptSafetyFixture.swift', str(temp/'Monitor.swift'), '-o', str(exe)], env)
    run([str(exe)], env)
