#!/usr/bin/env python3
"""Offline B2 production helper/caller fixtures. --baseline retains the P1 reproduction.
Only synthetic temporary homes are used. Guard must pass before any Swift compilation.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'task-test-outputs/credential-compatibility'
SERVICES = Path('Sources/CodexUsageWidget/Services')
spec = importlib.util.spec_from_file_location('generation', ROOT / 'scripts/test-credential-generation.py')
generation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generation)

EXTRA = r'''
struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ first: String, _ second: String) -> String { second }
}
extension CodexProfile {
    func matchesRecordedCredential(_ identity: CodexCredentialIdentity?) -> Bool {
        identity == CodexCredentialIdentity(email: recordedAccountKey, accountID: lastSnapshot!.accountID!)
    }
}
final class ControlledHome: FileManager, @unchecked Sendable {
    override var homeDirectoryForCurrentUser: URL { root }
}
func withoutLineage(_ data: Data) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var tokens = object["tokens"] as! [String: Any]
    let claims: [String: Any] = ["email": "fixture@example.invalid", "account_id": "workspace-a"]
    tokens["access_token"] = try jwt(claims); tokens["id_token"] = try jwt(claims)
    object["tokens"] = tokens
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
func editToken(_ data: Data, _ key: String, _ value: String?) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var tokens = object["tokens"] as! [String: Any]
    tokens[key] = value; object["tokens"] = tokens
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
func backup(_ data: Data) throws {
    try CodexAccountActions.writeManagedAuthBackup(.data(data), to: store.state.profiles[1], sourceHome: source, fileManager: ControlledHome())
}
'''
COMMON = r'''
for (label, src, dst) in [
    ("independent valid session", try bundle(400, session: "independent"), newer),
    ("missing lineage source", try withoutLineage(newer), old),
    ("missing lineage target", newer, try withoutLineage(old))
] {
    check("actual caller continues: " + label) {
        try seed(src, dst); try backup(src)
        return try Data(contentsOf: targetURL) == dst
    }
}
'''
CANDIDATE = r'''
for (label, src, dst, outcome) in [
    ("missing target", newer, nil, CodexCredentialTransaction.CopyOutcome.copied),
    ("identical", newer, newer, .unchanged),
    ("newer lineage", newer, old, .copied),
    ("older lineage", old, newer, .preservedValidExisting),
    ("independent", try bundle(400, session: "independent"), newer, .preservedValidExisting),
    ("no lineage", try withoutLineage(newer), try withoutLineage(old), .preservedValidExisting),
    ("equal issuance different bytes", try editToken(newer, "refresh_token", "synthetic-different"), newer, .preservedValidExisting)
] as [(String, Data, Data?, CodexCredentialTransaction.CopyOutcome)] {
    check("typed outcome: " + label) {
        try seed(src, dst)
        let result = try copy(src)
        try backup(src)
        return try result == outcome && Data(contentsOf: targetURL) == (outcome == .copied ? src : dst!)
    }
}
for key in ["access_token", "refresh_token"] {
    for (label, value) in [("missing", nil), ("empty", ""), ("whitespace", " \n\t ")] as [(String, String?)] {
        for isSource in [true, false] {
            check("reject " + (isSource ? "source " : "target ") + key + " " + label) {
                let bad = try editToken(newer, key, value)
                let src = isSource ? bad : newer, dst = isSource ? old : bad
                try seed(src, dst)
                do { try backup(src); return false } catch {}
                return try Data(contentsOf: targetURL) == dst
            }
        }
    }
}
let absentIdentity = try editToken(newer, "id_token", nil)
let mixedIdentity = try editToken(newer, "access_token", jwt(["email": "fixture@example.invalid", "account_id": "workspace-b"]))
let mixedEmail = try editToken(newer, "access_token", jwt(["email": "other@example.invalid", "account_id": "workspace-a"]))
for (label, bad) in [("absent identity", absentIdentity), ("workspace conflict", try bundle(300, account: "workspace-b")), ("mixed identity", mixedIdentity), ("mixed email", mixedEmail), ("malformed", Data("{".utf8))] {
    for isSource in [true, false] {
        check("reject " + (isSource ? "source " : "target ") + label) {
            let src = isSource ? bad : newer, dst = isSource ? old : bad
            try seed(src, dst)
            do { _ = try copy(src); return false } catch {}
            return try Data(contentsOf: targetURL) == dst
        }
    }
}
for dst in [newer, try bundle(400, session: "independent")] {
    for changeSource in [true, false] {
        check("no-op expectation race " + (changeSource ? "source" : "target")) {
            try seed(newer, dst)
            do {
                _ = try copy { try later.write(to: changeSource ? sourceURL : targetURL, options: .atomic) }
                return false
            } catch { return true }
        }
    }
}
for dst in [old, newer, try bundle(400, session: "independent")] {
    for component in ["source", "target", "root"] {
        check("canonical root race " + component) {
            try seed(newer, dst)
            let link = root.appendingPathComponent("controlled-link")
            let original = component == "source" ? source : (component == "target" ? target : managed)
            try fm.createSymbolicLink(at: link, withDestinationURL: original)
            defer { try? fm.removeItem(at: link) }
            do {
                _ = try CodexCredentialTransaction.copy(
                    from: component == "source" ? link : source,
                    to: component == "target" ? link : target,
                    managedRoot: component == "root" ? link : managed,
                    expectedSource: newer, identity: identity,
                    beforeReplace: {
                        try fm.removeItem(at: link)
                        try fm.createSymbolicLink(at: link, withDestinationURL: root)
                    })
                return false
            } catch { return true }
        }
    }
}
check("incomplete source cannot create target") {
    let bad = try editToken(newer, "refresh_token", " \t")
    try seed(bad, nil)
    do { _ = try copy(bad); return false } catch {}
    return !fm.fileExists(atPath: targetURL.path)
}
check("invalid root actual caller throws") {
    try seed(newer, old)
    var profile = store.state.profiles[1]; profile.codexHomeURL = source
    do { try CodexAccountActions.writeManagedAuthBackup(.data(newer), to: profile, sourceHome: source, fileManager: ControlledHome()); return false } catch { return true }
}
'''

def fixture(baseline):
    source = BUILD / 'baseline' if baseline else ROOT
    generation.ROOT = source
    swift = generation.fixture(False)
    generation.ROOT = ROOT
    if baseline:
        swift = swift.replace('throws -> CodexCredentialTransaction.CopyOutcome', 'throws -> Bool')
    actions = (source / SERVICES / 'CodexAccountActions.swift').read_text()
    caller = generation.extract(actions, 'private static func writeManagedAuthBackup(').replace('private static', 'fileprivate static', 1)
    swift = swift.replace('enum CodexAccountActions {', 'enum CodexAccountActions {\nstatic func switchError(_ text: String) -> Error { CocoaError(.fileReadCorruptFile) }\n' + caller, 1)
    swift = swift.replace('managed = root.appendingPathComponent("managed")', 'managed = root.appendingPathComponent(".codex-account-manager-next/profiles")')
    end = swift.index('\nprint("failures:')
    return swift[:end] + EXTRA + COMMON + ('' if baseline else CANDIDATE) + swift[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--emit-only', action='store_true')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    label = 'baseline' if args.baseline else 'candidate'
    swift = BUILD / (label + '.swift')
    swift.write_text(fixture(args.baseline))
    if args.emit_only:
        print(label + ': production fixture emitted; execution pending host')
        return 0
    target = BUILD / 'target'
    guard = subprocess.run(['python3', 'scripts/check-build-target-idle.py', str(target.relative_to(ROOT))], cwd=ROOT, capture_output=True, text=True)
    output = 'guard exit: ' + str(guard.returncode) + '\n' + guard.stdout + guard.stderr
    result = guard
    if guard.returncode == 0:
        with tempfile.TemporaryDirectory(prefix='credential-compatibility-') as cache:
            result = subprocess.run(['/usr/bin/swiftc', '-module-cache-path', cache, str(swift), '-o', str(target)], capture_output=True, text=True)
            output += 'compile exit: ' + str(result.returncode) + '\n' + result.stdout + result.stderr
            if result.returncode == 0:
                result = subprocess.run([str(target)], capture_output=True, text=True)
                output += result.stdout + result.stderr
    else:
        output += 'compile/tests skipped: process state unverified\n'
    output = output.replace(str(ROOT), '<workspace>')
    (BUILD / (label + '-output.txt')).write_text(output)
    print(output, end='')
    return result.returncode

if __name__ == '__main__':
    raise SystemExit(main())
