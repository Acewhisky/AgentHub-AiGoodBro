#!/usr/bin/env python3
"""Offline extracted-production tests; no live credentials, subprocess login or network.
Run --baseline first, then candidate. --emit-only generates portable Swift without compiling.
"""
import argparse
import subprocess
from pathlib import Path
import importlib.util
import tempfile
spec = importlib.util.spec_from_file_location("auth_stability", Path(__file__).with_name("test-auth-stability.py"))
regression = importlib.util.module_from_spec(spec)
spec.loader.exec_module(regression)
extract = regression.extract_declaration
ROOT = Path(__file__).resolve().parent.parent
SERVICES = Path("Sources/CodexUsageWidget/Services")


def fixture(baseline):
    source_root = ROOT / "task-test-outputs/credential-generation/baseline" if baseline else ROOT
    store = (source_root / SERVICES / "CodexProfileStore.swift").read_text()
    actions = (source_root / SERVICES / "CodexAccountActions.swift").read_text()
    reader = "enum CodexOfficialProfileReader {\n" + "\n".join(extract(store, needle) for needle in [
        "static func credentialIdentity(fromAuthData", "private static func claims(fromToken",
        "private static func accountID(in", "private static func normalizedEmail(_", "private static func nonEmpty(_"
    ]) + "\n}"
    methods = extract(store, "func syncSystemAuthToMatchingManagedProfiles()") + "\n" + extract(store, "private func writeAuth(")
    recovery = "enum CodexAccountActions {\n" + "\n".join(extract(actions, needle) for needle in [
        "fileprivate enum AuthState:", "fileprivate struct PendingSwitchJournal:",
        "fileprivate enum PendingSwitchRecoveryDecision:", "fileprivate static func authFingerprint(",
        "fileprivate static func identityDigest(for identity:", "fileprivate static func identityDigest(for state:",
        "fileprivate static func pendingSwitchRecoveryDecision("
    ]) + "\n}"
    helper = "" if baseline else (ROOT / SERVICES / "CodexCredentialTransaction.swift").read_text()
    rollback = extract(actions, "private static func restoreAuth(_ data: Data?").replace("private static", "static") if baseline else "" 
    return STUBS + reader + "\n" + recovery + "\n" + extract(actions, "enum CodexCredentialAccessGate") + "\n" + helper + "\nclass Store {\n" + STORE + methods + "\n" + rollback + "\n}\n" + TESTS + (BASELINE if baseline else CANDIDATE) + '\nprint("failures: \(failures)"); exit(failures == 0 ? 0 : 1)\n'


STUBS = r'''
import Foundation
import CryptoKit
struct CodexCredentialIdentity: Equatable { let email: String; let accountID: String }
struct Snapshot { var accountID: String? }
struct CodexProfile {
    var isSystemProfile: Bool
    var codexHomeURL: URL
    var recordedAccountKey = "fixture@example.invalid"
    var lastSnapshot: Snapshot? = Snapshot(accountID: "workspace-a")
}
enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool = false) throws -> Data? {
        if !FileManager.default.fileExists(atPath: url.path), allowMissing { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
'''
STORE = r'''
    struct State { var profiles: [CodexProfile] }
    var state: State
    let managedRootURL: URL
    let fileManager = FileManager.default
    init(source: URL, target: URL, root: URL) {
        state = State(profiles: [CodexProfile(isSystemProfile: true, codexHomeURL: source), CodexProfile(isSystemProfile: false, codexHomeURL: target)])
        managedRootURL = root
    }
'''
TESTS = r'''
var failures = 0
func check(_ name: String, _ operation: () throws -> Bool) {
    do { if try operation() { print("PASS " + name) } else { failures += 1; print("FAIL " + name) } }
    catch { failures += 1; print("FAIL " + name + " (error)") }
}
func jwt(_ claims: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "fixture." + data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".synthetic"
}
func bundle(_ generation: Int, session: String = "session-a", account: String = "workspace-a") throws -> Data {
    let claims: [String: Any] = ["email": "fixture@example.invalid", "account_id": account, "sid": session, "sub": "fixture-subject", "auth_time": 100, "iat": generation]
    return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": jwt(claims), "id_token": jwt(claims), "refresh_token": "synthetic-refresh-\(generation)-\(session)", "account_id": account], "last_refresh": "fixture", "bundle_marker": generation], options: [.sortedKeys])
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("credential-fixture-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("source"), managed = root.appendingPathComponent("managed"), target = managed.appendingPathComponent("target")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: target, withIntermediateDirectories: true)
let sourceURL = source.appendingPathComponent("auth.json"), targetURL = target.appendingPathComponent("auth.json")
let old = try bundle(200), newer = try bundle(300), later = try bundle(400)
func seed(_ src: Data, _ dst: Data?, sourceTime: Double = 20, targetTime: Double = 10) throws {
    try src.write(to: sourceURL, options: .atomic)
    if let dst { try dst.write(to: targetURL, options: .atomic) } else if fm.fileExists(atPath: targetURL.path) { try fm.removeItem(at: targetURL) }
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: sourceTime)], ofItemAtPath: sourceURL.path)
    if dst != nil { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: targetTime)], ofItemAtPath: targetURL.path) }
}
let store = Store(source: source, target: target, root: managed)
check("newer mtime cannot replace newer credentials") {
    try seed(old, newer); try store.syncSystemAuthToMatchingManagedProfiles()
    return try Data(contentsOf: targetURL) == newer
}
check("independent session preserved") {
    try seed(bundle(400, session: "independent"), newer); try store.syncSystemAuthToMatchingManagedProfiles()
    return try Data(contentsOf: targetURL) == newer
}
check("equal mtime legitimate newer full bundle") {
    try seed(newer, old, sourceTime: 20, targetTime: 20); try store.syncSystemAuthToMatchingManagedProfiles()
    return try Data(contentsOf: targetURL) == newer
}
check("missing destination import") {
    try seed(newer, nil); try store.syncSystemAuthToMatchingManagedProfiles()
    return try Data(contentsOf: targetURL) == newer
}
check("same email different workspace preserved") {
    let other = try bundle(200, account: "workspace-b")
    try seed(newer, other)
    do { try store.syncSystemAuthToMatchingManagedProfiles() } catch {}
    return try Data(contentsOf: targetURL) == other
}
'''
TESTS += r'''
check("recovery preserves rotated original; cross-account target still rolls back") {
    let other = try bundle(300, account: "workspace-b")
    let otherLater = try bundle(400, account: "workspace-b")
    let unrelated = try bundle(500, account: "workspace-c")
    let journal = CodexAccountActions.PendingSwitchJournal(
        originalAuth: .data(old), targetAuthFingerprint: CodexAccountActions.authFingerprint(other),
        targetIdentity: CodexOfficialProfileReader.credentialIdentity(fromAuthData: other)!,
        originalCodexWasRunning: false, originalDaemonWasRunning: false)
    return CodexAccountActions.pendingSwitchRecoveryDecision(current: .data(later), journal: journal) == .originalAlreadyPresent
        && CodexAccountActions.pendingSwitchRecoveryDecision(current: .data(otherLater), journal: journal) == .rollbackOriginal
        && CodexAccountActions.pendingSwitchRecoveryDecision(current: .data(unrelated), journal: journal) == .preserveExternal
}
'''
BASELINE = r'''
check("same account later login rollback preserved") {
    try seed(old, later)
    Store.restoreAuth(old, at: targetURL, fileManager: fm)
    return try Data(contentsOf: targetURL) == later
}
'''
CANDIDATE = r'''
let identity = CodexOfficialProfileReader.credentialIdentity(fromAuthData: newer)!
func copy(_ expected: Data = newer, hook: () throws -> Void = {}) throws -> CodexCredentialTransaction.CopyOutcome {
    try CodexCredentialTransaction.copy(from: source, to: target, managedRoot: managed, expectedSource: expected, identity: identity, beforeReplace: hook)
}
check("source rotates after initial snapshot") {
    try seed(later, old)
    do { _ = try copy(); return false } catch {}
    return try Data(contentsOf: targetURL) == old
}
check("source rotates immediately before replace") {
    try seed(newer, old)
    do { _ = try copy { try later.write(to: sourceURL, options: .atomic) }; return false } catch {}
    return try Data(contentsOf: targetURL) == old
}
check("target rotates immediately before replace") {
    try seed(newer, old)
    do { _ = try copy { try later.write(to: targetURL, options: .atomic) }; return false } catch {}
    return try Data(contentsOf: targetURL) == later
}
check("source identity drift before replace") {
    try seed(newer, old)
    do { _ = try copy { try bundle(400, account: "workspace-b").write(to: sourceURL, options: .atomic) }; return false } catch {}
    return try Data(contentsOf: targetURL) == old
}
check("equal issuance different bundle ambiguous") {
    var object = try JSONSerialization.jsonObject(with: newer) as! [String: Any]
    object["bundle_marker"] = 999
    let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return !CodexCredentialTransaction.permitsReplacement(source: changed, target: newer)
}
check("mixed account fields rejected") {
    var object = try JSONSerialization.jsonObject(with: newer) as! [String: Any]
    var tokens = object["tokens"] as! [String: Any]; tokens["account_id"] = "workspace-b"; object["tokens"] = tokens
    let drift = try JSONSerialization.data(withJSONObject: object)
    return !CodexCredentialTransaction.permitsReplacement(source: drift, target: old)
}
check("duplicate symlink home gate and self copy rejected") {
    let alias = root.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: target)
    guard CodexCredentialAccessGate.homeLock(forHomePath: alias.path) === CodexCredentialAccessGate.homeLock(forHomePath: target.path) else { return false }
    do { _ = try CodexCredentialTransaction.copy(from: alias, to: target, managedRoot: managed, expectedSource: newer, identity: identity); return false } catch { return true }
}
check("outside destination rejected") {
    do { _ = try CodexCredentialTransaction.copy(from: source, to: root.appendingPathComponent("outside"), managedRoot: managed, expectedSource: newer, identity: identity); return false } catch { return true }
}
check("same account later rollback preserved") {
    try seed(old, later)
    try CodexCredentialTransaction.restoreOwned(previous: old, written: newer, at: targetURL, fileManager: fm)
    return try Data(contentsOf: targetURL) == later
}
check("rollback absent previous does not delete later auth") {
    try seed(old, later)
    try CodexCredentialTransaction.restoreOwned(previous: nil, written: newer, at: targetURL, fileManager: fm)
    return try Data(contentsOf: targetURL) == later
}
check("cross account owned rollback restores original") {
    let other = try bundle(300, account: "workspace-b"); try seed(old, other)
    try CodexCredentialTransaction.restoreOwned(previous: old, written: other, at: targetURL, fileManager: fm)
    return try Data(contentsOf: targetURL) == old
}
check("rollback final expectation recheck") {
    try seed(old, newer)
    try CodexCredentialTransaction.restoreOwned(previous: old, written: newer, at: targetURL, fileManager: fm, beforeRestore: { try later.write(to: targetURL, options: .atomic) })
    return try Data(contentsOf: targetURL) == later
}
final class FailingRemoval: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
check("rollback failure remains visible") {
    try seed(old, newer)
    do { try CodexCredentialTransaction.restoreOwned(previous: nil, written: newer, at: targetURL, fileManager: FailingRemoval()); return false }
    catch { return true }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--emit-only", action="store_true")
    args = parser.parse_args()
    build = ROOT / "task-test-outputs/credential-generation"
    build.mkdir(parents=True, exist_ok=True)
    label = "baseline" if args.baseline else "candidate"
    swift = build / (label + ".swift")
    swift.write_text(fixture(args.baseline))
    if args.emit_only:
        print(label + ": fixture emitted; not compiled or executed")
        return 0
    target = build / "CredentialGenerationFixture"
    guard = subprocess.run(["python3", "scripts/check-build-target-idle.py", str(target.relative_to(ROOT))], cwd=ROOT, capture_output=True, text=True)
    output = "idle guard: exit " + str(guard.returncode) + "\n" + guard.stdout + guard.stderr
    if guard.returncode:
        output += "compile and tests skipped: process state not verified\n"
        (build / (label + "-output.txt")).write_text(output)
        print(output, end="")
        return guard.returncode
    with tempfile.TemporaryDirectory(prefix="credential-compile-") as temporary:
        result = subprocess.run(["/usr/bin/swiftc", "-module-cache-path", temporary, str(swift), "-o", str(target)], capture_output=True, text=True)
        output += "compile: exit " + str(result.returncode) + "\n" + result.stdout + result.stderr
        if result.returncode == 0:
            result = subprocess.run([str(target)], capture_output=True, text=True)
            output += result.stdout + result.stderr
    (build / (label + "-output.txt")).write_text(output)
    print(output, end="")
    return result.returncode

if __name__ == "__main__":
    raise SystemExit(main())
