"""One-time reset explicitly requested for the named VO1D production service.
Runs before opening HTTP and only when the exact request is armed on its
persistent Railway volume. Clear VO1D_REQUESTED_RESET after verification.
"""
import os
from pathlib import Path
import sqlite3
import re
import shutil
from contextlib import closing
from maintenance import reset

ROLLOUT = 'vo1d-user-request-20261017-c9eb809a'


def purge_account_backups(root):
    """This request explicitly asks for permanent deletion, including old resets."""
    for backup in Path(root).glob('reset-backup-vo1d-user-request-*'):
        if not re.fullmatch(r'reset-backup-vo1d-user-request-[0-9]{8}-[a-f0-9]{8}', backup.name):
            continue
        if backup.is_symlink() or not backup.is_dir():
            raise RuntimeError('Refusing an unexpected reset-backup entry')
        shutil.rmtree(backup)


def apply_requested_reset():
    expected = {
        'RAILWAY_PUBLIC_DOMAIN': 'f-production-bdfe.up.railway.app',
        'RAILWAY_GIT_BRANCH': 'codex/vo1d-next',
        'RAILWAY_GIT_REPO_NAME': 'F',
        'RAILWAY_GIT_REPO_OWNER': 'segiipozinovski12-cmd',
        'RAILWAY_VOLUME_MOUNT_PATH': '/data',
    }
    if os.environ.get('VO1D_REQUESTED_RESET') != ROLLOUT or os.environ.get('VO1D_DISABLE_REQUESTED_RESET') == '1' or any(os.environ.get(k) != v for k,v in expected.items()):
        print('Requested account reset: skipped (target/persistent-volume guard).', flush=True)
        return False
    path = Path(os.environ.get('VO1D_DB', '/data/relay.sqlite3'))
    if path.resolve() != Path('/data/relay.sqlite3') or not path.is_file():
        print('Requested account reset: skipped (existing target DB required).', flush=True)
        return False
    with closing(sqlite3.connect(path)) as db:
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='relay_meta'").fetchone():
            row = db.execute("SELECT value FROM relay_meta WHERE key='completed_reset_rollout'").fetchone()
            if row and row[0] == ROLLOUT:
                purge_account_backups('/data')
                print('Requested account reset: already completed.', flush=True)
                return False
    blob = Path(os.environ.get('VO1D_BLOB_DIR', '/data/blobs'))
    if blob.resolve() != Path('/data/blobs'):
        raise RuntimeError('Requested reset refused an unexpected blob directory')
    backup = Path('/data') / ('reset-backup-' + ROLLOUT)
    reset(path, backup, blob if blob.is_dir() else None, rollout_id=ROLLOUT, first_registration_admin=True)
    with closing(sqlite3.connect(path)) as db:
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok' or any(
            db.execute('SELECT count(*) FROM ' + table).fetchone()[0]
            for table in ('identities', 'sessions', 'usernames', 'permanent_admin')
        ):
            raise RuntimeError('Fresh account database failed reset verification')
    purge_account_backups('/data')
    print('Requested account reset: completed; zero accounts/sessions/usernames/owners verified; old account backups removed; first verified registration becomes permanent @vo1d administrator.', flush=True)
    return True


if __name__ == '__main__': apply_requested_reset()
