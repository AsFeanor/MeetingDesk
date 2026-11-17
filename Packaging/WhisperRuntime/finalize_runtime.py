#!/usr/bin/env python3
"""Reaudit a built candidate only after every pre-manifest file hash matches."""
import argparse
import json
import os
from pathlib import Path
from build_runtime import sha
from native_audit import cleanup_runtime, native_inventory


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    a = p.parse_args()
    root = a.runtime.resolve(strict=True)
    manifest_path = root / 'runtime-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schemaVersion') != 1 or not manifest.get('files'):
        raise ValueError('Versioned complete source manifest required')
    expected = {row['file'] for row in manifest['files']} | {'runtime-manifest.json'}
    actual = {str(path.relative_to(root)) for path in root.rglob('*')
              if path.is_file() and not path.is_symlink()}
    if actual != expected:
        raise ValueError('Candidate has missing or uninventoried files; no transforms applied')
    # No edits or native tools run until the entire original candidate verifies.
    for row in manifest['files']:
        path = root / row['file']
        if (not path.resolve().is_relative_to(root) or path.is_symlink() or not path.is_file()
                or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']):
            raise ValueError('Candidate differs from its pre-manifest; no transforms applied')
    before_manifest = sha(manifest_path)
    transforms = cleanup_runtime(root, sha, torch_expected=any(w['package'].lower() == 'torch' for w in manifest['packages']))
    natives, issues = native_inventory(root)
    manifest['nativeFiles'] = natives
    manifest['relocationIssues'] = issues
    manifest['nativeTransforms'] = manifest.get('nativeTransforms', []) + transforms
    manifest['preFinalizeManifestSHA256'] = before_manifest
    manifest['files'] = [{'file': str(f.relative_to(root)), 'sha256': sha(f), 'bytes': f.stat().st_size}
        for f in sorted(root.rglob('*')) if f.is_file() and not f.is_symlink() and f != manifest_path]
    temporary = manifest_path.with_name('runtime-manifest.json.part')
    with temporary.open('x') as output:
        json.dump(manifest, output, indent=2, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, manifest_path)
    print(json.dumps({'preManifestFilesVerified': len(manifest['files']), 'transforms': len(transforms),
        'nativeFiles': len(natives), 'relocationIssues': len(issues), 'inferenceRun': False}))
    if issues:
        raise SystemExit('Unresolved real native load paths remain; inspect updated manifest')


if __name__ == '__main__':
    main()
