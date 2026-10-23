# Relay backups, restore and launch checks

Install the pinned server dependencies first. Keep the relay database, blob directory and `VO1D_MODERATION_KEY` on persistent private storage. Provision the intended `@vo1d` identity and MFA before public registration. `@vo1d` remains permanent only for that authoritative database; do not discard it during upgrades.

## Database snapshot

```bash
install -d -m 700 /private/vo1d-backups
python3 scripts/relay_backup.py backup --source /srv/vo1d/relay.sqlite3 --destination /private/vo1d-backups/relay-2026-10-14.sqlite3
python3 scripts/relay_backup.py verify --source /private/vo1d-backups/relay-2026-10-14.sqlite3
```

Choose the actual deployment source path and a new destination filename. The utility uses SQLite's backup API for a consistent snapshot including committed WAL changes, verifies integrity/schema and the pinned signed administrator card, fsyncs a private file and installs it without replacing an existing destination. It emits only checksum/counts/owner-presence, never account keys, tokens or evidence. POSIX directories must be mode 700 and files are mode 600; protect Windows ACLs separately. Store backups and the persistent moderation secret independently in a trusted encrypted backup system; a private SQLite file contains sensitive routing/moderation metadata and is not a complete at-rest encrypted database.

Blob ciphertext lives separately. Quiesce uploads while snapshotting that directory with your host's backup system, retain corresponding deletion/retention policy, and test restore on staging. The database utility does not back up blobs, secrets, TLS, onion identity or APNs material automatically. Never publish operator backups as CI artifacts.

## Restore to a new path

Stop the old relay and all external bot workers before changing the authoritative database. Restore to a **new** private destination, verify the result, provision the original moderation secret and corresponding blob snapshot, then change the host's configured database path:

```bash
python3 scripts/relay_backup.py restore --source /private/vo1d-backups/relay-2026-10-14.sqlite3 --destination /srv/vo1d-private/restored.sqlite3
python3 scripts/relay_backup.py verify --source /srv/vo1d-private/restored.sqlite3
```

The destination directory must already exist and be private. Existing destination files, symlinks, corrupt schema and mismatched permanent-owner records fail closed. The script does not replace a deployed DB, start services or rewrite host configuration.

Restore preserves the permanent owner and encrypted MFA record but discards account/challenge/moderator/call sessions and MFA recovery codes. It disables all bots and clears their active leases, preventing restored historical credentials from immediately reviving workers. Authenticate again; each bot owner must rotate its token and explicitly re-enable it. An old DB may contain an earlier authenticator secret, policies or capability records. Use the matching authenticator backup and carefully reconcile later revocations/retention; restoring historical capabilities is an operator privacy/security decision. Issue new recovery codes after a fresh MFA login. No server snapshot can recreate client ratchet keys, erase received copies or prove the latest bot state.

Tests restore a fresh relay, reject old sessions, preserve the original @vo1d owner, reject conflicting claims and keep restored bot/recovery credentials inactive. Run an actual host/secret/blob restore drill before release; the unit test is not a disaster-recovery SLA.

## Candidate checks

For the exact candidate, run server/setup/worker tests, Python/npm dependency audits, coverage-guided parser fuzzing, both native builds/tests, bundle validation and Docker checks. Compare the pinned source commit with the artifacts' manifests. Monitor only aggregated health/queue/disk counts; never log request bodies, E2EE content, headers/capabilities or MFA secrets. `/health` and authenticated moderation metrics provide bounded indicators, not a production SLO.

Stage two physical iPhones for ordinary/private messages, selected-report evidence, MFA recovery, appeal, native/external bot handoff, linked-device send/files/revocation, locked storage, disk-full, long offline queues, Tor-only failures and mobile/Wi-Fi changes. Record behavior and budget RAM/disk/latency on the actual deployment. Review licences, privacy disclosures, Apple provisioning/APNs/PushKit and rollback behavior. CI unsigned archives and provenance do not install a signed app or supply an independent audit.
