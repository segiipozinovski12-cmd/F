#!/usr/bin/env python3
"""Check installed bundle layout and embedded framework loading paths."""
from pathlib import Path
import plistlib
import subprocess
import sys


def framework_binary(framework: Path) -> Path:
    if (framework / 'Versions').exists():
        raise RuntimeError(f'iOS requires a shallow framework: {framework}')
    with (framework / 'Info.plist').open('rb') as handle:
        executable = plistlib.load(handle)['CFBundleExecutable']
    if executable != Path(executable).name:
        raise RuntimeError(f'Invalid framework executable: {framework}')
    binary = framework / executable
    if not binary.is_file():
        raise RuntimeError(f'Missing embedded executable: {binary}')
    return binary


def validate(app: Path) -> None:
    with (app / 'Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    binary = app / info['CFBundleExecutable']
    if not binary.is_file():
        raise RuntimeError('App executable is missing')
    images = [binary] + [framework_binary(path) for path in (app / 'Frameworks').glob('*.framework')]
    ffi = app / 'Frameworks/signal_ffi.framework/signal_ffi'
    if not ffi.is_file():
        raise RuntimeError('The isolated Signal framework is missing from the app')
    exports = subprocess.check_output(['xcrun', 'nm', '-gjU', str(ffi)], text=True)
    public = [line.strip() for line in exports.splitlines() if line.strip().startswith('_')]
    if not public or any(not symbol.startswith('_signal_') for symbol in public):
        raise RuntimeError('The Signal framework exposes internal crypto symbols')
    for image in images:
        dependencies = subprocess.check_output(['xcrun', 'otool', '-L', str(image)], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if not dependency.startswith('@rpath/') or '.framework/' not in dependency:
                continue
            relative = dependency[len('@rpath/'):]
            if '/Versions/' in relative or not (app / 'Frameworks' / relative).is_file():
                raise RuntimeError(f'Unresolvable embedded framework: {image.name}: {dependency}')
    print(f'Validated iOS bundle: {app.name} ({len(images) - 1} embedded frameworks).')


if __name__ == '__main__':
    validate(Path(sys.argv[1]))
