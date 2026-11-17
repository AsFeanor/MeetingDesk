import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from . import sign_runtime


class RuntimeSigningPolicyTests(unittest.TestCase):
    def commands(self, identity):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'module.so').write_bytes(b'synthetic native file')
            (root / 'runtime-manifest.json').write_text(json.dumps({'relocationIssues': [], 'nativeFiles': [{'file': 'module.so'}]}))
            with mock.patch('sys.argv', ['sign_runtime.py', '--runtime', directory, '--identity', identity]), \
                 mock.patch.object(sign_runtime.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
                sign_runtime.main()
            return [call.args[0] for call in run.call_args_list]

    def testAdHocMatchesApplicationPolicyWithoutTeamLibraryValidation(self):
        commands = self.commands('-')
        self.assertNotIn('runtime', commands[0])
        self.assertNotIn('--timestamp', commands[0])
        self.assertEqual(commands[1][:3], ['/usr/bin/codesign', '--verify', '--strict'])

    def testDeveloperIdentityRetainsHardenedRuntimeAndTimestamp(self):
        commands = self.commands('Developer ID Application: Synthetic')
        self.assertIn('--options', commands[0])
        self.assertIn('runtime', commands[0])
        self.assertIn('--timestamp', commands[0])
        self.assertNotIn('--entitlements', commands[0])
