#!/usr/bin/env python3
"""Wrap the official FFI archive in an iOS framework with a private crypto ABI."""
from pathlib import Path
import hashlib
import platform
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'Vendor/libsignal/artifacts'


def archive_members(path: Path):
    """Read BSD/GNU archives without extracting their filenames onto disk."""
    with path.open('rb') as handle:
        if handle.read(8) != b'!<arch>\n':
            raise RuntimeError(f'Expected a static archive: {path}')
        while True:
            header = handle.read(60)
            if not header:
                return
            if len(header) != 60 or header[58:] != b'`\n':
                raise RuntimeError('Malformed native archive header')
            size = int(header[48:58])
            data = handle.read(size)
            if len(data) != size:
                raise RuntimeError('Truncated native archive member')
            if size % 2:
                handle.read(1)
            raw_name = header[:16].strip()
            prefix = b''
            if raw_name.startswith(b'#1/'):
                length = int(raw_name[3:])
                if length > len(data):
                    raise RuntimeError('Invalid BSD archive member name')
                prefix, data = data[:length], data[length:]
                name = prefix.rstrip(b'\0').decode('utf-8')
            else:
                name = raw_name.decode('utf-8').rstrip('/')
            # Offsets in the old symbol table change after IR becomes native.
            if raw_name in (b'/', b'/SYM64/') or name.startswith('__.SYMDEF'):
                continue
            yield header, prefix, name, data


def materialize_native_archive(source: Path, output: Path, target: str, sdk: str) -> None:
    with tempfile.TemporaryDirectory(prefix='vo1d-signal-ir-') as directory:
        temp = Path(directory)
        with output.open('wb') as handle:
            handle.write(b'!<arch>\n')
            for index, (header, prefix, _, data) in enumerate(archive_members(source)):
                # Upstream Kyber C objects are LLVM IR. Compile them before the
                # final link so Rust LTO cannot introduce these inputs too late.
                if data.startswith((b'BC\xc0\xde', b'\xde\xc0\x17\x0b')):
                    ir, native = temp / f'{index}.bc', temp / f'{index}.o'
                    ir.write_bytes(data)
                    subprocess.run(['xcrun', 'clang', '-target', target, '-isysroot', sdk,
                                    '-x', 'ir', '-c', '-O2', '-fno-lto', str(ir),
                                    '-o', str(native)], check=True)
                    data = native.read_bytes()
                payload = prefix + data
                header = header[:48] + f'{len(payload):<10}'.encode('ascii') + header[58:]
                handle.write(header)
                handle.write(payload)
                if len(payload) % 2:
                    handle.write(b'\n')
        subprocess.run(['xcrun', 'ranlib', str(output)], check=True)


def exported_ffi_symbols(binary: Path):
    listing = subprocess.check_output(['xcrun', 'nm', '-gjU', str(binary)], text=True)
    return sorted(set(line.strip() for line in listing.splitlines()
                      if re.fullmatch(r'_signal_[A-Za-z0-9_]+', line.strip())))


def prepare_framework(source: Path, platform_name: str, architecture: str, compiler: str) -> None:
    framework = source.parent / 'signal_ffi.framework'
    binary = framework / 'signal_ffi'
    stamp = source.parent / 'signal-ffi-framework.sha256'
    digest = hashlib.sha256()
    digest.update(Path(__file__).read_bytes())
    digest.update(compiler.encode())
    digest.update((platform_name + architecture).encode())
    with source.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    fingerprint = digest.hexdigest()
    if binary.is_file() and (framework / 'Info.plist').is_file() and stamp.is_file() and stamp.read_text().strip() == fingerprint:
        link = source.parent / 'libsignal_ffi.dylib'
        if not link.is_symlink():
            link.unlink(missing_ok=True)
            link.symlink_to('signal_ffi.framework/signal_ffi')
        return

    sdk = subprocess.check_output(['xcrun', '--sdk', platform_name, '--show-sdk-path'], text=True).strip()
    target = f'{architecture}-apple-ios13.0' + ('-simulator' if platform_name == 'iphonesimulator' else '')
    framework.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='vo1d-signal-link-') as directory:
        temp = Path(directory)
        archive = temp / 'native.a'
        materialize_native_archive(source, archive, target, sdk)
        symbols = exported_ffi_symbols(archive)
        if not symbols:
            raise RuntimeError('The official archive has no Signal FFI exports')
        exports = temp / 'exports.txt'
        exports.write_text('\n'.join(symbols) + '\n')
        args = ['xcrun', 'clang', '-target', target, '-isysroot', sdk, '-dynamiclib',
                str(archive), '-o', str(binary),
                '-Wl,-install_name,@rpath/signal_ffi.framework/signal_ffi',
                '-Wl,-exported_symbols_list,' + str(exports), '-Wl,-dead_strip',
                '-lc++', '-lresolv', '-framework', 'Security', '-framework', 'Foundation',
                '-framework', 'SystemConfiguration']
        # Load public entry points rather than every alternative implementation
        # in the static archive. All internal TLS symbols remain private.
        args += ['-Wl,-u,' + symbol for symbol in symbols]
        subprocess.run(args, check=True)
        actual = subprocess.check_output(['xcrun', 'nm', '-gjU', str(binary)], text=True)
        public = {line.strip() for line in actual.splitlines() if line.strip().startswith('_')}
        if public != set(symbols):
            raise RuntimeError('Unexpected exports in the isolated Signal framework')

    binary.chmod(0o755)
    metadata = {'CFBundleExecutable': 'signal_ffi', 'CFBundleIdentifier': 'io.vo1d.signalffi',
                'CFBundleName': 'signal_ffi', 'CFBundlePackageType': 'FMWK',
                'CFBundleShortVersionString': '0.70.0', 'CFBundleVersion': '70',
                'CFBundleSupportedPlatforms': ['iPhoneOS' if platform_name == 'iphoneos' else 'iPhoneSimulator'],
                'MinimumOSVersion': '13.0'}
    (framework / 'Info.plist').write_bytes(plistlib.dumps(metadata))
    link = source.parent / 'libsignal_ffi.dylib'
    link.unlink(missing_ok=True)
    link.symlink_to('signal_ffi.framework/signal_ffi')
    stamp.write_text(fingerprint + '\n')
    print(f'Prepared isolated Signal FFI: {platform_name}/{source.parent.name}')


def prepare_frameworks() -> None:
    if platform.system() != 'Darwin':
        raise RuntimeError('Native Signal framework preparation requires Xcode on macOS')
    compiler = subprocess.check_output(['xcrun', 'clang', '--version'], text=True)
    simulator_arch = 'x86_64' if platform.machine().lower() in ('x86_64', 'amd64') else 'arm64'
    for platform_name, architecture in (('iphoneos', 'arm64'), ('iphonesimulator', simulator_arch)):
        for configuration in ('Debug', 'Release'):
            source = ARTIFACTS / platform_name / configuration / 'libsignal_ffi.a'
            prepare_framework(source, platform_name, architecture, compiler)


if __name__ == '__main__':
    prepare_frameworks()
