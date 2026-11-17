import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
from .native_audit import parse_otool, system_path, native_inventory, cleanup_runtime, prune_console_entrypoints


class NativeParsingTests(unittest.TestCase):
    def test_fresh_bin_prunes_console_targets_and_aliases_together(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix=Path(directory);bin_path=prefix/'bin';bin_path.mkdir()
            for name in ['python3.12','2to3-3.12','pydoc3.12','python3.12-config','pip']:
                (bin_path/name).write_text('fixture')
            for name,target in [('python','python3.12'),('python3','python3.12'),('2to3','2to3-3.12'),('pydoc3','pydoc3.12')]:
                (bin_path/name).symlink_to(target)
            prune_console_entrypoints(prefix)
            self.assertEqual({p.name for p in bin_path.iterdir()},{'python','python3','python3.12'})
            self.assertTrue(all(p.exists() for p in bin_path.iterdir()))

    def test_cleanup_only_exact_known_dangling_aliases_and_audit_other_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();bin_path=root/'python/bin';bin_path.mkdir(parents=True)
            for name,target in [('2to3','2to3-3.12'),('pydoc3','pydoc3.12'),('unknown','missing')]:
                (bin_path/name).symlink_to(target)
            with patch(__package__ + '.native_audit.subprocess.check_output') as native_tool, patch(__package__ + '.native_audit.subprocess.run') as mutation:
                transforms=cleanup_runtime(root,lambda p: self.fail('No regular files expected'),torch_expected=False)
                native,issues=native_inventory(root)
            native_tool.assert_not_called();mutation.assert_not_called()
            self.assertEqual(len(transforms),2)
            self.assertTrue(all(t['postAbsent'] and len(t['beforeLinkTargetSHA256'])==64 for t in transforms))
            self.assertEqual(native,[])
            self.assertEqual(issues,[{'file':'python/bin/unknown','issue':'dangling-symlink'}])
            (bin_path/'2to3').symlink_to('unexpected-target')
            self.assertEqual(cleanup_runtime(root,lambda p: '',torch_expected=False),[])
            self.assertTrue((bin_path/'2to3').is_symlink())

    def test_embed_rejects_a_dangling_link_even_with_matching_regular_inventory(self):
        import json
        from .embed_runtime import verify
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();(root/'bad').symlink_to('missing')
            (root/'runtime-manifest.json').write_text(json.dumps({'relocationIssues':[],'nativeFiles':[{'file':'fixture'}],'files':[]}))
            with self.assertRaisesRegex(ValueError,'dangling'):
                verify(root)

    def test_fat_headers_and_ids_are_not_load_dependencies(self):
        text = '''/private/build/cd.so (architecture x86_64):
Load command 0
          cmd LC_ID_DYLIB
      cmdsize 40
         name /DLC/scipy/.dylibs/libgfortran.dylib (offset 24)
Load command 1
          cmd LC_LOAD_DYLIB
         name /usr/lib/libSystem.B.dylib (offset 24)
/private/build/cd.so (architecture arm64):
Load command 0
          cmd LC_LOAD_DYLIB
         name @loader_path/libquadmath.0.dylib (offset 24)
Load command 1
          cmd LC_RPATH
         path @loader_path/lib (offset 12)
Load command 2
          cmd LC_BUILD_VERSION
        minos 14.0
'''
        result = parse_otool(text)
        self.assertEqual(set(result), {'x86_64', 'arm64'})
        self.assertEqual(result['x86_64']['ids'], ['/DLC/scipy/.dylibs/libgfortran.dylib'])
        self.assertEqual(result['x86_64']['dependencies'], ['/usr/lib/libSystem.B.dylib'])
        self.assertEqual(result['arm64']['dependencies'], ['@loader_path/libquadmath.0.dylib'])
        self.assertEqual(result['arm64']['rpaths'], ['@loader_path/lib'])
        self.assertEqual(result['arm64']['minimumOS'], ['minos 14.0'])

    def test_other_loader_commands_and_version(self):
        for command in ['LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB']:
            result = parse_otool('Load command 0\n cmd ' + command + '\n name @rpath/library.dylib (offset 24)')
            self.assertEqual(result['default']['dependencies'], ['@rpath/library.dylib'])

    def test_system_directory_boundaries(self):
        for path in ['/usr/lib', '/usr/lib/libSystem.B.dylib', '/System/Library/Frameworks/Accelerate.framework/Accelerate']:
            self.assertTrue(system_path(path))
        for path in ['/usr/library', '/opt/homebrew/lib', '/System/LibraryOther']:
            self.assertFalse(system_path(path))

    def test_actual_parent_rpaths_resolve_nested_dylibs(self):
        def commands(loads=(), rpaths=()):
            parts = []
            for value in loads:
                parts.append('cmd LC_LOAD_DYLIB\n name ' + value + ' (offset 24)')
            for value in rpaths:
                parts.append('cmd LC_RPATH\n path ' + value + ' (offset 12)')
            if not parts:
                parts = ['cmd LC_ID_DYLIB\n name @rpath/self.dylib (offset 24)']
            return '\n'.join('Load command ' + str(i) + '\n' + v for i,v in enumerate(parts))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            rows = {
                'python/bin/python3.12': commands(['@rpath/libpython3.12.dylib'], ['@executable_path/../lib']),
                'python/lib/libpython3.12.dylib': commands(['/usr/lib/libSystem.B.dylib']),
                'python/lib/core.so': commands(['@rpath/libmlx.dylib'], ['@loader_path/nested']),
                'python/lib/nested/libmlx.dylib': commands(['@rpath/libjaccl.dylib']),
                'python/lib/nested/libjaccl.dylib': commands(['/usr/lib/libSystem.B.dylib'])}
            for name in rows:
                path = root / name;path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(b'\xcf\xfa\xed\xfe')
            def output(command, text):
                if command[0].endswith('lipo'):
                    return 'arm64\n'
                return rows[str(Path(command[-1]).relative_to(root))]
            with patch(__package__ + '.native_audit.subprocess.check_output', side_effect=output):
                native, issues = native_inventory(root)
            self.assertEqual(len(native), 5)
            self.assertEqual(issues, [])

    def test_unresolved_load_does_not_use_unrelated_image_rpath(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            names = ['python/bin/python3.12', 'python/lib/a.so', 'python/lib/b.so', 'python/lib/other/libhidden.dylib']
            for name in names:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'\xcf\xfa\xed\xfe')
            def output(command, text):
                if command[0].endswith('lipo'): return 'arm64\n'
                name=Path(command[-1]).name
                if name=='a.so': return 'Load command 0\n cmd LC_LOAD_DYLIB\n name @rpath/libhidden.dylib (offset 24)'
                if name=='b.so': return 'Load command 0\n cmd LC_RPATH\n path @loader_path/other (offset 12)'
                return 'Load command 0\n cmd LC_LOAD_DYLIB\n name /usr/lib/libSystem.B.dylib (offset 24)'
            with patch(__package__ + '.native_audit.subprocess.check_output',side_effect=output):
                _,issues=native_inventory(root)
            self.assertEqual(len(issues),1)
            self.assertEqual(issues[0]['dependency'],'@rpath/libhidden.dylib')


if __name__ == '__main__':
    unittest.main()
