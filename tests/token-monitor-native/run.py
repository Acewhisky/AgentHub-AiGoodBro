#!/usr/bin/env python3
"""Offline native regression suite. Requires macOS/Xcode CLI tools; installs nothing."""
from pathlib import Path
import argparse, subprocess, tempfile, sys
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--repo-root', type=Path, default=here.parents[1])
parser.add_argument('--suite', choices=['all', 'engine', 'routing', 'selection', 'interop'], default='all')
args = parser.parse_args()
repo = args.repo_root.resolve()
source = repo/'Sources/CodexUsageWidget'
if not (source/'Domain/TokenMonitorEngineModels.swift').is_file():
    parser.error('repo root must contain the production Sources tree')
def run(command):
    subprocess.run([str(x) for x in command], cwd=repo, check=True, timeout=180)
with tempfile.TemporaryDirectory(prefix='token-monitor-native-tests-') as temp:
    temp = Path(temp)
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()
    compiler = ['xcrun', 'swiftc', '-sdk', sdk, '-target', arch+'-apple-macosx13.0', '-module-cache-path', temp/'module-cache']
    models = source/'Domain/TokenMonitorEngineModels.swift'
    engine = source/'Services/TokenMonitorEngine.swift'
    suites = ['engine', 'routing', 'selection', 'interop'] if args.suite == 'all' else [args.suite]
    for suite in suites:
        if suite == 'engine':
            run(['clang', '-mmacosx-version-min=13.0', here/'engine-helper.c', '-o', temp/'helper'])
            run([sys.executable, here/'extract-production-seams.py', temp/'ProductionSeams.swift'])
            run(compiler+[models, engine, temp/'ProductionSeams.swift', here/'EngineFixture.swift', '-o', temp/'engine-fixture'])
            run([temp/'engine-fixture', temp/'helper'])
        elif suite == 'routing':
            run([sys.executable, here/'extract-routing.py', temp/'RoutingSeams.swift'])
            run(compiler+[models, temp/'RoutingSeams.swift', here/'RoutingFixture.swift', '-o', temp/'routing-fixture'])
            run([temp/'routing-fixture'])
        elif suite == 'selection':
            run([sys.executable, here/'test-source-selection.py', repo])
        else:
            run(compiler+[models, engine, here/'BridgeCompatibility.swift', '-o', temp/'interop-fixture'])
            run([temp/'interop-fixture', here/'fixtures'])
