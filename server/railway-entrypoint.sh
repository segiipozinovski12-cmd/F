#!/bin/sh
set -eu

PORT="${PORT:-8080}"
VO1D_DB="${VO1D_DB:-/data/relay.sqlite3}"
DB_DIR="$(dirname "$VO1D_DB")"

mkdir -p "$DB_DIR"
chown relay:relay "$DB_DIR"

export PORT
export VO1D_DB

exec gosu relay python realtime.py
