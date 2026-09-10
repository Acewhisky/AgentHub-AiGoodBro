#!/usr/bin/env python3
"""macOS-only Python/Swift shared-file contract and real flock interoperability."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import next_dispatch_activity as activity

# Standalone boundaries replace only application dependencies. The production
# DispatchActivityStore itself is compiled unchanged and reads/writes real files.
BOUNDARIES = '''
import Foundation
import Darwin
enum HubAccountTaskPhase { case maintenance, starting, running, cancelRequested, uncertain, awaitingAcceptance, succeeded, failed, cancelled, unavailable }
struct HubAccountTaskStatus { let phase: HubAccountTaskPhase; let updatedAt: Date? }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL { fatalError("Live directory must not be used by this fixture") }
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw NSError(domain: "fixture", code: 1) }
        return data
    }
}
@main struct Fixture {
    static func main() {
        let store = DispatchActivityStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            let alias = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "fixture-alias-" + CommandLine.arguments[2]
            let id = try store.reserveWarmUp(account: CommandLine.arguments[2], alias: alias)
            try store.finishWarmUp(id, succeeded: true)
            try store.appendIssue(id: "interop", phase: "verified", summary: "Swift fixture appended", code: "B")
            print("WROTE")
        } catch DispatchActivityStore.Failure.busy {
            print("BUSY")
        } catch {
            print("FAILED")
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='next-activity-interop-') as temporary:
    root = Path(temporary)
    source = root / 'Fixture.swift'
    source.write_text(BOUNDARIES)
    binary = root / 'fixture'
    compile_result = subprocess.run(
        ['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'Sources/CodexUsageWidget/Services/DispatchActivityStore.swift'),
         str(source), '-o', str(binary)], capture_output=True, text=True,
        env={**os.environ, 'CLANG_MODULE_CACHE_PATH': str(root / 'module-cache')})
    if compile_result.returncode:
        print('Interop fixture compilation failed; no live state was used')
        detail = compile_result.stderr.replace(str(ROOT), '<repo>').replace(str(root), '<temp>').strip()
        if detail:
            print(detail)
        raise SystemExit(1)
    registry = activity.Registry(root / 'state')
    lease = registry.reserve(account_key=activity.digest('fixture-a'), alias_key=activity.digest('fixture-alias-fixture-a'),
                             code='A', project=activity.digest('fixture-project'), owner='fixture-owner',
                             task='fixture-task', route='direct')
    # Unknown process fields are preserved by Swift's schema-preserving mutation.
    registry.update(lease['leaseId'], 'fixture-owner', childPID=99999, childPIDBirth=activity.digest('birth'))
    def invoke(account):
        return subprocess.run([str(binary), str(registry.root), account], capture_output=True, text=True, check=True).stdout.strip()
    assert invoke('fixture-a') == 'BUSY', 'Swift failed to honor Python account reservation'
    same_alias = subprocess.run([str(binary), str(registry.root), 'different-account', 'fixture-alias-fixture-a'], capture_output=True, text=True, check=True)
    assert same_alias.stdout.strip() == 'BUSY', 'Swift failed to honor Python alias reservation'
    with registry.lock():
        assert invoke('fixture-b') == 'BUSY', 'Swift failed to honor Python system file lock'
    assert invoke('fixture-b') == 'WROTE'
    leases = registry.read()['leases']
    assert len(leases) == 2
    assert leases[0]['leaseId'] == lease['leaseId'] and leases[0]['childPIDBirth'] == activity.digest('birth')
    assert leases[1]['state'] == 'accepted' and leases[1]['accountKey'] == activity.digest('fixture-b')
    registry.issue(issue_id='interop', component='skill', phase='verified', summary='Python fixture appended')
    lines = [json.loads(line) for line in (registry.root / activity.ISSUE_NAME).read_text().splitlines()]
    assert len(lines) == 2 and all('dateShanghai' in line for line in lines)
    assert lines[0]['code'] == 'B'
    print('Interop passed: shared account reservation, system lock, schema preservation, two-language journal append')
