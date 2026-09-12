#!/usr/bin/env python3
"""Run isolated engine fixtures against a staged Resources/TokenMonitorEngine."""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess, tempfile, os
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--resource-root', type=Path, required=True)
parser.add_argument('--trusted-receipt', type=Path,
                    help='External build receipt binding the pinned binary before and after signing')
args = parser.parse_args()
resource = args.resource_root.resolve()
arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'AMD64': 'x64'}.get(platform.machine())
key = ('darwin-' if platform.system() == 'Darwin' else 'linux-') + str(arch)
pins = json.loads((here/'tokscale-pin.json').read_text())['platformSha256']
if key not in pins:
    parser.error('this runner has no reviewed binary pin for the host platform')
entry = pins[key]
binary = resource/'vendor/node_modules'/entry['package']/'bin/tokscale'
if not binary.is_file():
    parser.error('staged native scanner is missing')
actual = hashlib.sha256(binary.read_bytes()).hexdigest()
if actual != entry['sha256']:
    receipt = args.trusted_receipt
    if receipt is None or not receipt.is_file() or receipt.is_symlink() or receipt.resolve().is_relative_to(resource):
        parser.error('signed scanner requires an external trusted build receipt')
    record = json.loads(receipt.read_text())
    binding = record.get('nativeFiles', {}).get(binary.relative_to(resource).as_posix(), {})
    if record.get('architecture') != arch or binding.get('pre', {}).get('sha256') != entry['sha256'] or binding.get('post', {}).get('sha256') != actual:
        parser.error('staged native scanner does not match the pinned pre/post signing receipt')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True, timeout=20)
node = resource/'runtime/node'
if not node.is_file() or not os.access(node, os.X_OK):
    parser.error('staged executable runtime/node is missing')
with tempfile.TemporaryDirectory(prefix='token-monitor-engine-tests-') as temp:
    temp = Path(temp)
    engine = temp/'engine'
    engine.mkdir()
    for name in ['bridge.cjs', 'lib', 'hooks', 'vendor', 'provenance.json']:
        source = resource/name
        if source.is_dir(): shutil.copytree(source, engine/name)
        elif source.is_file(): shutil.copy2(source, engine/name)
        else: parser.error('required reviewed engine source or metadata is missing: '+name)
    shutil.copytree(resource/'upstream', temp/'upstream')
    shutil.copytree(here/'cases', engine/'tests')
    (temp/'qa').mkdir()
    # The preload belongs only to the test package. Production bridge ignores fixture env flags.
    tests = sorted((engine/'tests').glob('*.test.cjs'))
    subprocess.run([str(node), '--require', str(engine/'tests/helpers/bootstrap.cjs'), '--test']+[str(t) for t in tests], cwd=temp, check=True, timeout=180)
