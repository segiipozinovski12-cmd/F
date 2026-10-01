import importlib.util
from pathlib import Path
import plistlib
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import io
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tor = load('prepare_tor')
signal = load('prepare_signal')
bundle = load('validate_ios_bundle')


class NativeSetupTests(unittest.TestCase):
    def test_preserves_source_built_simulator_and_fills_device_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'signal.tar.gz'
            payload = b'!<arch>\n' + b'official' * 200
            with tarfile.open(archive, 'w:gz') as tar:
                for target in ('aarch64-apple-ios', 'aarch64-apple-ios-sim'):
                    info = tarfile.TarInfo(f'target/{target}/release/libsignal_ffi.a')
                    info.size = len(payload)
                    tar.addfile(info, io.BytesIO(payload))
            existing = root / 'artifacts/iphonesimulator/Debug/libsignal_ffi.a'
            existing.parent.mkdir(parents=True)
            compiled = b'!<arch>\n' + b'local-with-testing-symbols' * 100
            existing.write_bytes(compiled)
            with patch.object(signal, 'SIGNAL_ROOT', root), patch.object(signal, 'ensure_archive', return_value=archive), patch.object(signal.platform, 'machine', return_value='arm64'):
                signal.prepare_artifacts()
                self.assertTrue(signal.artifacts_ready())
                self.assertEqual(existing.read_bytes(), compiled)
                self.assertEqual((root / 'artifacts/iphoneos/Debug/libsignal_ffi.a').read_bytes(), payload)

    def test_tar_member_must_be_unique(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'duplicate.tar'
            with tarfile.open(path, 'w') as tar:
                for prefix in ('first', 'second'):
                    info = tarfile.TarInfo(prefix + '/target/libsignal_ffi.a')
                    info.size = 1
                    tar.addfile(info, io.BytesIO(b'a'))
            with tarfile.open(path) as tar:
                with self.assertRaises(RuntimeError):
                    signal.read_archive_member(tar, 'target/libsignal_ffi.a')

    def test_flattens_current_version_and_preserves_executable_and_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            framework = Path(directory) / 'tor.framework'
            for version in ('A', 'B'):
                source = framework / 'Versions' / version
                (source / 'Resources').mkdir(parents=True)
                (source / 'Headers').mkdir()
                (source / 'Headers/tor.h').write_text('void tor_main(void);')
                (source / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'tor'}))
                (source / 'tor').write_bytes(version.encode())
                (source / 'tor').chmod(0o755)
            (framework / 'Versions/Current').symlink_to('B')
            tor.flatten_ios_framework(framework)
            self.assertFalse((framework / 'Versions').exists())
            self.assertEqual(bundle.framework_binary(framework).read_bytes(), b'B')
            self.assertTrue((framework / 'Headers/tor.h').is_file())
            self.assertTrue((framework / 'tor').stat().st_mode & stat.S_IXUSR)
            tor.flatten_ios_framework(framework)

    def test_rejects_deep_bundle_during_device_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            framework = Path(directory) / 'tor.framework'
            (framework / 'Versions/A').mkdir(parents=True)
            with self.assertRaises(RuntimeError):
                bundle.framework_binary(framework)

    def test_static_tor_framework_does_not_receive_a_dylib_install_name(self):
        with tempfile.TemporaryDirectory() as directory:
            framework = Path(directory) / 'tor.framework'
            framework.mkdir()
            (framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'tor'}))
            (framework / 'tor').write_bytes(b'!<arch>\n')
            with patch.object(tor.platform, 'system', return_value='Darwin'), \
                 patch.object(tor.subprocess, 'check_output', return_value='MH_MAGIC_64 ARM64 ALL OBJECT'), \
                 patch.object(tor.subprocess, 'run') as run:
                run.return_value.returncode = 1
                tor.normalize_ios_binary(framework)
                self.assertFalse(any('install_name_tool' in call.args[0] for call in run.call_args_list))

    def test_xcframework_without_ios_slices_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': []}))
            with patch.object(tor, 'XCFRAMEWORK', root):
                self.assertFalse(tor.ios_slices_are_valid())

    def test_rejects_archive_symlink_outside_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as zf:
                link = zipfile.ZipInfo('escape')
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(link, '../outside')
            with self.assertRaises(RuntimeError):
                tor.safe_extract_with_symlinks(archive, root / 'extract')

    def test_keeps_internal_framework_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'safe.zip'
            with zipfile.ZipFile(archive, 'w') as zf:
                zf.writestr('tor.framework/Versions/A/tor', b'binary')
                link = zipfile.ZipInfo('tor.framework/tor')
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(link, 'Versions/A/tor')
            tor.safe_extract_with_symlinks(archive, root / 'extract')
            self.assertEqual((root / 'extract/tor.framework/tor').read_bytes(), b'binary')


if __name__ == '__main__':
    unittest.main()
