from pathlib import Path
import sys

def declaration(path, marker):
    text = Path(path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]

root = 'Sources/CodexUsageWidget/'
domain = root + 'Domain/UsageModels.swift'
parts = ['import Foundation']
for name in ['RateWindow', 'CreditsInfo', 'ResetCreditDetail', 'AccountInfo']:
    parts.append(declaration(domain, 'struct ' + name + ':'))
parts.append(declaration(root + 'Services/CCSwitchUsageReader.swift', 'enum CustomTokenSourceStore {'))
parts.append('struct CodexUsageReader {\n' + declaration(root + 'Services/CodexUsageReader.swift', 'struct AppServerSnapshot {') + '\n}')
Path(sys.argv[1]).write_text('\n'.join(parts))
