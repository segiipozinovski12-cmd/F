import importlib.util
from pathlib import Path
import plistlib
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import io
import os
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
isolate = load('isolate_signal')
cache = load('configure_xcode_cache')


def require_symlinks(case):
    if os.name == 'nt':
        case.skipTest('POSIX framework links and executable modes are exercised on macOS/Linux CI')
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / 'target'
        target.touch()
        try:
            (Path(directory) / 'probe').symlink_to(target)
        except OSError as exc:
            if getattr(exc, 'winerror', None) == 1314:
                case.skipTest('Windows account lacks symlink privileges; exercised on macOS/Linux CI')
            raise


def archive_member(name, data, long_name=False):
    prefix = name.encode() if long_name else b''
    stored_name = ('#1/' + str(len(prefix))) if long_name else name + '/'
    payload = prefix + data
    header = f'{stored_name:<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(payload):<10}`\n'.encode()
    return header + payload + (b'\n' if len(payload) % 2 else b'')


class NativeSetupTests(unittest.TestCase):
    def test_project_cache_overrides_broken_global_path_and_preserves_other_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'Project With Spaces.xcodeproj'
            settings = project / 'project.xcworkspace/xcuserdata/tester.xcuserdatad/WorkspaceSettings.xcsettings'
            settings.parent.mkdir(parents=True)
            settings.write_bytes(plistlib.dumps({
                'DerivedDataLocationStyle': 'AbsolutePath',
                'DerivedDataCustomLocation': '/unwritable/global/DerivedData',
                'LiveSourceIssuesEnabled': False,
            }))
            destination = root / 'build/cache with spaces'
            self.assertEqual(cache.configure(project, destination, 'tester'), settings)
            values = plistlib.loads(settings.read_bytes())
            self.assertEqual(values['DerivedDataCustomLocation'], str(destination))
            self.assertEqual(values['DerivedDataLocationStyle'], 'AbsolutePath')
            self.assertFalse(values['LiveSourceIssuesEnabled'])
            self.assertEqual(list(destination.iterdir()), [])
            original = settings.read_bytes()
            cache.configure(project, destination, 'tester')
            self.assertEqual(settings.read_bytes(), original)

    def test_unwritable_cache_fails_before_modifying_workspace_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'Project.xcodeproj'; project.mkdir()
            destination = root / 'not-a-directory'; destination.write_text('keep')
            with self.assertRaises(OSError):
                cache.configure(project, destination, 'tester')
            self.assertFalse((project / 'project.xcworkspace').exists())
            self.assertEqual(destination.read_text(), 'keep')

    def test_invalid_existing_workspace_settings_are_not_silently_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'Project.xcodeproj'
            settings = project / 'project.xcworkspace/xcuserdata/tester.xcuserdatad/WorkspaceSettings.xcsettings'
            settings.parent.mkdir(parents=True)
            settings.write_bytes(b'broken existing settings')
            with self.assertRaises(plistlib.InvalidFileException):
                cache.configure(project, root / 'build', 'tester')
            self.assertEqual(settings.read_bytes(), b'broken existing settings')

    def test_callkit_modes_are_present_in_debug_and_release_metadata(self):
        app = SCRIPTS.parent / 'ios' / 'VO1DMessenger'
        for name in ('Info.Debug.plist', 'Info.plist'):
            with self.subTest(configuration=name):
                info = plistlib.loads((app / name).read_bytes())
                bundle.validate_call_configuration(info)

    def test_bundle_validation_rejects_audio_only_debug_before_native_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'VO1DMessenger', 'UIBackgroundModes': ['audio'],
            }))
            with self.assertRaisesRegex(RuntimeError, "CallKit requires.*voip"):
                bundle.validate(app)

    def test_callkit_modes_do_not_require_an_apns_entitlement(self):
        app = SCRIPTS.parent / 'ios' / 'VO1DMessenger'
        debug = plistlib.loads((app / 'Info.Debug.plist').read_bytes())
        entitlements = plistlib.loads((app / 'VO1DMessenger.Debug.entitlements').read_bytes())
        self.assertFalse(debug['VO1DPushEnabled'])
        self.assertNotIn('aps-environment', entitlements)
        bundle.validate_call_configuration(debug)

    def test_signal_archive_preserves_bsd_names_and_removes_stale_symbol_index(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'signal.a'
            name = 'very-long-native-object-name.o'
            archive.write_bytes(b'!<arch>\n' + archive_member('__.SYMDEF SORTED', b'old-offsets', True)
                                + archive_member(name, b'native-object', True))
            members = list(isolate.archive_members(archive))
            self.assertEqual([(member[2], member[3]) for member in members], [(name, b'native-object')])
            archive.write_bytes(archive.read_bytes()[:-3])
            with self.assertRaises(RuntimeError):
                list(isolate.archive_members(archive))

    def test_signal_ir_is_native_before_the_framework_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'source.a', root / 'native.a'
            source.write_bytes(b'!<arch>\n' + archive_member('kem.o', b'BC\xc0\xdeIR')
                               + archive_member('assembly.o', b'existing-native'))
            def execute(args, **kwargs):
                if 'clang' in args:
                    Path(args[-1]).write_bytes(b'compiled-native')
            with patch.object(isolate.subprocess, 'run', side_effect=execute) as run:
                isolate.materialize_native_archive(source, output, 'arm64-apple-ios13.0', '/sdk')
            self.assertEqual([(member[2], member[3]) for member in isolate.archive_members(output)],
                             [('kem.o', b'compiled-native'), ('assembly.o', b'existing-native')])
            self.assertTrue(any('ranlib' in call.args[0] for call in run.call_args_list))

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
        require_symlinks(self)
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
        require_symlinks(self)
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
