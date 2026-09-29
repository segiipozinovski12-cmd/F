# Security model / protocol v1

This is a functional, unaudited first version. Do not market it as untraceable, zero metadata, Signal-equivalent or suitable for high-risk communications.

## Identity

A device generates independent Ed25519 signing, X25519 agreement and AES storage keys. The identity is lowercase SHA-256 of the raw 32-byte Ed25519 public key. The agreement key is bound by an Ed25519 signature over UTF-8:

```
VO1D-CARD-1\n{id}\n{signingKeyBase64}\n{agreementKeyBase64}
```

No key replacement is allowed under an existing identity. Keys are stored in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; the encrypted application vault is file-protected and excluded from backup. There is no recovery, device sync or key export in v1. A reinstall may preserve Keychain entries, depending on iOS behavior, but is not a recovery strategy.

## Server authentication

Register a signed public card, get a single-use, 120-second random challenge, sign `VO1D-AUTH-1\n{id}\n{nonce}` and receive a 24-hour random bearer token. Only the SHA-256 token digest is stored in SQLite. Authentication challenges are consumed atomically. Request bodies, authorization headers and message content are not logged by the app. Infrastructure outside this source can still retain logs.

## Envelope

A fresh X25519 ephemeral key and random 32-byte salt are generated for every recipient of every event. The HKDF-SHA256 context and AES-GCM associated data are the same canonical UTF-8 header:

```
VO1D-ENVELOPE-1\n{id}\n{sender}\n{recipient}\n{ephemeralKeyBase64}\n{saltBase64}\n{expiresAtIntegerUnixSeconds}
```

ECDH is ephemeral-sender to static-recipient. HKDF produces a 32-byte AES key. CryptoKit combined ciphertext is `12-byte nonce || ciphertext || 16-byte tag`. Ed25519 signs `header || LF || combinedCiphertext`. The relay checks the signature without learning plaintext. The receiver also validates the sender's public card, envelope signature, destination, expiry, room membership and event author before applying an event.

Names, group title/membership, message text, attachments, reactions, edits and receipts are encrypted event payloads. Groups fan out independently to each member. Fixed membership avoids silently sharing historical keys with a newly added member. To change members, create another group. Fingerprints must be compared out of band to connect a cryptographic identity to an actual person.

## Delivery

Foreground polling every two seconds; no APNs token collection. Outgoing envelopes persist before transmission. Server deduplication uses `(envelope ID, recipient)` plus a digest, retaining tombstones until expiry even after acknowledgement. Received content and receipts are saved before ACK. Offline relay retention is at most seven days, or less for disappearing messages. Expired rows are purged during API requests. A low-traffic installation should call `/v1/inbox` normally or add its own maintenance job if requiring wall-clock deletion while entirely idle. SQLite free pages, WAL, system snapshots and backups complicate physical erasure.

## Explicit boundaries

- No Double Ratchet, recipient one-time prekeys, post-compromise security, multi-device or audited protocol implementation. Obtaining a recipient's long-term agreement key can expose previously captured ciphertext.
- TLS is mandatory outside Debug loopback. The server sees IP, identity routing, ciphertext sizes and timings. No Tor transport, cover traffic, padding or traffic-analysis resistance.
- Account registration is open, with rate limits and per-mailbox quotas, not a comprehensive anti-abuse system. First contact from an unknown but valid identity is accepted. Add moderation/abuse policies before a public service.
- Blocking a person cannot stop them creating a new identity. Fixed groups containing a blocked member need to be replaced.
- Timers start on send. Remote delete/edit are delivery events, not guaranteed erasure. Offline recipients can retain plaintext; malicious clients can ignore expiration.
- Event order follows relay enqueue order; v1 is not a distributed CRDT and provides no consensus across devices.
- Photos are re-rendered to JPEG without original EXIF. Arbitrary documents may contain personal metadata. Exporting a preview creates a protected temporary decrypted file, removed when preview closes or the app backgrounds.
- Device compromise, screen recording, keyboard extensions, copied content and recipient behavior are outside the encryption boundary.
- TLS proxy deployment currently rates authentication by its immediate socket peer. Behind the supplied Caddy this is a conservative shared limit. For larger deployments add trusted-proxy aware rate limiting; never trust arbitrary forwarded headers.
- `PrivacyInfo.xcprivacy` is not a substitute for operator-specific App Store disclosures. Review it against actual hosting, diagnostics, data handling and Apple's current requirements before distribution.

Reference API documentation: [CryptoKit](https://developer.apple.com/documentation/cryptokit), [Curve25519](https://developer.apple.com/documentation/cryptokit/curve25519), [AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm).
