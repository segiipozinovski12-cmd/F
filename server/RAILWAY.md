# Railway relay 2 work branch

1. Select repository `segiipozinovski12-cmd/F`, branch `codex/anonymous-v2`. Take a database/volume backup before upgrading.
2. Set Root Directory to `/server`; use its Dockerfile.
3. Mount a persistent volume at `/data`, set healthcheck `/health`, generate an HTTPS domain.
4. The entrypoint uses injected `PORT`, prepares the data directory and starts aiohttp as UID 10001. There is one process; obsolete Gunicorn worker/thread variables have no effect.
5. Check `/health` and `/v2/capabilities`, then set the HTTPS domain in the client. Existing production deployments are not changed merely by creating this branch. A 1.3 relay cannot serve the v2 client.

Defaults: `VO1D_DB=/data/relay.sqlite3`, blobs `/data/blobs`, maximum seven-day blob retention. `VO1D_BLOB_RETENTION` can shorten it in seconds. Keep `/data` persistent across deployments.

Set `VO1D_TRUSTED_PROXIES` only after inspecting Railway's actual immediate proxy network and forwarded-header chain. Never use universal CIDRs. Inspect platform request logs, retention, snapshots and capabilities in URL paths separately; application logging configuration does not disable hosting-provider telemetry. Private mailbox/blob operations use capabilities without account IDs, but timing/network correlation remains possible.

APNs is optional. Configure `VO1D_APNS_KEY_ID`, `VO1D_APNS_TEAM_ID`, `VO1D_APNS_TOPIC` and `VO1D_APNS_KEY_PATH` pointing to a securely provisioned, readable `.p8` file. Do not commit provider keys or bake them into a public image. See `../docs/DEPLOYMENT.md` for client entitlements and physical testing. No Apple credentials or paid infrastructure are provisioned by this change.
