# Deploy relay 1.3

Use branch `codex/privacy-expansion` for both the client and server. Changes in GitHub do not redeploy an existing service automatically unless the operator has configured that integration. Take a database backup before replacing an existing installation; new privacy tables are created on startup.

## Docker and HTTPS

1. Point a domain to the host; install Docker Engine and Compose.
2. Copy `.env.example` to `.env` and set `VO1D_DOMAIN`.
3. Allow TCP 80/443. Keep port 8080 private.
4. Run `docker compose up -d --build`.
5. Check `https://your-domain/health`, then set this HTTPS URL in the iOS relay settings.

Caddy provides TLS and WSS. `/data` persists SQLite and ciphertext blobs in `relay-data`. One aiohttp process handles HTTP/WSS calls and maintenance; do not run independent workers without shared call routing. The container drops to UID 10001; root is used only to prepare the mounted data directory. Avoid access logs containing authorization headers, device tokens or bodies.

```bash
docker compose ps
docker compose logs --tail=80 relay
```

`docker compose down -v` erases volumes. Logical deletions do not erase host backups or SQLite remnants. Blob retention is at most seven days; `VO1D_BLOB_RETENTION` can shorten it (seconds, minimum 60). Maintenance runs every 30 seconds.

## Optional Apple push

Create an APNs provider key through your Apple developer account. Configure the actual application Bundle Identifier with Push Notifications; Debug uses the sandbox entitlement and Release uses production. Use a provisioning profile containing these capabilities. PushKit uses the same application topic with `.voip` appended.

Set these variables in `.env`:

- `VO1D_APNS_KEY_ID`: provider key ID.
- `VO1D_APNS_TEAM_ID`: Apple Team ID.
- `VO1D_APNS_TOPIC`: exact app Bundle Identifier.
- `VO1D_APNS_KEY_FILE`: host path to your `.p8` file.

Keep the file outside Git. Ensure UID 10001 can read the mounted key with restrictive permissions; do not put the key contents in logs, source, screenshots or this repository.

```bash
docker compose -f compose.yaml -f compose.push.yaml up -d --build
```

Without these settings ordinary foreground delivery and WSS calls continue, but server push is disabled. APNs delivery is best effort; background execution and user permissions are controlled by iOS. The implementation uses HTTP/2 and ES256 provider JWTs, handles invalid tokens and sends neutral alert payloads. Disabling notifications deletes registrations on the connected relay.

## Device validation still required

Use two physical iPhones and provisioned builds. Test sandbox and production tokens, app foreground/background/termination, locked phone after reboot and first unlock, immediate CallKit reporting, answer/decline/end, caller cancellation, no network, proxy failure, blocking, verified-only policy, microphone and notification permission refusal. Check that incoming pushes expose no text/name, and that message/vault keys remain unavailable while protected data is locked. The separate background-call signing key is deliberately available after first unlock; disable background calls if that tradeoff is unsuitable.

Test requests, one-use invitation concurrency, QR mismatch, offline queue, corrupted attachment/backup, wrong password, old-vault migration, local/media clearing, inactivity cleanup and receipt settings. Simulator CI does not replace these phone scenarios.

## Signing and release

Open the Xcode project, set your Team and Bundle Identifier, connect an iPhone and Run. Distribution requires an archive signed by your team. No signed IPA or production deployment is included. Keep the app and APNs topic consistent when renaming the identifier. Complete actual privacy disclosures and applicable export review before distribution.
