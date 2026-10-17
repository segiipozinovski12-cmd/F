#!/bin/sh
set -eu

PORT="${PORT:-8080}"
VO1D_DB="${VO1D_DB:-/data/relay.sqlite3}"
DB_DIR="$(dirname "$VO1D_DB")"

mkdir -p "$DB_DIR"
chown relay:relay "$DB_DIR"

export PORT
export VO1D_DB

# One-time account reset explicitly requested on 2026-10-17. Remove after verification.
gosu relay python reset_rollout.py

exec gosu relay python realtime.py
