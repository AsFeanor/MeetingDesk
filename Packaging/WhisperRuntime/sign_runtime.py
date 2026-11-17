#!/usr/bin/env python3
"""Explicit inside-out signing hook. Sign enclosing .app separately afterward."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--identity', required=True)
    p.add_argument('--entitlements', type=Path)
    a = p.parse_args()
    manifest = json.loads((a.runtime / 'runtime-manifest.json').read_text())
    if manifest['relocationIssues']:
        raise ValueError('Resolve native relocation findings before signing')
    paths = sorted((a.runtime / r['file'] for r in manifest['nativeFiles']), key=lambda p: len(p.parts), reverse=True)
    for path in paths:
        command = ['/usr/bin/codesign', '--force', '--sign', a.identity]
        if a.identity != '-':
            command.extend(['--options', 'runtime', '--timestamp'])
        # Explicit entitlements only; do not silently disable library validation or add JIT rights.
        if a.entitlements:
            command += ['--entitlements', str(a.entitlements)]
        subprocess.run(command + [str(path)], check=True)
    for path in paths:
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True)
    def digest(path):
        h = hashlib.sha256()
        with path.open('rb') as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b''):
                h.update(block)
        return h.hexdigest()
    # Code signatures alter Mach-O bytes. Preserve the pre-sign inventory and record current bytes separately.
    result = {'schemaVersion': 1, 'identity': a.identity, 'enclosingAppSigned': False,
        'signedRelocationPassed': False, 'nativeFiles': [
            {'file': str(path.relative_to(a.runtime)), 'sha256': digest(path)} for path in paths]}
    (a.runtime / 'runtime-signatures.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'signedNativeFiles': len(paths), 'enclosingAppSigned': False,
                      'signedRelocationPassed': False, 'manifestHashesPreSigning': True}))


if __name__ == '__main__':
    main()
