#!/usr/bin/env python3
"""Extract actual production pure Swift. All arbitrary text below is synthetic.
No GUI, translation engine, account data, notification or network access.
"""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'task-test-outputs/public-reset-translation'
SERVICE = Path('Sources/CodexUsageWidget/Services/PublicResetAnnouncements.swift')
MODEL = Path('Sources/CodexUsageWidget/Services/PublicResetTranslation.swift')
UI = Path('Sources/CodexUsageWidget/UI/PublicResetAnnouncementView.swift')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--static-only', action='store_true')
    parser.add_argument('--baseline-file', type=Path, help='Optional preserved original service for protected-scope comparison')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    candidate = (ROOT / SERVICE).read_text()
    if args.baseline_file:
        baseline = args.baseline_file.read_text()
        assert baseline.split('    func title(')[0] == candidate.split('    func title(')[0]
        # Current-page publication and matching self-test assertions are authorized
        # host additions. Retrieval, DTO/schema and durable delivery remain exact.
        def protected(source, start, end):
            return source.split(start, 1)[1].split(end, 1)[0]
        for start, end in [('struct PublicResetPage:', 'final class PublicResetAnnouncementMonitor:'),
                           ('    private func load(', '    @MainActor\n    func check()'),
                           ('    /// Separate durable ledger', '    /// Read the same bounded feed page')]:
            if end in baseline:
                assert protected(baseline, start, end) == protected(candidate, start, end)
            else:
                # The new fixture precedes the unchanged original MainActor test.
                assert protected(baseline, start, '    /// Invoke delivery from a detached task') == protected(candidate, start, end)
        print('PASS optional baseline: protected DTO, retrieval and delivery remain exact')
    model = (ROOT / MODEL).read_text()
    assert all(word not in model for word in ['monitor', 'URLSession', 'UserDefaults', 'FileManager', 'Notification', 'Ledger'])
    ui = (ROOT / UI).read_text()
    adapter = ui.split('/// Identity resets', 1)[1]
    assert all(word not in adapter for word in ['monitor.', '.check()', 'URLSession', 'Ledger', 'Notification'])
    assert '.translationTask(configuration)' in adapter
    assert 'session.prepareTranslation()' in adapter and 'session.translate(request.original)' in adapter
    assert 'TranslationSession(' not in adapter
    assert 'Task.checkCancellation()' in adapter and '.id(request.generation)' in adapter
    print('PASS static: translation has no monitor, ledger or notification callbacks')
    pure = model.split('@MainActor', 1)[0].replace('import Combine\n', '')
    methods = candidate.split('    func title(', 1)[1].split('    func summary(', 1)[0]
    fixture = pure + '''
// Synthetic language shell, with ACTUAL production title/meaning methods below.
enum WidgetLanguage {
    case chinese
    static func storedOrAutomatic() -> Self { .chinese }
    func text(_ chinese: String, _ english: String) -> String { chinese }
}
struct SyntheticAnnouncement {
    let text: String
    func title(''' + methods + '''
}
''' + r'''
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fatalError("FAIL: " + label) }
    print("PASS: " + label)
}
let exact = "Reset all propagated. Sweet dreams."
check(PublicResetTranslationModel.vettedTranslation(exact) == "额度重置已全部完成。晚安，好梦。", "exact vetted public cache")
for altered in [exact.lowercased(), exact + " ", " " + exact, exact + "\n", "Reset all propagated. Sweet dreams!", "Reset all propagated.  Sweet dreams."] {
    check(PublicResetTranslationModel.vettedTranslation(altered) == nil, "altered bytes never cached")
}
let original = "Synthetic: we will do a reset today. Lands end of day."
let possible = "Synthetic: credits might become available."
for value in [original, possible] {
    check(PublicResetTranslationModel.vettedTranslation(value) == nil, "arbitrary forecast has no invented translation")
    check(PublicResetTranslationModel.isForecast(value), "forecast modality")
    check(SyntheticAnnouncement(text: value).title().contains("尚未确认"), "production forecast title")
    check(SyntheticAnnouncement(text: value).meaning().contains("尚未确认完成"), "production forecast meaning")
}
check(SyntheticAnnouncement(text: "Synthetic unspecified announcement.").title() == "额度重置公告", "unspecified remains neutral")
typealias Model = PublicResetTranslationModel
let key = Model.Key(eventID: "synthetic-event", original: original)
check(key == Model.Key(eventID: "synthetic-event", original: original), "unchanged key reuse")
let changed = Model.Key(eventID: "synthetic-event", original: original + " ")
check(key != changed, "same ID changed exact hash")
check(key != Model.Key(eventID: "other-synthetic", original: original), "event isolation")
check(Model.Key(eventID: "synthetic", original: "é") != Model.Key(eventID: "synthetic", original: "e\u{301}"), "UTF8 canonical equivalence remains distinct")
var model = Model()
check(model.state(for: key, original: original) == .notRequested, "initial state")
check(model.begin(key: key, original: original, supported: false) == nil, "unsupported OS no request")
check(model.state(for: key, original: original) == .unavailable, "unsupported unavailable")
check(model.begin(key: changed, original: original, supported: true) == nil, "mismatched key refused")
let first = model.begin(key: key, original: original, supported: true)!
check(model.state(for: key, original: original) == .preparing, "prepare assets state")
check(model.begin(key: key, original: original, supported: true) == nil, "banner/detail deduplication")
model.prepared(first)
check(model.state(for: key, original: original) == .translating, "translating state")
model.cancel(first)
check(model.state(for: key, original: original) == .unavailable, "cancellation retry ready")
let retry = model.begin(key: key, original: original, supported: true)!
model.finish(first, source: original, translation: "synthetic late response")
model.cancel(first)
model.prepared(first)
check(model.owns(retry), "late success/failure/preparation cannot clear retry")
model.finish(retry, source: original + " ", translation: "synthetic mismatch")
check(model.state(for: key, original: original) == .unavailable, "source response mismatch")
let blank = model.begin(key: key, original: original, supported: true)!
model.finish(blank, source: original, translation: " \n")
check(model.state(for: key, original: original) == .unavailable, "blank response refused")
let old = model.begin(key: key, original: original, supported: true)!
model.cancel(old) // View identity disappears when source changes.
let new = model.begin(key: changed, original: original + " ", supported: true)!
model.finish(old, source: original, translation: "synthetic stale response")
model.cancel(old)
check(model.owns(new), "late old-event completion cannot affect changed text")
model.finish(new, source: original + " ", translation: "合成测试：可能会重置。")
check(model.state(for: changed, original: original + " ") == .translated("合成测试：可能会重置。", vetted: false), "mock success retains keyed result")
check(model.state(for: key, original: original) == .unavailable, "changed text never poisons old key")
check(model.begin(key: changed, original: original + " ", supported: true) == nil, "successful cache prevents duplicate OS request")
let vettedKey = Model.Key(eventID: "synthetic-vetted", original: exact)
check(model.state(for: vettedKey, original: exact) == .translated("额度重置已全部完成。晚安，好梦。", vetted: true), "vetted label even without OS support")
check(model.state(for: vettedKey, original: exact + " ") == .unavailable, "no mixing vetted cache with changed event text")
print("Pure model proof only: no real Apple translation engine exercised.")
'''
    (OUT / 'production-fixtures.swift').write_text(fixture)
    print('PASS fixture extraction: actual production model/title/meaning; synthetic adapter responses')
    if args.static_only:
        return 0
    guard = subprocess.run([sys.executable, 'scripts/check-build-target-idle.py',
                            'task-test-outputs/public-reset-translation/build/AiGoodBro.app/Contents/MacOS/AiGoodBro'],
                           cwd=ROOT, capture_output=True, text=True)
    (OUT / 'pure-guard.log').write_text(guard.stdout + guard.stderr)
    if guard.returncode:
        print('BLOCKED: process guard unverified; no compilation attempted')
        return 77
    commands = [
        ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', 'task-test-outputs/public-reset-translation/ModuleCache',
         'task-test-outputs/public-reset-translation/production-fixtures.swift', '-o', 'task-test-outputs/public-reset-translation/pure-tests'],
        ['task-test-outputs/public-reset-translation/pure-tests'],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        (OUT / f'pure-{index}.log').write_text(result.stdout + result.stderr)
        print(result.stdout, end='')
        if result.returncode:
            print('FAIL: see scoped raw log')
            return result.returncode
    return 0


if __name__ == '__main__':
    sys.exit(main())
