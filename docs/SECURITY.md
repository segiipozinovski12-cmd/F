# Security model, messages v2 / calls v2

This is a functional, unaudited implementation. New messages use pinned libsignal PQXDH/Double Ratchet; old history remains readable. It provides pseudonymous end-to-end encrypted messaging, not untraceability or zero metadata. See [PROTOCOL-V2.md](PROTOCOL-V2.md), [the 60-item ledger](ANONYMITY-V2.md) and [audit handoff](AUDIT-PACK.md).

## Identity and authentication

Independent Ed25519 signing, X25519 agreement, SDK identity and AES storage keys are generated on device. ID is lowercase SHA-256 of the Ed25519 public key. The signed public-card binding is:

```
VO1D-CARD-1\n{id}\n{signingKeyBase64}\n{agreementKeyBase64}
```

The server refuses key substitution under an existing identity. Message agreement and vault keys use `WhenUnlockedThisDeviceOnly`. The vault is encrypted, file-protected and excluded from ordinary backup. User-exported backups have identity/history/full modes and use PBKDF2-HMAC-SHA256 (600,000 iterations, random 16-byte salt) and AES-GCM. Ratchet sessions, prekeys, outbox, capabilities and delegated authorities are excluded. Passwords are not sent to the relay. Identity import replaces the active profile after confirmation; history import creates a read-only archive. This is not live multi-device synchronization. Independent profiles have separate Keychain/vault namespaces and keys; concurrent background use of all profiles is not implemented.

Authentication uses a single-use 120-second challenge and signature of `VO1D-AUTH-1\n{id}\n{nonce}`, returning a 24-hour bearer token. Only token digests are stored. Revoking sessions does not revoke copied private keys: their holder can authenticate again.

## Message v2 and legacy envelope v1

New peer sessions use official libsignal v0.70.0, pinned at `efe13e9b363d2c115dba61b76e5e53bbfc2874bc`. SDK public identities are bound to the root card by Ed25519 signatures. First contact is TOFU; compare fingerprints over an independent channel. State and exact ready ciphertext commit together before send; retries reuse bytes. SDK decryption uses a disposable state and successful state/event persistence precedes ACK. Once v2 is pinned for a peer, v1 messages from that peer are rejected. An account-based outer envelope still exposes routing IDs.

Private QR invitations distribute independent capability mailboxes and SDK bundles inside a one-use encrypted invitation. Mailbox rows contain capability digests and ciphertext, not sender/account ID. The custom outer ephemeral seal encrypts the SDK packet and sender card. This is not Signal Sealed Sender and has not been reviewed independently. Capability/session separation does not remove timing correlation, connection-level association or operator collusion. Account lookup, bootstrap and calls are separate metadata surfaces.

The following v1 construction is retained for old history/legacy receive, not selected as a fallback for new outgoing messages:

Every recipient gets a fresh sender-ephemeral X25519 key and 32-byte salt. Ephemeral-sender/static-recipient ECDH and HKDF-SHA256 produce the AES-GCM key. HKDF context and authenticated header are:

```
VO1D-ENVELOPE-1\n{id}\n{sender}\n{recipient}\n{ephemeralKeyBase64}\n{saltBase64}\n{expiresAtIntegerUnixSeconds}
```

Ed25519 signs `header || LF || combinedCiphertext`. Both relay and receiver validate signatures. Recipient agreement-key compromise can reveal recorded ciphertext: this protocol has no message forward secrecy, prekeys or post-compromise security. Random payload padding is not traffic-analysis resistance.

Room drafts, local aliases, notes, unread counters, archives and other local UI settings are stripped from transmitted room payloads. Message and group events are encrypted per recipient, with author, membership and administrative checks on receipt. Group changes do not re-encrypt historical messages. Unknown-contact events and group invitations are quarantined locally until accepted; attachments and receipts are withheld during this stage.

A private roster is supported only in a channel with the creator as the sole administrator and publisher. Subscribers receive owner + own card. Existing historical roster disclosures cannot be undone. Ordinary groups still expose membership. V2 groups use pairwise libsignal fanout (maximum 16 participants), authenticated membership epochs and cancellation of old-membership queued messages. They are not MLS groups. Scoped group/contact profiles offer separate identities only when explicitly chosen. Private poll participants receive counts, while the poll creator receives and stores individual votes; this is not anonymity from the creator. Research decisions are recorded separately.

## Calls v2

Each call generates a fresh X25519 key. Offers are signed over:

```
VO1D-CALL-KEY-2\n{callID}\n{fromID}\n{toID}\n{ephemeralKeyBase64}
```

Peers verify signed public cards and offers. ECDH/HKDF derives a call key with a call-ID hash salt and canonical identity context. AES-GCM audio associated data binds call ID, sending identity, receiving identity and sequence. Replay counters advance only after authentic decryption; duplicate frames and reflected own audio are rejected. Keys are discarded on call end. Reconnect retains the established key and counters, uses authenticated resume markers and expires locally after 20 seconds. No direct peer sockets are used. This custom PCM/WSS construction has not been independently audited; RingRTC/WebRTC is not integrated. The relay knows call routing IDs.

When the user enables background calls and notifications, a separate Keychain descriptor stores a delegated calls-only signing authority, root-signed certificate, public card, allowed peers and transport configuration as `AfterFirstUnlockThisDeviceOnly`. It never stores the root signing, message agreement or vault key. The server checks certificate scope/expiry and restricts the resulting token to call WSS; account HTTP operations reject it. This deliberately makes limited call signing authority available on a locked device after first unlock and expands the local trust boundary. Disable background calls to remove the descriptor. PushKit immediately reports the call to CallKit before network work. Physical-device correctness still needs testing with actual provisioning and APNs credentials.

## Delivery and retention

Ciphertext envelopes persist before transmission. Deduplication retains tombstones until expiry even after ACK. Retention is bounded to seven days or shorter message expiry. Background maintenance runs every 30 seconds, clearing expired records, blobs and inactive accounts. Logical removal does not guarantee physical erasure of SQLite pages, WAL, host snapshots or backups.

Private v2 blobs use independent random upload/read/delete capabilities without account authentication and expire within seven days. Legacy v1 blobs still require account authentication. Server storage contains ciphertext and capability digests. HTTP Range reads retain an authorized fd for an in-flight response; deletion blocks future authorization but cannot retract bytes already read. Quota reservation and atomic finalization prevent concurrent upload/delete resurrection. Ciphertext checkpoints on device are file-protected; plaintext is released only after digest/size and AES-GCM verification. Clearing local inline attachments without another copy is irreversible. Owned preview/transient directories are protected and cleaned on startup, dismissal/background; OS copies and physical flash erasure are not guaranteed.

APNs alert payloads are neutral and contain no sender, message text or room title. VoIP payloads contain an event token rather than caller ID; callers are resolved through authenticated signalling. Apple sees device tokens and push metadata; operators also store tokens. Disabling notifications removes registrations on the current relay. Private account-independent mailboxes do not automatically generate account push and are collected while the app can run. Delivery is best effort and requires operator credentials. Local quiet hours do not suppress server APNs. Opaque account inbox control events may trigger neutral push.

Account inactivity is measured from authenticated activity, including background network activity. Local inactivity cleanup runs only on next app activation. Timers, deletion and edits cannot erase screenshots or plaintext copies on other clients. Scheduled messages require the app to synchronize at or after the chosen time.

## Network and device boundaries

TLS is mandatory outside Debug loopback, except strict v3 onion origins selected with a Tor route. Embedded pinned Tor is available, with a protected data directory, bootstrap gate and no direct fallback. External SOCKS5 is optional. App-owned URLSession HTTP, blobs and WSS use failover=false and block redirects; capability operations have distinct session/auth scopes. APNs, external browsers and other applications are outside this route. Runtime DNS/packet capture on physical devices remains outstanding; a configured proxy is not proof of no leaks. Relays see timing, size buckets and direct or proxy-origin IP; account/call paths also see routing IDs. Stable public identities link conversations. Four-character public codes remain enumerable despite lookup limits; sensitive users should disable discovery and use private one-use invitations.

Authentication rate buckets use an in-memory random HMAC salt. Forwarded addresses are accepted only from explicitly configured `VO1D_TRUSTED_PROXIES` CIDRs, parsed from the right to the first untrusted hop. Without that setting clients behind Caddy share its bucket. Do not trust arbitrary forwarded headers or universal CIDRs. Capability attempts are bounded before authorization, with capability-specific limits after validation; random invalid tokens cannot create arbitrary per-token buckets. Open registration, proof-of-work, blocking and quotas do not prevent Sybil abuse or traffic correlation.

## Device history links

An independent second identity can receive a root-signed, audience-bound history certificate after both contacts are verified and explicitly approved. Certificate expiry, scope and revocation tombstones are checked; queued transfers are cancelled on revoke. Each device has its own message keys. Current transfer is manual, at most 200 text/poll messages, into a read-only archive, with no attachments or drafts. It is not automatic synchronization of all future chats and does not duplicate an account's ratchet state.

Photo re-rendering removes original EXIF; redaction needs user review, and blur can leave recognizable context. PDF/Office warnings are not complete metadata sanitization. OCR and link cards run locally. External links can reveal IP through the browser; tracking cleanup covers known parameters only. Clipboard expiry and screen-recording curtains reduce incidental disclosure, but do not prevent screenshots, malicious keyboards, device compromise or recipient copying.

Review App Store privacy disclosures against actual hosting and APNs operation. No independent security audit, signed physical distribution, or production rollout is included in this branch.
