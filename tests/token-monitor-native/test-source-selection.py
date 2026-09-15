from pathlib import Path
import subprocess, tempfile, sys
root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
source = (root/'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
start = source.index('    func configureStatisticsSources(')
opening=source.index('{', start); depth=1; end=opening+1
while depth:
    depth += (source[end]=='{') - (source[end]=='}'); end+=1
configure=source[start:end]
line=next(line.strip() for line in source.splitlines() if 'let candidates = statisticsIncludesManagedCodex ?' in line)
fixture='''import Foundation
final class StoreFixture {
    var engineLocalSources: [TokenMonitorSource] = []
    var statisticsIncludesManagedCodex = true
    var hasStarted = false
    var cancelled = 0
    var refreshed = 0
    func cancelStatisticsEngine() { cancelled += 1 }
    func refresh(queueIfBusy: Bool) { refreshed += 1 }
''' + configure + '''
    struct Profile { let id: String; let isSystemProfile: Bool }
    var profiles = [Profile(id: "system", isSystemProfile: true), Profile(id: "managed", isSystemProfile: false)]
    func candidates() -> [Profile] {
''' + line + '''
        return candidates
    }
}
@main struct Main {
 static func main() throws {
  let s = StoreFixture()
  precondition(s.candidates().map(\\.id) == ["managed"])
  print("PASS default managed Codex inclusion")
  try s.configureStatisticsSources([], includeManagedCodex: false)
  precondition(s.candidates().isEmpty && s.cancelled == 1)
  print("PASS disabled Codex yields no managed usage sources")
  s.hasStarted = true
  try s.configureStatisticsSources([])
  precondition(s.candidates().map(\\.id) == ["managed"] && s.cancelled == 2 && s.refreshed == 1)
  print("PASS enabled default restores managed usage and refreshes")
  let bad = TokenMonitorSource(id: "custom", providerId: "codex", kind: .custom, canonicalPath: "/tmp/synthetic-custom.json", pathRole: .customFile, toolId: "codex", authority: .custom)
  do { try s.configureStatisticsSources([bad], includeManagedCodex: false); fatalError("invalid authority accepted") }
  catch TokenMonitorFailure.invalidSource { }
  precondition(s.candidates().map(\\.id) == ["managed"] && s.cancelled == 2)
  print("PASS rejected configuration preserves previous inclusion state")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='token-monitor-selection-') as tmp:
 p=Path(tmp); (p/'Fixture.swift').write_text(fixture)
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 arch=subprocess.check_output(['uname','-m'],text=True).strip()
 subprocess.run(['swiftc','-sdk',sdk,'-target',arch+'-apple-macosx13.0','-module-cache-path',str(p/'cache'),str(root/'Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift'),str(root/'Sources/CodexUsageWidget/Services/TokenMonitorEngine.swift'),str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True)
