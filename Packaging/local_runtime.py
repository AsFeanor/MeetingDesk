#!/usr/bin/env python3
"""Package a pinned, GUI-free Apple Silicon inference runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = Path(__file__).with_name('local-runtime.json')
MANIFEST = 'runtime-manifest.json'
MAX_ARCHIVE_BYTES = 500 * 1024 * 1024
MAX_MEMBER_BYTES = 128 * 1024 * 1024
MAX_PAYLOAD_BYTES = 200 * 1024 * 1024


class PackagingError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PackagingError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def load_config(path=DEFAULT_CONFIG):
    config = json.loads(Path(path).read_text())
    url = urlsplit(config['url'])
    require(url.scheme == 'https' and url.hostname == 'github.com'
            and url.path.startswith('/ollama/ollama/releases/download/')
            and not url.username and not url.password, 'Runtime source must be the official HTTPS release.')
    require(config.get('architecture') == 'arm64', 'Only the pinned arm64 runtime is supported.')
    files = config.get('files', [])
    names = [entry['name'] for entry in files]
    require(len(names) == len(set(names)) and {'ollama', 'llama-server'} <= set(names),
            'Runtime manifest has missing or duplicate files.')
    for entry in files:
        name = entry['name']
        require(normalize_member(name) == name and '/' not in name, 'Runtime member names must be flat.')
        require(entry['role'] in ('executable', 'notice')
                and (entry['role'] != 'executable' or name in ('ollama', 'llama-server')),
                'Unexpected executable in runtime manifest.')
        require(type(entry['bytes']) is int and 0 < entry['bytes'] <= MAX_MEMBER_BYTES,
                'Runtime member size is invalid.')
        require(len(entry['sha256']) == 64 and all(c in '0123456789abcdef' for c in entry['sha256']),
                'Runtime member digest is invalid.')
    return config


def verify_archive(path, config):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Runtime archive must be a regular file.')
    size = path.stat().st_size
    require(0 < size <= MAX_ARCHIVE_BYTES, 'Runtime archive exceeds the download limit.')
    require(size == config['archiveBytes'], 'Runtime archive size differs from the pinned release.')
    require(digest(path) == config['sha256'], 'Runtime archive checksum differs from the pinned release.')


def cached_archive(config, cache_directory=None):
    cache = Path(cache_directory) if cache_directory else PROJECT / '.build/vendor'
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / 'ollama-darwin.tgz'
    if os.path.lexists(target):
        verify_archive(target, config)
        return target
    descriptor, temporary = tempfile.mkstemp(prefix='.ollama-', suffix='.part', dir=cache)
    os.close(descriptor)
    try:
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error',
                        '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
                        '--retry', '2', '--connect-timeout', '30', '--max-time', '1800',
                        '--max-filesize', str(MAX_ARCHIVE_BYTES), '--output', temporary, config['url']], check=True)
        verify_archive(temporary, config)
        require(not os.path.lexists(target), 'Another runtime archive appeared while downloading.')
        os.replace(temporary, target)
        return target
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def normalize_member(name):
    require(isinstance(name, str) and name and '\\' not in name, 'Unsafe archive path.')
    path = PurePosixPath(name)
    require(not path.is_absolute() and '..' not in path.parts, 'Unsafe archive path.')
    return str(path)


def extract_payload(archive, destination, config):
    """Read selected regular members manually; never follow links or extractall."""
    destination = Path(destination)
    expected = {entry['name']: entry for entry in config['files']}
    selected = set()
    total = 0
    with tarfile.open(archive, mode='r:gz') as source:
        for member in source:
            name = normalize_member(member.name)
            if name not in expected:
                continue
            require(name not in selected, 'Duplicate selected archive member.')
            entry = expected[name]
            require(member.isfile() and not member.issym() and not member.islnk(),
                    'Selected runtime member must be a regular file.')
            require(0 < member.size <= MAX_MEMBER_BYTES and member.size == entry['bytes'],
                    'Selected runtime member size differs from manifest.')
            total += member.size
            require(total <= MAX_PAYLOAD_BYTES, 'Runtime payload exceeds the extraction limit.')
            incoming = source.extractfile(member)
            require(incoming is not None, 'Selected runtime member is unreadable.')
            target = destination / name
            value = hashlib.sha256()
            written = 0
            with incoming, target.open('xb') as output:
                for block in iter(lambda: incoming.read(1024 * 1024), b''):
                    written += len(block)
                    require(written <= entry['bytes'], 'Runtime member exceeds its declared size.')
                    value.update(block)
                    output.write(block)
            require(written == entry['bytes'] and value.hexdigest() == entry['sha256'],
                    'Selected runtime member checksum differs from manifest.')
            target.chmod(0o755 if entry['role'] == 'executable' else 0o644)
            selected.add(name)
    require(selected == set(expected), 'Pinned runtime payload is incomplete.')


def thin_arm64(path):
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()
    require('arm64' in architectures, 'Pinned runtime has no arm64 slice.')
    if architectures != ['arm64']:
        output = path.with_name(path.name + '.arm64')
        subprocess.run(['/usr/bin/lipo', str(path), '-thin', 'arm64', '-output', str(output)], check=True)
        output.chmod(0o755)
        os.replace(output, path)
    actual = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split()
    require(actual == ['arm64'], 'Runtime thinning did not produce arm64-only code.')


def write_manifest(destination, value):
    (Path(destination) / MANIFEST).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def install(archive, destination, config):
    verify_archive(archive, config)
    destination = Path(destination)
    require(not os.path.lexists(destination), 'Runtime destination already exists; use a fresh build directory.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.local-runtime-', dir=destination.parent))
    try:
        extract_payload(archive, staging, config)
        for entry in config['files']:
            if entry['role'] == 'executable':
                thin_arm64(staging / entry['name'])
        records = []
        for entry in config['files']:
            target = staging / entry['name']
            records.append({'file': entry['name'], 'role': entry['role'], 'sourceSHA256': entry['sha256'],
                            'preSigningSHA256': digest(target), 'installedBytes': target.stat().st_size})
        write_manifest(staging, {'schemaVersion': 1, 'runtime': 'ollama', 'version': config['version'],
                       'architecture': 'arm64', 'sourceURL': config['url'], 'sourceArchiveSHA256': config['sha256'],
                       'signedFilesRecorded': False, 'files': records})
        staging.chmod(0o755)
        require(not os.path.lexists(destination), 'Runtime destination appeared during build.')
        os.rename(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def finalize_manifest(destination, config):
    """Call after nested codesign and before signing the outer application."""
    destination = Path(destination)
    value = json.loads((destination / MANIFEST).read_text())
    expected = {entry['name']: entry for entry in config['files']}
    require(value.get('sourceArchiveSHA256') == config['sha256'] and value.get('architecture') == 'arm64',
            'Installed runtime provenance differs from the pinned manifest.')
    records = value.get('files', [])
    require(len(records) == len(expected) and {entry['file'] for entry in records} == set(expected),
            'Installed runtime manifest has missing or duplicate files.')
    for entry in records:
        name = entry['file']
        target = destination / name
        require(target.is_file() and not target.is_symlink() and entry['sourceSHA256'] == expected[name]['sha256'],
                'Installed runtime file or provenance is invalid.')
        if expected[name]['role'] == 'notice':
            require(digest(target) == expected[name]['sha256'], 'Runtime notice changed during signing.')
        entry['installedSHA256'] = digest(target)
        entry['installedBytes'] = target.stat().st_size
    value['signedFilesRecorded'] = True
    write_manifest(destination, value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--destination', type=Path)
    group.add_argument('--finalize-manifest', type=Path)
    parser.add_argument('--archive', type=Path, help='Use an existing archive, still requiring the pinned digest.')
    parser.add_argument('--cache-directory', type=Path)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.finalize_manifest:
            finalize_manifest(args.finalize_manifest, config)
            print('Recorded signed runtime file fingerprints.')
        else:
            archive = args.archive or cached_archive(config, args.cache_directory)
            install(archive, args.destination, config)
            print('Installed pinned arm64 runtime; sign nested executables before finalizing the manifest.')
        return 0
    except (PackagingError, OSError, ValueError, KeyError, tarfile.TarError):
        print('Bundled runtime packaging failed: input, digest, extraction or destination validation failed.', file=sys.stderr)
        return 1
    except subprocess.SubprocessError:
        print('Bundled runtime packaging failed: a download or architecture tool failed.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
