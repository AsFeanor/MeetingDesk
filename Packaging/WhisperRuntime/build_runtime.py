#!/usr/bin/env python3
"""Offline, fresh-prefix assembly from exact artifacts; does not import MLX or run ASR."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from urllib.parse import unquote, urlparse
from native_audit import native_inventory, cleanup_runtime, prune_console_entrypoints

HERE = Path(__file__).resolve().parent
MACH = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
        b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
STRATEGY = 'window-auto-20s-v1'
OPTIONS = dict(task='transcribe', language=None, temperature=0.0,
               word_timestamps=True, condition_on_previous_text=False,
               initial_prompt=None, verbose=False, fp16=True,
               compression_ratio_threshold=2.4, logprob_threshold=-1.0,
               no_speech_threshold=0.6)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def main():
    if sys.version_info < (3, 12):
        raise SystemExit('Run with the pinned Python3.12 builder; no model imports occur')
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--artifacts', type=Path, required=True)
    p.add_argument('--destination', type=Path, required=True)
    p.add_argument('--worker', type=Path, required=True)
    p.add_argument('--quality-accepted', action='store_true',
                   help='Record explicit human acceptance; does not imply runtime/release checks passed')
    a = p.parse_args()
    dest = a.destination.resolve()
    if dest.exists() or not a.worker.is_file():
        raise ValueError('Fresh destination and existing worker required')
    py = json.loads((HERE / 'python-provenance.json').read_text())
    wheel_proof = json.loads((HERE / 'wheel-provenance.json').read_text())
    rows = wheel_proof['artifacts']
    archive = a.artifacts / py['archive']
    if sha(archive) != py['archiveSHA256']:
        raise ValueError('Standalone Python checksum mismatch')
    wheels = []
    for row in rows:
        path = a.artifacts / Path(unquote(urlparse(row['url']).path)).name
        if sha(path) != row['sha256']:
            raise ValueError('Pinned wheel checksum mismatch')
        wheels.append(path.resolve())
    dest.mkdir(parents=True, mode=0o700)
    # The official install-only archive contains one relocatable python/ prefix.
    with tarfile.open(archive) as tar:
        if any(Path(m.name).parts[:1] != ('python',) for m in tar.getmembers()):
            raise ValueError('Unexpected standalone archive layout')
        tar.extractall(dest, filter='data')
    prefix = dest / 'python'
    python = prefix / 'bin/python3.12'
    site = prefix / 'lib/python3.12/site-packages'
    # Do not retain any seed packages shipped inside the standalone distribution.
    if site.exists():
        shutil.rmtree(site)
    site.mkdir(parents=True, exist_ok=True)
    pip = next(path for path in wheels if path.name.startswith('pip-'))
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(dest), 'TMPDIR': str(dest / 'build-tmp'),
           'PIP_CONFIG_FILE': '/dev/null', 'PYTHONDONTWRITEBYTECODE': '1'}
    (dest / 'build-tmp').mkdir()
    # Load pinned pip directly from its verified wheel; never use source venv paths.
    bootstrap = 'import runpy,sys;sys.path.insert(0,sys.argv.pop(1));runpy.run_module("pip",run_name="__main__")'
    with (dest / 'install-private.log').open('w') as log:
        subprocess.run([str(python), '-I', '-B', '-c', bootstrap, str(pip), '--isolated', 'install',
            '--no-index', '--no-deps', '--no-compile', '--no-cache-dir', '--disable-pip-version-check',
            '--no-warn-script-location', '--target', str(site)] + [str(w) for w in wheels],
            env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.rmtree(dest / 'build-tmp')
    # Console-script shebangs embed a build prefix. App invokes the interpreter + worker directly.
    shutil.rmtree(site / 'bin', ignore_errors=True)
    # Generated local-wheel metadata records build paths; upstream wheel provenance is retained below.
    for generated in site.glob('*.dist-info/direct_url.json'):
        generated.unlink()
    prune_console_entrypoints(prefix)
    shutil.copyfile(a.worker, dest / 'worker.py')
    notices = dest / 'Notices'
    notices.mkdir()
    for name in ['python-provenance.json', 'wheel-provenance.json', 'model-provenance.json']:
        shutil.copyfile(HERE / name, notices / name)
    for license_file in sorted(prefix.rglob('*')):
        if not license_file.is_file() or license_file.is_symlink():
            continue
        if license_file.name.lower().startswith(('license', 'copying', 'notice')):
            relative = license_file.relative_to(prefix)
            target = notices / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(license_file, target)
    transforms = cleanup_runtime(dest, sha, torch_expected=any(w['package'].lower() == 'torch' for w in rows))
    natives, issues = native_inventory(dest)
    manifest = {'schemaVersion': 1, 'status': 'staged-candidate-not-release-accepted', 'python': py,
        'packages': rows, 'workerSHA256': sha(dest / 'worker.py'), 'torchOmitted': False, 'minimumWheelPlatform': 'macOS26 arm64 (mlx0.32.4; not validated on older macOS)',
        'nativeFiles': natives, 'relocationIssues': issues, 'nativeTransforms': transforms,
        'acceptance': {'qualityAccepted': a.quality_accepted, 'signedRelocationPassed': False,
                       'offlineInferencePassed': False, 'cancellationPassed': False},
        'files': [{'file': str(f.relative_to(dest)), 'sha256': sha(f), 'bytes': f.stat().st_size}
                  for f in sorted(dest.rglob('*')) if f.is_file() and not f.is_symlink()]}
    write(dest / 'runtime-manifest.json', manifest)
    if issues:
        raise ValueError('Native relocation audit has issues; inspect candidate manifest before signing')
    print(json.dumps({'status': manifest['status'], 'packages': len(rows), 'nativeFiles': len(natives),
                      'torchOmitted': False, 'inferenceRun': False}))


if __name__ == '__main__':
    main()
