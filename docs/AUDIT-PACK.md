# Independent review handoff

Prepared for the `codex/anonymous-v2` work branch. This document is audit preparation, not an independent audit report. Production is not automatically updated by publishing this branch.

## Review material

- [Threat model](SECURITY.md), [v2 protocol and state transitions](PROTOCOL-V2.md), [60-item implementation ledger](ANONYMITY-V2.md), [research decisions](RESEARCH-DECISIONS.md).
- `SignalProtocol.swift`, `SignalStore.swift`, `PrivateMailbox*.swift`, `PrivateBlob.swift`, `APIClient.swift`, `NetworkRoute.swift`, `EmbeddedTorManager.swift`, `Calls.swift`, `BackgroundCalls.swift`, `DeviceLinks.swift`, `SecureBackup.swift`, `Profiles.swift` in `ios/VO1DMessenger/`.
- `server/prekeys.py`, `mailboxes.py`, `private_blobs.py`, `network_privacy.py`, `app.py`, `realtime.py`; schema migrations and server tests.
- Pinned libsignal submodule, Tor package URL/checksum and licence notices, Cargo lock, hash-locked Python dependencies and audit tool, pinned CI actions, generated project script, unsigned release evidence.
- `deploy/tor/`, Caddy and Compose configuration. Host access logs, Railway configuration, backups and actual DNS traffic are not included in the evidence.

## Required security review

1. SDK identity binding, prekey claim concurrency, key replacement, restore recovery, skipped keys, receive/ACK ordering, send/vault atomicity and crash replay. Test actual interop with the pinned SDK, including simultaneous initiation and peer reinstall.
2. Custom outer mailbox encryption/signature and capability distribution. Examine ID/timing correlation across invitation redemption, account bootstrap, uploads, notifications and mailbox rotation, not just database columns.
3. Group epochs, owner changes, invitation replay/revocation and out-of-order controls. Pairwise fanout is limited to 16; there is no MLS or cryptographic removal of past plaintext.
4. Call E2EE offer/counter/resume construction, delegated signing authority, expiry and socket replacement. The PCM/WSS engine remains custom. Local permission enforcement must be checked independently from server authorization.
5. Profile lifecycle, async task cancellation, scope binding, backup import rollback, stale capabilities, device certificate audience/revocation, incoming archive validation and attachment exclusions.
6. Rate buckets, trusted proxy chain handling, request/body limits, disk reservation, fd lifetime and delete/upload race conditions. Review SQLite/WAL/snapshot retention and single-process call routing.
7. Dependency update procedure, upstream binary trust and licences, artifact provenance, Apple signing and release policies. A dependency scan does not find design flaws.

## Physical-device matrix

Use at least two provisioned iPhones. Record iOS/app versions, network, permission state and pass/fail observations without including real keys, messages or push tokens.

| Area | Cases | Evidence required |
|---|---|---|
| Protected data | Reboot before first unlock, locked after unlock, foreground/background/terminated | Vault/message keys unavailable when locked; only explicit delegated call authority usable after first unlock. |
| Push / CallKit | Sandbox and production, report/answer/decline/cancel/end, notifications disabled | Neutral payload; prompt CallKit report; correct audio activation and permission handling. |
| Tor / DNS | Bootstrap, bridge failure, proxy unavailable, redirect, onion and clearnet relay | Device/router packet capture: no direct fallback; no destination DNS leak from app-owned requests. Separate APNs/browser traffic. |
| Calls | Two-way audio, 44.1/48 kHz devices, headphones/Bluetooth, interruptions, Wi-Fi→mobile and back | intelligible sample rate, no counter reset/replay, bounded reconnect and clean end. |
| Devices | Two-sided verification, wrong audience, expiration, revoke during queued transfer, profile switch | Separate private keys; revoked grants unusable; clearly limited manual history mode. |
| Recovery | Wrong password, damaged/large backup, old vault, full restore, failed write | No partial identity switch or ratchet counter rollback; actionable peer/key recovery. |
| Media / UI | Preview crash/background, denied photo/microphone permission, large files, VoiceOver, Reduce Motion, Dynamic Type | No surviving owned plaintext temp; readable black/white interface and usable focus/order. |

## Performance and fuzz work still required

CI has bounded concurrency/regression tests. Before a capacity claim, benchmark queue throughput, mailbox polling, multi-client calls, 50 MiB uploads, disk exhaustion, prolonged disconnects and cleanup under peak load. Report hardware, database size, concurrency, p50/p95/p99 latency, error/loss rate, CPU/RAM/disk and duration. No measured production capacity is claimed.

Mutation tests exercise malformed HTTP/WS and SDK ciphertext. A coverage-guided campaign still needs isolated reproducible corpus/seeds, resource/time limits, sanitizers for native parsers where supported, minimized crash cases and a triage log. Do not feed production ciphertext or private keys into a public corpus.

## Exit criteria

External reviewers must produce a report tied to a source commit, with findings, severity, reproduction and remediation evidence. Release requires resolving material findings and completing physical QA and deployment inspection. GitHub green checks, provenance and this handoff document do not satisfy those conditions on their own.
