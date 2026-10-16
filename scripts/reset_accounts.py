#!/usr/bin/env python3
"""Offline relay reset. Stop the service first. Defaults to a read-only preview."""
import argparse
import os
from pathlib import Path
import secrets
import sqlite3
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from app import Relay


def reset(path, backup, blob_dir=None):
    path, backup = Path(path), Path(backup)
    if not path.is_file() or path.is_symlink() or backup.exists():
        raise ValueError('Use an existing regular DB and a new backup directory')
    blob = Path(blob_dir) if blob_dir else None
    if blob and (blob.is_symlink() or not blob.is_dir()):
        raise ValueError('Invalid blob directory')
    if backup.resolve().is_relative_to(path.resolve().parent) and backup.resolve() == path.resolve().parent:
        raise ValueError('Backup must be separate from the database')
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    saved = backup / 'relay.sqlite3'
    with sqlite3.connect(path) as source, sqlite3.connect(saved) as destination:
        source.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        source.backup(destination)
        if destination.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Backup failed validation')
    os.chmod(saved, 0o600)
    staged = path.with_name(path.name + '.reset-' + secrets.token_hex(8))
    relay = Relay(staged)
    with relay.db() as db:
        db.execute("INSERT INTO relay_meta VALUES ('bootstrap_first_session','1')")
        db.execute("INSERT INTO relay_meta VALUES ('account_epoch',?)", (secrets.token_hex(16),))
    with sqlite3.connect(staged) as db:
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    os.chmod(staged, 0o600)
    os.chown(staged, path.stat().st_uid, path.stat().st_gid)
    # Both filesystems must support the atomic rename. Blobs are moved intact
    # into the backup, never recursively deleted by this command.
    if blob:
        if backup.resolve().is_relative_to(blob.resolve()):
            raise ValueError('Backup cannot be inside the blob directory')
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


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--db', required=True)
    p.add_argument('--backup')
    p.add_argument('--blob-dir')
    p.add_argument('--server-stopped', action='store_true')
    p.add_argument('--confirm', choices=['DELETE-ALL-ACCOUNTS'])
    a = p.parse_args()
    if not a.confirm:
        # mode=ro ensures a typo cannot create a new empty production database.
        with sqlite3.connect(Path(a.db).resolve().as_uri() + '?mode=ro', uri=True) as db:
            count = db.execute('SELECT count(*) FROM identities').fetchone()[0]
        print(f'Preview: {count} accounts. Reset removes all server records, sessions, usernames and moderator ownership. Nothing changed.')
    else:
        if not a.server_stopped or not a.backup:
            p.error('Stop the relay and supply --server-stopped and a new --backup directory')
        print('Reset complete. Backup:', reset(a.db, a.backup, a.blob_dir))
        print('The first cryptographically authenticated session becomes permanent @vo1d administrator. Restart only when ready to claim it.')
