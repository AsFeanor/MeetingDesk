#!/usr/bin/env python3
"""Explicit build-time download only. Never called by the app or runtime builder."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlparse

HERE = Path(__file__).resolve().parent


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def artifacts():
    py = json.loads((HERE / 'python-provenance.json').read_text())
    wheels = json.loads((HERE / 'wheel-provenance.json').read_text())['artifacts']
    return [(py['archive'], py['metadataEntry']['url'], py['archiveSHA256'])] + [
        (Path(unquote(urlparse(w['url']).path)).name, w['url'], w['sha256']) for w in wheels]


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--destination', type=Path, required=True)
    p.add_argument('--reuse-directory', type=Path)
    a = p.parse_args()
    a.destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    records = []
    for name, url, expected in artifacts():
        parsed = urlparse(url)
        if parsed.scheme != 'https' or parsed.hostname not in {'files.pythonhosted.org', 'releases.astral.sh'}:
            raise ValueError('Unpinned artifact host')
        target = a.destination / name
        if not target.exists():
            cached = a.reuse_directory / name if a.reuse_directory else None
            part = target.with_name(name + '.part')
            if part.exists():
                raise ValueError('Partial artifact already exists; inspect before retry')
            if cached and cached.is_file() and sha(cached) == expected:
                shutil.copyfile(cached, part)
            else:
                subprocess.run(['/usr/bin/curl', '--disable', '--fail', '--silent', '--show-error',
                    '--proto', '=https', '--proto-redir', '=https', '--location', '--connect-timeout', '30',
                    '--max-time', '1200', '--retry', '2', '--max-filesize', '1200000000',
                    '--output', str(part), url], check=True)
            if sha(part) != expected:
                raise ValueError('Artifact checksum mismatch; partial retained')
            os.replace(part, target)
        if sha(target) != expected:
            raise ValueError('Existing artifact checksum mismatch')
        records.append({'file': name, 'sha256': expected, 'bytes': target.stat().st_size})
    (a.destination / 'verified-artifacts.json').write_text(json.dumps(records, indent=2) + '\n')
    print(json.dumps({'verifiedArtifacts': len(records), 'modelDownloaded': False}))


if __name__ == '__main__':
    main()
