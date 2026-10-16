"""Offline reset implementation; never exposed over HTTP."""
import os
from pathlib import Path
import secrets
import sqlite3
from contextlib import closing
from app import Relay


def reset(path, backup, blob_dir=None, rollout_id=None):
    path, backup = Path(path), Path(backup)
    if not path.is_file() or path.is_symlink() or backup.exists():
        raise ValueError('Use an existing regular DB and a new backup directory')
    blob = Path(blob_dir) if blob_dir else None
    if blob and (blob.is_symlink() or not blob.is_dir()):
        raise ValueError('Invalid blob directory')
    if blob and (backup.resolve().is_relative_to(blob.resolve()) or path.resolve().is_relative_to(blob.resolve())):
        raise ValueError('Database and backup must be outside the blob directory')
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    if blob and blob.stat().st_dev != backup.stat().st_dev:
        raise ValueError('Blob backup must be on the same filesystem')
    saved = backup / 'relay.sqlite3'
    with closing(sqlite3.connect(path)) as source, closing(sqlite3.connect(saved)) as destination:
        if source.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] != 0:
            raise ValueError('Database is busy; stop the relay before resetting')
        source.backup(destination)
        if destination.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Backup failed validation')
    os.chmod(saved, 0o600)
    staged = path.with_name(path.name + '.reset-' + secrets.token_hex(8))
    relay = Relay(staged)
    with relay.db() as db:
        db.execute("INSERT INTO relay_meta VALUES ('bootstrap_first_session','1')")
        db.execute("INSERT INTO relay_meta VALUES ('account_epoch',?)", (secrets.token_hex(16),))
        if rollout_id:
            db.execute("INSERT INTO relay_meta VALUES ('completed_reset_rollout',?)", (rollout_id,))
    with closing(sqlite3.connect(staged)) as db:
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    os.chmod(staged, 0o600)
    os.chown(staged, path.stat().st_uid, path.stat().st_gid)
    # Both filesystems must support the atomic rename. Blobs are moved intact
    # into the backup, never recursively deleted by this command.
    if blob:
        os.rename(blob, backup / 'blobs')
        blob.mkdir(mode=0o700)
        info = (backup / 'blobs').stat()
        os.chown(blob, info.st_uid, info.st_gid)
    for suffix in ('-wal', '-shm'):
        Path(str(path) + suffix).unlink(missing_ok=True)
    os.replace(staged, path)
    for suffix in ('-wal', '-shm'):
        Path(str(staged) + suffix).unlink(missing_ok=True)
    return saved

