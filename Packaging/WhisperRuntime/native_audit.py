"""Command-aware Mach-O inventory and narrowly allowlisted relocation cleanup."""
import os
import json
import hashlib
from pathlib import Path
import re
import subprocess

MACH = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
        b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
LOADS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
         'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}
FBLAS = 'python/lib/python3.12/site-packages/scipy/linalg/_fblas.cpython-312-darwin.so'
REMOVE_RPATHS = {
    '/opt/homebrew/Cellar/gcc@13/13.4.0/lib/gcc/13/gcc/aarch64-apple-darwin23/13',
    '/opt/homebrew/Cellar/gcc@13/13.4.0/lib/gcc/13/gcc',
    '/opt/homebrew/Cellar/gcc@13/13.4.0/lib/gcc/13'}
INTERPRETERS = {'python', 'python3', 'python3.12'}
PRUNED_CONSOLE_ALIASES = {'2to3': '2to3-3.12', 'pydoc3': 'pydoc3.12'}


def prune_console_entrypoints(prefix):
    """Fresh standalone prefix only: remove scripts and their aliases together."""
    for entry in (prefix / 'bin').iterdir():
        if entry.name in INTERPRETERS:
            continue
        if entry.is_symlink() or entry.is_file():
            entry.unlink()
        else:
            raise ValueError('Unexpected standalone bin entry; refusing broad deletion')


def cleanup_dangling_console_aliases(root):
    transforms = []
    for name, expected in PRUNED_CONSOLE_ALIASES.items():
        path = root / 'python/bin' / name
        if path.is_symlink() and not path.exists() and os.readlink(path) == expected:
            path.unlink()
            transforms.append({'file': str(path.relative_to(root)), 'operation': 'remove-known-dangling-console-alias',
                'linkTarget': expected, 'beforeLinkTargetSHA256': hashlib.sha256(expected.encode('utf-8')).hexdigest(),
                'postAbsent': not path.exists() and not path.is_symlink()})
    return transforms


def system_path(path):
    return any(path == p or path.startswith(p + '/') for p in ['/usr/lib', '/System/Library'])


def parse_otool(text):
    """Parse -l load commands; never confuse fat headers or LC_ID_DYLIB with loads."""
    slices, architecture, block = {}, 'default', []
    def finish():
        if not block:
            return
        current = slices.setdefault(architecture, {'dependencies': [], 'ids': [], 'rpaths': [], 'minimumOS': []})
        command = next((line[4:] for line in block if line.startswith('cmd ')), None)
        if command in LOADS or command == 'LC_ID_DYLIB':
            name = next((line[5:].split(' (offset ', 1)[0] for line in block if line.startswith('name ')), None)
            if name:
                current['dependencies' if command in LOADS else 'ids'].append(name)
        if command == 'LC_RPATH':
            path = next((line[5:].split(' (offset ', 1)[0] for line in block if line.startswith('path ')), None)
            if path:
                current['rpaths'].append(path)
        if command in {'LC_BUILD_VERSION', 'LC_VERSION_MIN_MACOSX'}:
            current['minimumOS'] += [line for line in block if line.startswith(('minos ', 'version '))]
    for raw in text.splitlines():
        line = raw.strip()
        header = re.search(r'\(architecture ([^)]+)\):$', line)
        if header:
            finish(); block = []; architecture = header.group(1)
        elif re.fullmatch(r'Load command \d+', line):
            finish(); block = []
        else:
            block.append(line)
    finish()
    return slices


def read_native(path):
    return parse_otool(subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True))


def cleanup_allowlisted_rpaths(root, digest):
    path = root / FBLAS
    if not path.is_file() or path.is_symlink():
        return []
    slices = read_native(path)
    found = {r for row in slices.values() for r in row['rpaths']} & REMOVE_RPATHS
    if not found:
        return []
    # These three exact fallback paths are unused only for this exact wheel image.
    if any(not system_path(dep) for row in slices.values() for dep in row['dependencies']):
        raise ValueError('Allowlisted _fblas cleanup requires system-only real loads')
    before = digest(path)
    command = ['/usr/bin/install_name_tool']
    for rpath in sorted(found):
        command += ['-delete_rpath', rpath]
    subprocess.run(command + [str(path)], check=True)
    remaining = {r for row in read_native(path).values() for r in row['rpaths']}
    if remaining & found:
        raise ValueError('Allowlisted RPATH deletion was incomplete')
    return [{'file': FBLAS, 'operation': 'delete-unused-rpath', 'rpaths': sorted(found),
             'beforeSHA256': before, 'afterSHA256': digest(path),
             'reason': 'Pinned SciPy wheel _fblas real LC_LOAD commands use system frameworks/libraries only'}]


def cleanup_runtime(root, digest, torch_expected):
    """Called only after exact artifact install or full pre-manifest hash verification."""
    transforms = cleanup_dangling_console_aliases(root) + cleanup_allowlisted_rpaths(root, digest)
    if torch_expected:
        directory = root / 'python/lib/python3.12/site-packages/numba/np/ufunc'
        pools = list(directory.glob('omppool*.so'))
        library = root / 'python/lib/python3.12/site-packages/torch/lib/libomp.dylib'
        if len(pools) != 1 or pools[0].is_symlink() or not library.is_file() or library.is_symlink():
            raise ValueError('Pinned full Torch/Numba OpenMP images required')
        pool = pools[0]
        rpath = '@loader_path/../../../torch/lib'
        slices = read_native(pool)
        if any('@rpath/libomp.dylib' not in row['dependencies'] for row in slices.values()):
            raise ValueError('Unexpected pinned Numba OpenMP load commands')
        missing = any(rpath not in row['rpaths'] for row in slices.values())
        if missing:
            if any(rpath in row['rpaths'] for row in slices.values()):
                raise ValueError('Mixed-architecture Numba OpenMP RPATH requires explicit review')
            before = digest(pool)
            library_digest = digest(library)
            subprocess.run(['/usr/bin/install_name_tool', '-add_rpath', rpath, str(pool)], check=True)
            if any(rpath not in row['rpaths'] for row in read_native(pool).values()):
                raise ValueError('Numba OpenMP relative RPATH addition was incomplete')
            transforms.append({'file': str(pool.relative_to(root)), 'operation': 'add-bundled-omp-rpath',
                'rpath': rpath, 'beforeSHA256': before, 'afterSHA256': digest(pool),
                'target': str(library.relative_to(root)), 'targetSHA256': library_digest,
                'reason': 'Full pinned Torch runtime supplies Numba OpenMP backend dependency; Torch licenses retained'})
    model_provenance = root / 'Notices/model-provenance.json'
    if model_provenance.is_file():
        value = json.loads(model_provenance.read_text())
        if 'modelDirectory' in value:
            before = digest(model_provenance)
            del value['modelDirectory']
            model_provenance.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
            transforms.append({'file': str(model_provenance.relative_to(root)), 'operation': 'remove-local-model-directory-metadata',
                'beforeSHA256': before, 'afterSHA256': digest(model_provenance)})
    log = root / 'install-private.log'
    if log.is_file() and not log.is_symlink():
        transforms.append({'file': 'install-private.log', 'operation': 'remove-build-log', 'beforeSHA256': digest(log)})
        log.unlink()
    return transforms


def native_inventory(root):
    root = root.resolve()
    natives, issues = [], []
    for path in sorted(root.rglob('*')):
        rel = str(path.relative_to(root))
        if path.is_symlink():
            if not path.exists():
                issues.append({'file': rel, 'issue': 'dangling-symlink'})
            elif os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(root):
                issues.append({'file': rel, 'issue': 'absolute-or-external-symlink'})
            continue
        if not path.is_file():
            continue
        with path.open('rb') as f:
            if f.read(4) not in MACH:
                continue
        slices = read_native(path)
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).strip()
        if set(slices) == {'default'} and len(architectures.split()) == 1:
            slices = {architectures: slices['default']}
        natives.append({'file': rel, 'architectures': architectures, 'slices': slices})
    by_path = {str((root / row['file']).resolve()): row for row in natives}
    executable = root / 'python/bin/python3.12'

    def row_for(path, arch):
        native = by_path.get(str(path.resolve()), {})
        if arch != 'default' and arch not in native.get('architectures', '').split():
            return None
        slices = native.get('slices', {})
        return slices.get(arch, slices.get('default'))

    def expand(value, image):
        if value == '@loader_path' or value.startswith('@loader_path/'):
            return image.parent / value[len('@loader_path'):].lstrip('/')
        if value == '@executable_path' or value.startswith('@executable_path/'):
            return executable.parent / value[len('@executable_path'):].lstrip('/')
        return Path(value) if value.startswith('/') else None

    # Traverse load ancestry from the actual interpreter and each extension dlopen root.
    # RPATHs come only from the current image, its actual resolved ancestors and interpreter.
    visited = set()
    seen_images = set()
    def inspect(path, arch, inherited):
        row = row_for(path, arch)
        if row is None:
            issues.append({'file': str(path.relative_to(root)), 'architecture': arch, 'issue': 'dependency-architecture-missing'})
            return
        current_rpaths = tuple((path, r) for r in row['rpaths']) + inherited
        key = (str(path), arch, current_rpaths)
        if key in visited:
            return
        visited.add(key)
        seen_images.add((str(path), arch))
        rel = str(path.relative_to(root))
        for rpath in row['rpaths']:
            if rpath.startswith('/') and not system_path(rpath):
                issues.append({'file': rel, 'architecture': arch, 'issue': 'absolute-non-system-rpath', 'rpath': rpath})
        for dep in row['dependencies']:
            if system_path(dep):
                continue  # Shared-cache system libraries need not exist as ordinary files.
            options = []
            if dep.startswith('@rpath/'):
                for owner, value in current_rpaths:
                    base = expand(value, owner)
                    if base is not None:
                        options.append(base / dep[len('@rpath/'):])
            else:
                target = expand(dep, path)
                if target is not None:
                    options.append(target)
            if any(system_path(str(p.resolve())) for p in options):
                continue  # A real system RPATH can resolve through the dyld shared cache.
            resolved = next((p.resolve() for p in options if p.is_file() and p.resolve().is_relative_to(root)), None)
            if dep.startswith('/') or resolved is None:
                issues.append({'file': rel, 'architecture': arch, 'issue': 'unresolved-or-absolute-non-system-load', 'dependency': dep})
                continue
            # Ancestor recursion remains finite even for dylib cycles.
            ancestors = tuple(dict.fromkeys(current_rpaths))
            inspect(resolved, arch, ancestors)

    ordered = sorted(natives, key=lambda row: not (row['file'].endswith('.so') or (root / row['file']) == executable))
    for native in ordered:
        path = root / native['file']
        for arch in native['slices']:
            if (str(path), arch) in seen_images:
                continue
            exe = row_for(executable, arch)
            inherited = tuple((executable, r) for r in exe['rpaths']) if exe else ()
            inspect(path, arch, inherited)
    # Repeated ancestry contexts may find the same issue; keep a compact deterministic result.
    unique = {json.dumps(issue, sort_keys=True): issue for issue in issues}
    return natives, [unique[k] for k in sorted(unique)]
