#!/usr/bin/env python3
"""Copy a verified runtime only; sign its native code before the enclosing app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify(root):
    root = root.resolve(strict=True)
    manifest = json.loads((root / 'runtime-manifest.json').read_text())
    if manifest.get('relocationIssues') != [] or not manifest.get('nativeFiles'):
        raise ValueError('A finalized native audit with no unresolved dependencies is required')
    expected = set()
    for row in manifest['files']:
        path = root / row['file']
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError('Invalid or missing runtime inventory file')
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Runtime inventory changed after finalization')
        expected.add(row['file'])
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
    if actual != expected | {'runtime-manifest.json'}:
        raise ValueError('Uninventoried runtime files; use a fresh finalized candidate')
    for path in root.rglob('*'):
        if path.is_symlink() and (not path.exists() or os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(root)):
            raise ValueError('Runtime has a dangling, external or absolute symlink')
    if (root / 'install-private.log').exists() or (root / 'Model').exists() or (root / 'models').exists():
        raise ValueError('Build logs and model data do not belong in the runtime bundle')
    if any(p.name in ('weights.safetensors', 'weights.npz') for p in root.rglob('*')):
        raise ValueError('Model weights must remain in the separately verified application-support store')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--entitlements', type=Path)
    args = parser.parse_args()
    source = args.runtime.resolve(strict=True)
    verify(source)
    app = args.app.resolve(strict=True)
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        raise ValueError('Existing fresh app bundle required')
    target = app / 'Contents/Resources/ASRRuntime'
    if target.exists() or target.is_symlink():
        raise ValueError('ASRRuntime already exists; use a fresh app build')
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.parent.resolve().is_relative_to(app):
        raise ValueError('App resources resolve outside the app bundle')
    shutil.copytree(source, target, symlinks=True)
    manifest = verify(target)
    signer = Path(__file__).with_name('sign_runtime.py')
    command = [sys.executable, '-I', '-B', str(signer), '--runtime', str(target), '--identity', args.identity]
    if args.entitlements:
        command.extend(['--entitlements', str(args.entitlements.resolve(strict=True))])
    subprocess.run(command, check=True)
    print(json.dumps(dict(runtimeEmbedded=True, nativeFiles=len(manifest['nativeFiles']),
                         modelWeightsEmbedded=False, enclosingAppSigned=False)))


if __name__ == '__main__':
    main()
