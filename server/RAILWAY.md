# Railway relay 1.3

1. Select repository `segiipozinovski12-cmd/F`, branch `codex/privacy-expansion`.
2. Set Root Directory to `/server`; use its Dockerfile.
3. Mount a persistent volume at `/data`, set healthcheck `/health`, generate an HTTPS domain.
4. The entrypoint uses injected `PORT`, prepares the data directory and starts aiohttp as UID 10001. There is one process; obsolete Gunicorn worker/thread variables have no effect.
5. Set the HTTPS domain in the client. Existing production deployments are not changed merely by creating this branch.

Defaults: `VO1D_DB=/data/relay.sqlite3`, blobs `/data/blobs`, maximum seven-day blob retention. `VO1D_BLOB_RETENTION` can shorten it in seconds. Keep `/data` persistent across deployments.

APNs is optional. Configure `VO1D_APNS_KEY_ID`, `VO1D_APNS_TEAM_ID`, `VO1D_APNS_TOPIC` and `VO1D_APNS_KEY_PATH` pointing to a securely provisioned, readable `.p8` file. Do not commit provider keys or bake them into a public image. See `../docs/DEPLOYMENT.md` for client entitlements and physical testing. No Apple credentials or paid infrastructure are provisioned by this change.
