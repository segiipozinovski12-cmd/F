#!/bin/sh
set -eu

PORT="${PORT:-8080}"
VO1D_DB="${VO1D_DB:-/data/relay.sqlite3}"
DB_DIR="$(dirname "$VO1D_DB")"

mkdir -p "$DB_DIR"
chown relay:relay "$DB_DIR"

export VO1D_DB

exec gosu relay gunicorn \
  --bind "0.0.0.0:${PORT}" \
  --workers "${WEB_CONCURRENCY:-2}" \
  --threads "${GUNICORN_THREADS:-4}" \
  --timeout 45 \
  --graceful-timeout 20 \
  --keep-alive 5 \
  --limit-request-line 4094 \
  --limit-request-fields 30 \
  --access-logfile - \
  --error-logfile - \
  "app:create_app()"
