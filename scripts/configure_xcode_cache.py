#!/usr/bin/env python3
"""Keep this project's Xcode cache out of the user's global DerivedData."""
import argparse
import getpass
from pathlib import Path
import plistlib
import tempfile


def configure(project: Path, derived_data: Path, username: str = None) -> Path:
    project = project.resolve(strict=True)
    derived_data = derived_data.resolve()
    derived_data.mkdir(parents=True, exist_ok=True)
    # Actually write a plist: access() alone misses ACLs and a full disk.
    with tempfile.TemporaryFile(dir=derived_data) as probe:
        plistlib.dump({'VO1DWriteProbe': True}, probe)
        probe.flush()
    username = username or getpass.getuser()
    if Path(username).name != username or username in ('', '.', '..'):
        raise ValueError('Invalid Xcode username')
    settings = (project / 'project.xcworkspace' / 'xcuserdata'
                / (username + '.xcuserdatad') / 'WorkspaceSettings.xcsettings')
    values = plistlib.loads(settings.read_bytes()) if settings.exists() else {}
    if not isinstance(values, dict):
        raise ValueError('Xcode workspace settings must be a dictionary')
    values['DerivedDataLocationStyle'] = 'AbsolutePath'
    values['DerivedDataCustomLocation'] = str(derived_data)
    settings.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=settings.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            plistlib.dump(values, output)
            output.flush()
            temporary.replace(settings)
        finally:
            temporary.unlink(missing_ok=True)
    return settings


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('derived_data', type=Path)
    args = parser.parse_args()
    try:
        configure(args.project, args.derived_data)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, 'Cannot prepare the project build cache: ' + str(error) + '\n')
    print('Xcode cache: ' + str(args.derived_data.resolve()))
