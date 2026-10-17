#!/usr/bin/env python3
"""Consistent SQLite snapshot and fail-closed restore to a NEW relay database."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid
from contextlib import closing

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
from app import verify_card

def inspect(connection):
    result=connection.execute('PRAGMA quick_check').fetchone()[0]
    if result!='ok': raise ValueError('SQLite integrity check failed')
    tables={row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not {'identities','sessions','envelopes','permanent_admin','moderator_mfa','bots'}.issubset(tables): raise ValueError('Unsupported relay schema')
    owner=connection.execute('SELECT owner,card FROM permanent_admin WHERE singleton=1').fetchone()
    if owner:
        card=verify_card(json.loads(owner[1]))
        if card['id']!=owner[0]: raise ValueError('Administrator ownership record invalid')
    return {'integrity':'ok','hasPermanentAdministrator':bool(owner),'identities':connection.execute('SELECT count(*) FROM identities').fetchone()[0]}

def snapshot(source,destination,restore=False):
    source=Path(source).absolute(); destination=Path(destination).absolute()
    if source.is_symlink() or not source.is_file() or source.resolve()==destination.resolve(): raise ValueError('Source must be a distinct regular database file')
    if destination.exists() or destination.is_symlink() or not destination.parent.is_dir(): raise ValueError('Destination must be new and its private directory must exist')
    if os.name!='nt' and destination.parent.stat().st_mode & 0o077: raise ValueError('Destination directory must be private (mode 700)')
    temporary=destination.with_name(destination.name+'.'+uuid.uuid4().hex+'.tmp')
    descriptor=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.close(descriptor)
    try:
        with closing(sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)) as original, closing(sqlite3.connect(temporary)) as copied:
            inspect(original); original.backup(copied); info=inspect(copied)
            if restore:
                tables={row[0] for row in copied.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                for table in ('sessions','challenges','moderator_sessions','call_authorities','moderator_recovery'):
                    if table in tables: copied.execute(f'DELETE FROM {table}')
                # A restored historical token digest must not revive a revoked
                # bot worker. Owner must rotate its credential then re-enable.
                columns={row[1] for row in copied.execute('PRAGMA table_info(bots)')}
                copied.execute('UPDATE bots SET enabled=0')
                if 'lease_instance' in columns: copied.execute('UPDATE bots SET lease_instance=NULL,lease_until=0')
                copied.commit(); info=inspect(copied)
            copied.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        with temporary.open('r+b') as stream: os.fsync(stream.fileno())
        # A hard-link installation is atomic and refuses replacing an existing
        # destination even if another process created it after the initial check.
        os.link(temporary,destination); temporary.unlink()
        if os.name!='nt':
            descriptor=os.open(destination.parent,os.O_RDONLY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
        with destination.open('rb') as stream: digest=hashlib.file_digest(stream,'sha256').hexdigest()
        info.update({'restored':restore,'sha256':digest})
        return info
    finally:
        if temporary.exists(): temporary.unlink()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation',choices=['backup','restore','verify']); parser.add_argument('--source',required=True); parser.add_argument('--destination')
    args=parser.parse_args()
    if args.operation=='verify':
        source=Path(args.source).absolute()
        if source.is_symlink() or not source.is_file(): parser.error('A regular source file is required')
        with closing(sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)) as database: result=inspect(database)
    else:
        if not args.destination: parser.error('--destination is required')
        result=snapshot(args.source,args.destination,restore=args.operation=='restore')
    print(json.dumps(result,sort_keys=True))

if __name__=='__main__': main()
