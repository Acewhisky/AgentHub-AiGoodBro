#!/usr/bin/env python3
"""Compile current production projections, with synthetic metadata only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Sources/CodexUsageWidget'
BUILD = ROOT / 'task-test-outputs/statistics-integration'


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    target = BUILD / 'statistics-fixture'
    subprocess.run(['python3', 'scripts/check-build-target-idle.py', str(target.relative_to(ROOT))], cwd=ROOT, check=True)
    usage = (SOURCE / 'UI/UsageSurfaceTableView.swift').read_text().split('struct UsageSurfaceTableView: View {')[0]
    usage = usage.replace('import SwiftUI', 'import Foundation')
    profile = (SOURCE / 'Domain/LocalCLIAccount.swift').read_text().split('struct LocalCLIQuotaWindow:')[0]
    with tempfile.TemporaryDirectory(prefix='statistics-source-tests-') as temporary:
        temporary = Path(temporary)
        for name, source in [('usage', usage), ('sources', profile)]:
            code = temporary / 'main.swift'
            checks = 'UsageSurfaceProjectionChecks.swift' if name == 'usage' else 'StatisticsSourcesChecks.swift'
            code.write_text(source + '\n' + (ROOT / 'tests' / checks).read_text())
            inputs = [str(code)]
            if name == 'sources':
                inputs += [str(SOURCE / 'Domain/TokenMonitorEngineModels.swift'), str(SOURCE / 'Services/TokenMonitorEngine.swift'), str(SOURCE / 'Services/StatisticsSources.swift')]
            subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-module-cache-path', str(temporary / 'modules'), *inputs, '-o', str(target)], check=True)
            subprocess.run([str(target), str(ROOT / 'Companion/TokenMonitorEngine/client-catalog.json')], check=True, timeout=20)


if __name__ == '__main__':
    main()
