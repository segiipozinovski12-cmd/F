# VO1D NEXT implementation ledger

Branch `codex/vo1d-next` starts at `48f7ee7fb78050c0c6e99bf915df72a342b107d5` on `codex/anonymous-v2`. [Draft PR #5](https://github.com/segiipozinovski12-cmd/F/pull/5). This is substantive implementation work, not a claim that every P0–P4 item or a release is complete.

## Implemented additions

| Priority | Change | Practical boundary |
| --- | --- | --- |
| P0 | Keychain record validation and duplicate-creation recovery | Damaged keys fail closed; hardware recovery still needs QA |
| P0 | One shared in-flight account authentication operation | Concurrent requests stop creating competing token sessions |
| P0 | Delivery retry/backoff state inside encrypted vault | Survives restart/profile switch; ready message bytes remain unchanged |
| P0 | Explicit SQLite secure-delete/synchronous policy per connection | Does not physically erase snapshots/WAL or prove crash durability on every host |
| P0 | Call sanction/session rechecks | Ordinary session revocation rechecked at a bounded interval; physical handover/APNs QA remains |
| P1 | Permanent first-claim @vo1d | Username, keys, owner tombstone and verified MFA cannot be reset through ordinary deletion/rename |
| P1 | Profile/chat/message reporting with opt-in selected evidence | Exact ciphertext queued; comments/attachments bounded; no generic chat-key access |
| P1 | MFA, role scopes, queue, decisions, appeals and audit | Owner-only evidence; delegated reviewers/admins have metadata/decision scopes |
| P1 | Paged filtered queue, assignment and independent appeal decisions | Shared revisions; owner self-review requires an explicit audited acknowledgement |
| P1 | Reporter quotas, duplicate protection and aggregate metrics | No automatic majority ban; does not eliminate Sybil abuse |
| P1 | Local suspicious-link checks and explicit exit confirmation | No remote browsing submission or malware-reputation guarantee |
| P1 | Trust Circle UI and existing consent synchronization | Local contact selection; relay sees calls consent IDs |
| P3 | Private Spaces on independent key/vault namespaces | Device-authenticated switch, stronger defaults, one active identity at a time |
| P3 | Local Security Check and Device Guard controls | Findings reflect local configuration, not an independent security verdict |
| P3 | Secure Notes | Local encrypted vault, no network serialization; full backup can include notes |
| P3 | Smart Queue improvements and bot-aware expiry | Existing scheduled/cancel/retry functions preserved |
| P2 | Opt-in automatic device text snapshots | Last 200 texts/polls in a read-only archive; no secondary sending/files/calls |
| P3 | Durable private links, bot invitations and selective queued revocation | Used/revoked links cannot resurrect on retry; redeemed chat addresses need separate revocation |
| P3 | One-view text and consumed tombstones | Cleared before display, omitted from previews/search/export; modified or older clients may retain copies |
| P4 | Native black/white form/list screens with semantic type styles | VoiceOver/Dynamic Type and physical visual review remain required |
| P4 | New abuse/parser/crypto/restart tests and a local load harness | Bounded deterministic tests, not coverage-guided fuzzing or production capacity evidence |
| Additional | Real BotFather registry, scoped worker token and native libsignal executor | Foreground canned-command workers; external 24/7 execution/handoff remain incomplete |

The branch retains existing conversations, Tor/strict SOCKS routes, private mailboxes/blobs, groups, calls, notifications, identity profiles, scoped aliases, history archives and old history reading. Existing room timers/private invitations/file encryption supply parts of Ghost Messages, Private Links, Privacy Profiles and secure file transfer; they are not counted as new complete implementations here.

## Validation record

The first published native implementation is commit `8e7fff9208584ab9d90b1bbc9cbb3844723fdfcd`; [Actions run 38447488565](https://github.com/segiipozinovski12-cmd/F/actions/runs/38447488565). Server and both complete native jobs passed: Simulator Debug, device Debug, XCTest, unsigned device Release and packaging on macOS 15 and 26. Later source changes require their own CI result; do not attribute them to this earlier commit.

Locally, the expanded server suite passed **106 tests**, including first-claim races, MFA/replay/roles, independent appeals, concurrent assignment, cursor pagination, private-link retry resurrection, signed/opaque non-contributory key rejection, bot ownership/token revocation, parser mutation and live socket revocation. The setup suite has ten tests; eight passed on Windows and two POSIX framework link/executable-mode cases run on macOS/Linux. Existing server tests close the direct SQLite connection correctly instead of leaking a Windows file handle.

The final local report load run used 100 distinct authenticated identities and eight concurrent WSGI requests: 100 stored reports, zero failures, zero chat envelopes; elapsed 1.285 s, median 37.246 ms, p95 490.656 ms. This includes JSON/signature/key validation and local SQLite, excludes fixture creation, and excludes real HTTP/TLS, Tor, APNs, devices and production traffic. It is a regression probe, not a throughput/SLA claim.

The new loopback HTTP probe sent 100 encrypted reports with eight concurrent real HTTP connections: 100 stored, zero failures, zero chat envelopes, 1.432 s, median 41.861 ms, p95 551.959 ms. It includes HTTP/WSGI/SQLite and excludes TLS, Tor, APNs, fixtures and production capacity. CI runs both transports. Native cases cover persistent one-view/replay, live-device authority/reordering/restart and fixed private-link publication, plus 256 seeded contact mutations and 128 ciphertext mutations. These are bounded probes, not coverage-guided fuzzing or an audit.

Reproduce:

```bash
python3 -m unittest discover -s server/tests -v
python3 -m unittest discover -s scripts/tests -v
python3 scripts/benchmark_next.py --samples 100 --workers 8
python3 scripts/benchmark_next.py --transport http --samples 100 --workers 8
python3 scripts/generate_project.py --project-only
```

Use the full native preparation/build/test instructions in [IPHONE-BUILD.md](IPHONE-BUILD.md) on macOS. The final work report records later checks and exact commit IDs.

## Remaining P0–P4 work

The follow-up also prevents stopped deliveries at the queue head from starving later eligible messages, persists bounded bot retry state, and rotates polling across up to 32 private mailboxes per synchronization with a persisted cursor. Expired addresses/links are pruned; local address creation is bounded. Low-order X25519 public keys are rejected on normal and private envelope submission without changing valid envelope encoding. These are tested implementation changes; they do not complete the external checks below.

P0: independently review the custom outer/private/report envelopes and protocol composition; exercise power-loss, locked Keychain, full disk, Tor bootstrap/bridge failures, DNS/packet captures and two-device key recovery. Evidence uses the existing static-recipient seal and does not gain Signal forward secrecy. Do not deploy without that tradeoff being reviewed and communicated.

P1: policy-specific retention/export, secure moderator recovery and external bot executor recovery remain. Pagination, ID-prefix search, filters, assignment, independent appeal decisions and bot private invitations are implemented. The native dashboard exists; a separate web moderation console is not provided. False-report handling is manual; quoted authorship is not independently proven. Account sanctions intentionally do not expose identity through account-independent capabilities.

P2: replace/review custom PCM/WSS calling if the product requires a production WebRTC/RingRTC stack; finish provisioned APNs/PushKit/CallKit tests, mobile/Wi-Fi handover and long offline delivery. Live text replication is implemented; full simultaneous secondary sending, attachment/call sync and concurrent conflict resolution remain. No new app-owned background polling entitlement is claimed.

P3: additional isolation UX/recovery, delegated cross-device link revocation, file capability deletion across endpoints and device compromise indicators remain. One-view text and local durable private-link revocation are implemented. Ghost/timer deletion cannot erase recipient copies; older clients ignore the one-view policy. Private Spaces do not prove uncorrelatable network activity.

P4: complete real VoiceOver/Dynamic Type/contrast/interaction reviews, production HTTP/WSS/blob load with RAM/disk/latency budgets, coverage-guided parser/native fuzzing, dependency/native/Tor audit, release signing, operator runbooks, distribution privacy labels, upgrade/rollback drills and independent security review. The manifest now declares pseudonymous IDs, optional push device identifiers, in-app consent/social graph and voluntarily supplied support/text/media/content, linked for app functionality without tracking. It also declares C617.1 for app-owned cache file metadata. This is a source manifest update, not submission to App Store Connect or an audit of every SDK. See [Apple collected-data categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype), [collection purposes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes), and [required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Release gates

1. Pass CI for the exact release candidate, including both native runners, server, dependency audit and Docker checks.
2. Keep persistent relay storage and configure `VO1D_MODERATION_KEY`; establish the intended @vo1d owner/MFA before opening public registration. Restore the DB/secret/identity/authenticator on a staging host.
3. Run real two-device reporting, selected attachment, appeal, token rotation, bot reply, lock/profile switch and network loss scenarios. Verify moderator evidence cannot open unrelated ciphertext.
4. Measure deployed HTTP/WSS/Tor behavior and exercise bounded quota/abuse failure modes; validate operator logging does not capture payloads/tokens.
5. Review protocol choices, licence obligations and actual hosting/APNs/moderation privacy disclosures. Unsigned CI archives and provenance do not provide Apple provisioning or an independent audit.
6. Only after review, sign the app and stage rollout with backups, rollback and observability. This PR neither merges nor deploys production.

Detailed contracts: [MODERATION.md](MODERATION.md), [BOTS.md](BOTS.md), [PRIVATE-LINKS.md](PRIVATE-LINKS.md), [DEVICE-SYNC.md](DEVICE-SYNC.md), [GHOST-TEXT.md](GHOST-TEXT.md), [SECURITY.md](SECURITY.md). The older [ANONYMITY-V2 ledger](ANONYMITY-V2.md) remains historical.
