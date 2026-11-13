import copy
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

import local_runtime as runtime


class LocalRuntimePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payload = {'ollama': b'fake-public-cli', 'llama-server': b'fake-public-runner',
                        'GO_LICENSE': b'full synthetic license text'}

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, additions=(), omitted=(), replacements=None):
        path = self.root / 'runtime.tgz'
        values = {**self.payload, **(replacements or {})}
        with tarfile.open(path, 'w:gz') as output:
            for name, data in values.items():
                if name not in omitted:
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    output.addfile(info, io.BytesIO(data))
            for entry in additions:
                if isinstance(entry, tarfile.TarInfo):
                    output.addfile(entry)
                else:
                    name, data = entry
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    output.addfile(info, io.BytesIO(data))
        return path

    def config(self, archive):
        return {'version': 'test', 'architecture': 'arm64',
                'url': 'https://github.com/ollama/ollama/releases/download/test/ollama-darwin.tgz',
                'archiveBytes': archive.stat().st_size, 'sha256': runtime.digest(archive),
                'files': [{'name': name, 'role': 'notice' if name == 'GO_LICENSE' else 'executable',
                           'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                          for name, data in self.payload.items()]}

    @staticmethod
    def fake_thin(path):
        # Exercises manifest provenance across an architecture transform without
        # executing a runtime, curl, lipo or any Mach-O code in unit tests.
        path.write_bytes(path.read_bytes() + b'-arm64')

    def testPinnedConfigListsExactlyTwoExecutablesAndElevenNotices(self):
        config = runtime.load_config()
        self.assertEqual(config['version'], '0.40.11')
        self.assertEqual(config['archiveBytes'], 181324349)
        self.assertEqual(config['architecture'], 'arm64')
        self.assertEqual({entry['name'] for entry in config['files'] if entry['role'] == 'executable'},
                         {'ollama', 'llama-server'})
        self.assertEqual(len([entry for entry in config['files'] if entry['role'] == 'notice']), 11)
        self.assertFalse(any('model' in entry['name'].lower() for entry in config['files']))

    def testArchiveChecksumSizeAndDownloadCeilingAreEnforced(self):
        archive = self.archive()
        config = self.config(archive)
        runtime.verify_archive(archive, config)
        changed = copy.deepcopy(config)
        changed['sha256'] = '0' * 64
        with self.assertRaises(runtime.PackagingError):
            runtime.verify_archive(archive, changed)
        changed = copy.deepcopy(config)
        changed['archiveBytes'] += 1
        with self.assertRaises(runtime.PackagingError):
            runtime.verify_archive(archive, changed)
        with mock.patch.object(runtime, 'MAX_ARCHIVE_BYTES', archive.stat().st_size - 1):
            with self.assertRaises(runtime.PackagingError):
                runtime.verify_archive(archive, config)

    def testCachedArchiveIsVerifiedWithoutDownloadAndCorruptionDoesNotGetOverwritten(self):
        archive = self.archive()
        config = self.config(archive)
        cache = self.root / 'cache'
        cache.mkdir()
        target = cache / 'ollama-darwin.tgz'
        target.write_bytes(archive.read_bytes())
        with mock.patch.object(runtime.subprocess, 'run') as external:
            self.assertEqual(runtime.cached_archive(config, cache), target)
            target.write_bytes(b'corrupted cached payload')
            with self.assertRaises(runtime.PackagingError):
                runtime.cached_archive(config, cache)
            self.assertEqual(target.read_bytes(), b'corrupted cached payload')
            external.assert_not_called()

    def testInstallCopiesOnlyAllowlistedRuntimeNotWeightsOrGUI(self):
        archive = self.archive(additions=[('models/public-weight.bin', b'fake model'),
                                         ('Ollama.app/Contents/MacOS/Ollama', b'fake gui'),
                                         ('mlx_metal_v4/mlx.metallib', b'fake metal')])
        config = self.config(archive)
        destination = self.root / 'app/Contents/Helpers/LocalSummaryRuntime'
        with mock.patch.object(runtime, 'thin_arm64', side_effect=self.fake_thin) as thin:
            runtime.install(archive, destination, config)
        self.assertEqual(thin.call_count, 2)
        self.assertEqual({path.name for path in destination.iterdir()}, set(self.payload) | {runtime.MANIFEST})
        self.assertEqual((destination / 'GO_LICENSE').read_bytes(), self.payload['GO_LICENSE'])
        self.assertEqual((destination / 'ollama').stat().st_mode & 0o777, 0o755)
        self.assertEqual((destination / 'GO_LICENSE').stat().st_mode & 0o777, 0o644)
        manifest = json.loads((destination / runtime.MANIFEST).read_text())
        self.assertFalse(manifest['signedFilesRecorded'])
        executable = next(entry for entry in manifest['files'] if entry['file'] == 'ollama')
        self.assertEqual(executable['sourceSHA256'], hashlib.sha256(self.payload['ollama']).hexdigest())
        self.assertNotEqual(executable['sourceSHA256'], executable['preSigningSHA256'])
        with self.assertRaises(runtime.PackagingError):
            runtime.install(archive, destination, config)

    def testTraversalAbsoluteAndBackslashMembersNeverEscapeStaging(self):
        for path in ('../escape', '/absolute-escape', 'safe/../../escape', 'bad\\escape'):
            archive = self.archive(additions=[(path, b'unsafe')])
            destination = self.root / 'destination'
            with self.subTest(path=path), mock.patch.object(runtime, 'thin_arm64') as thin:
                with self.assertRaises(runtime.PackagingError):
                    runtime.install(archive, destination, self.config(archive))
                self.assertFalse(destination.exists())
                self.assertFalse((self.root / 'escape').exists())
                thin.assert_not_called()

    def testSelectedSymlinksAndHardlinksCannotSupplyExecutable(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            link = tarfile.TarInfo('ollama')
            link.type = kind
            link.linkname = '../outside'
            archive = self.archive(additions=[link], omitted=['ollama'])
            destination = self.root / 'destination'
            with self.subTest(kind=kind), self.assertRaises(runtime.PackagingError):
                runtime.install(archive, destination, self.config(archive))
            self.assertFalse(destination.exists())

    def testMissingDuplicateAndIncorrectSelectedPayloadAreRejected(self):
        cases = [self.archive(omitted=['llama-server']).read_bytes(),
                 self.archive(additions=[('ollama', self.payload['ollama'])]).read_bytes(),
                 self.archive(replacements={'ollama': b'x' * len(self.payload['ollama'])}).read_bytes()]
        for data in cases:
            archive = self.root / 'runtime.tgz'
            archive.write_bytes(data)
            destination = self.root / 'destination'
            with mock.patch.object(runtime, 'thin_arm64') as thin:
                with self.assertRaises(runtime.PackagingError):
                    runtime.install(archive, destination, self.config(archive))
                self.assertFalse(destination.exists())
                thin.assert_not_called()

    def testSelectedUncompressedPayloadHasAnIndependentSizeBound(self):
        archive = self.archive()
        with mock.patch.object(runtime, 'MAX_PAYLOAD_BYTES', 1), self.assertRaises(runtime.PackagingError):
            runtime.install(archive, self.root / 'destination', self.config(archive))

    def testFinalManifestRecordsSignedBytesWithoutChangingSourceProvenance(self):
        archive = self.archive()
        config = self.config(archive)
        destination = self.root / 'destination'
        with mock.patch.object(runtime, 'thin_arm64', side_effect=self.fake_thin):
            runtime.install(archive, destination, config)
        (destination / 'ollama').write_bytes((destination / 'ollama').read_bytes() + b'-signature')
        runtime.finalize_manifest(destination, config)
        manifest = json.loads((destination / runtime.MANIFEST).read_text())
        self.assertTrue(manifest['signedFilesRecorded'])
        executable = next(entry for entry in manifest['files'] if entry['file'] == 'ollama')
        self.assertEqual(executable['sourceSHA256'], hashlib.sha256(self.payload['ollama']).hexdigest())
        self.assertEqual(executable['installedSHA256'], runtime.digest(destination / 'ollama'))
        self.assertNotEqual(executable['preSigningSHA256'], executable['installedSHA256'])
        (destination / 'GO_LICENSE').write_text('changed license')
        with self.assertRaises(runtime.PackagingError):
            runtime.finalize_manifest(destination, config)


if __name__ == '__main__':
    unittest.main()
