# Railway relay 2 work branch

Production origin: `https://f-production-448b.up.railway.app`, service `F`
in project `pleasant-beauty`, branch `codex/vo1d-next`.
The iPhone app migrates saved first-party `bdfe` and `5715` origins to this
address; custom relays keep their saved addresses.

1. Select repository `segiipozinovski12-cmd/F`, branch `codex/vo1d-next`. Take a database/volume backup before upgrading.
2. Set Root Directory to `/server`; use its Dockerfile.
3. Mount a persistent volume at `/data`, set healthcheck `/health`, generate an HTTPS domain.
4. The entrypoint uses injected `PORT`, prepares the data directory and starts aiohttp as UID 10001. There is one process; obsolete Gunicorn worker/thread variables have no effect.
5. Check `/health` and `/v2/capabilities`, then set the HTTPS domain in the client. Existing production deployments are not changed merely by creating this branch. A 1.3 relay cannot serve the v2 client.

Defaults: `VO1D_DB=/data/relay.sqlite3`, blobs `/data/blobs`, maximum seven-day blob retention. `VO1D_BLOB_RETENTION` can shorten it in seconds. Keep `/data` persistent across deployments.

The current service uses a 500 MB persistent volume at `/data` (the plan's
current limit), port `8080`, healthcheck `/health`, one replica, no sleep, and
the existing `server/Dockerfile`. The Docker build installs the exact hashed
dependencies from `requirements.lock`; no separate dependency service, Redis
or Gunicorn worker is required. Keep `VO1D_MODERATION_KEY` as a persistent
random 32-byte base64 Railway variable; never regenerate it on ordinary deploys.

Set `VO1D_TRUSTED_PROXIES` only after inspecting Railway's actual immediate proxy network and forwarded-header chain. Never use universal CIDRs. Inspect platform request logs, retention, snapshots and capabilities in URL paths separately; application logging configuration does not disable hosting-provider telemetry. Private mailbox/blob operations use capabilities without account IDs, but timing/network correlation remains possible.

APNs is optional. Configure `VO1D_APNS_KEY_ID`, `VO1D_APNS_TEAM_ID`, `VO1D_APNS_TOPIC` and either `VO1D_APNS_PRIVATE_KEY` containing the multiline P-256 `.p8` PEM as a Railway secret variable, or `VO1D_APNS_KEY_PATH` pointing to a securely provisioned readable file. Do not commit provider keys or bake them into a public image. See `../docs/DEPLOYMENT.md` for client entitlements and physical testing. No Apple credentials or paid infrastructure are provisioned by this change.

For a paid Apple development team, `VO1D_ENABLE_DEBUG_PUSH=1 python3 scripts/generate_project.py`
selects development APNs entitlements for Debug; regular Debug remains installable
with a Personal Team. Release keeps production APNs. The authenticated
`GET /v1/push/status` reports provider readiness without returning credentials.
Private queue notifications are opt-in and bind random mailbox IDs to the Apple
device token. Maximum privacy mode skips this binding. Neutral payloads contain
no account ID, sender, message text or mailbox ID.

A full account reset is inert unless `VO1D_REQUESTED_RESET` equals the exact
request ID in `reset_rollout.py`. This latest request permanently removes the
known prior reset backups after validating the fresh database. It requires explicit
operator authorization; clear the arming variable after verification. The first
cryptographically verified registration then receives permanent `@vo1d`.
The 2026-10-23 request is restricted to the exact project, service, production
environment, branch, domain and `/data` mount in `reset_rollout.py`. On a new
volume it also initializes the enrollment epoch. A persisted receipt makes the
request idempotent even if the arming variable survives a restart. Verify the
receipt in `/health` and the zero-account startup log, then remove the arming
variable before further deployments. This request applies only to this new
Railway database; it cannot erase data retained by a different Railway project.
