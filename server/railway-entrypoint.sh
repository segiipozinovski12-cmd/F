#!/bin/sh
set -eu

PORT="${PORT:-8080}"
VO1D_DB="${VO1D_DB:-/data/relay.sqlite3}"
DB_DIR="$(dirname "$VO1D_DB")"

mkdir -p "$DB_DIR"
chown relay:relay "$DB_DIR"

export PORT
export VO1D_DB

# Inert during normal deploys. The operator must arm the exact, idempotent request.
if [ -n "${VO1D_REQUESTED_RESET:-}" ]; then
    gosu relay python reset_rollout.py
fi

exec gosu relay python realtime.py
