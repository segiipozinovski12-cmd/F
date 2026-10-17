"""One-time reset explicitly requested for the named VO1D production service.
Runs before opening HTTP and only on its persistent Railway volume. Remove the
entrypoint invocation after rollout; never use this as an automatic recurring job.
"""
import os
from pathlib import Path
import sqlite3
from contextlib import closing
from maintenance import reset

ROLLOUT = 'vo1d-user-request-20261017-a4ba0300'


def apply_requested_reset():
    expected = {
        'RAILWAY_PUBLIC_DOMAIN': 'f-production-bdfe.up.railway.app',
        'RAILWAY_GIT_BRANCH': 'codex/vo1d-next',
        'RAILWAY_GIT_REPO_NAME': 'F',
        'RAILWAY_GIT_REPO_OWNER': 'segiipozinovski12-cmd',
        'RAILWAY_VOLUME_MOUNT_PATH': '/data',
    }
    if os.environ.get('VO1D_DISABLE_REQUESTED_RESET') == '1' or any(os.environ.get(k) != v for k,v in expected.items()):
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
                print('Requested account reset: already completed.', flush=True)
                return False
    blob = Path(os.environ.get('VO1D_BLOB_DIR', '/data/blobs'))
    if blob.resolve() != Path('/data/blobs'):
        raise RuntimeError('Requested reset refused an unexpected blob directory')
    backup = Path('/data') / ('reset-backup-' + ROLLOUT)
    reset(path, backup, blob if blob.is_dir() else None, rollout_id=ROLLOUT)
    print('Requested account reset: completed with verified persistent backup; first explicit @vo1d claim becomes permanent administrator.', flush=True)
    return True


if __name__ == '__main__': apply_requested_reset()
