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


from maintenance import reset


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
