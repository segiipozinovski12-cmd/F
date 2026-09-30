# Security model, messages v1 / calls v2

This is a functional, unaudited implementation. It provides pseudonymous end-to-end encrypted messaging, not untraceability or zero metadata. Double Ratchet is still absent; see PROTOCOL-V2.md.

## Identity and authentication

Independent Ed25519 signing, X25519 agreement and AES storage keys are generated on device. ID is lowercase SHA-256 of the Ed25519 public key. The signed public-card binding is:

```
VO1D-CARD-1\n{id}\n{signingKeyBase64}\n{agreementKeyBase64}
```

The server refuses key substitution under an existing identity. Message agreement and vault keys use `WhenUnlockedThisDeviceOnly`. The vault is encrypted, file-protected and excluded from ordinary backup. User-exported backups contain all identity keys and history, encrypted with PBKDF2-HMAC-SHA256 (600,000 iterations, random 16-byte salt) and AES-GCM. Passwords are not sent to the relay. Import replaces local identity after confirmation; it is not live multi-device synchronization.

Authentication uses a single-use 120-second challenge and signature of `VO1D-AUTH-1\n{id}\n{nonce}`, returning a 24-hour bearer token. Only token digests are stored. Revoking sessions does not revoke copied private keys: their holder can authenticate again.

## Message envelope v1

Every recipient gets a fresh sender-ephemeral X25519 key and 32-byte salt. Ephemeral-sender/static-recipient ECDH and HKDF-SHA256 produce the AES-GCM key. HKDF context and authenticated header are:

```
VO1D-ENVELOPE-1\n{id}\n{sender}\n{recipient}\n{ephemeralKeyBase64}\n{saltBase64}\n{expiresAtIntegerUnixSeconds}
```

Ed25519 signs `header || LF || combinedCiphertext`. Both relay and receiver validate signatures. Recipient agreement-key compromise can reveal recorded ciphertext: this protocol has no message forward secrecy, prekeys or post-compromise security. Random payload padding is not traffic-analysis resistance.

Room drafts, local aliases, notes, unread counters, archives and other local UI settings are stripped from transmitted room payloads. Message and group events are encrypted per recipient, with author, membership and administrative checks on receipt. Group changes do not re-encrypt historical messages. Unknown-contact events and group invitations are quarantined locally until accepted; attachments and receipts are withheld during this stage.

A private roster is supported only in a channel with the creator as the sole administrator and publisher. Subscribers receive owner + own card. Existing historical roster disclosures cannot be undone. Ordinary groups still expose membership. Private poll participants receive counts, while the poll creator receives and stores individual votes; this is not anonymity from the creator.

## Calls v2

Each call generates a fresh X25519 key. Offers are signed over:

```
VO1D-CALL-KEY-2\n{callID}\n{fromID}\n{toID}\n{ephemeralKeyBase64}
```

Peers verify signed public cards and offers. ECDH/HKDF derives a call key with a call-ID hash salt and canonical identity context. AES-GCM audio associated data binds call ID, sending identity, receiving identity and sequence. Replay counters advance only after authentic decryption; duplicate frames and reflected own audio are rejected. Keys are discarded on call end. This custom construction has not been independently audited; messages retain v1.

When the user enables background calls and notifications, a separate Keychain descriptor stores signing authority, public card, allowed peers and transport configuration as `AfterFirstUnlockThisDeviceOnly`. It never stores the message agreement or vault key. This deliberately makes signing authority available on a locked device after first unlock and expands the local trust boundary. Disable background calls to remove this descriptor. PushKit immediately reports the call to CallKit before network work. Physical-device correctness still needs testing with actual provisioning and APNs credentials.

## Delivery and retention

Ciphertext envelopes persist before transmission. Deduplication retains tombstones until expiry even after ACK. Retention is bounded to seven days or shorter message expiry. Background maintenance runs every 30 seconds, clearing expired records, blobs and inactive accounts. Logical removal does not guarantee physical erasure of SQLite pages, WAL, host snapshots or backups.

Blobs are opaque random bearer capabilities, require an authenticated session to download, support HTTP Range, expire within seven days, and have owner-only deletion. Ciphertext checkpoints on device are file-protected; plaintext is released only after digest/size and AES-GCM verification. Clearing local inline attachments without another copy is irreversible. Temporary decrypted previews are cleaned when dismissed/backgrounded, subject to OS crash behavior.

APNs alert payloads are neutral and contain no sender, message text or room title. VoIP payloads contain call ID and caller pseudonymous ID. Apple sees device tokens and push metadata; operators also store tokens. Disabling notifications removes registrations on the current relay. Delivery is best effort and requires operator credentials. Local quiet hours do not suppress server APNs. Because mailbox contents are opaque, neutral push may also accompany control events.

Account inactivity is measured from authenticated activity, including background network activity. Local inactivity cleanup runs only on next app activation. Timers, deletion and edits cannot erase screenshots or plaintext copies on other clients. Scheduled messages require the app to synchronize at or after the chosen time.

## Network and device boundaries

TLS is mandatory outside Debug loopback. SOCKS5 applies to URLSession HTTP, blobs and WSS with failover disabled; a working external proxy or Tor is required. It does not cover APNs, external browsers or other applications. Relay still sees identity routing, timing and sizes, plus the direct or proxy-exit IP. Stable public identities link conversations. Four-character public codes remain enumerable despite lookup limits; sensitive users should disable discovery and use one-use invitations.

Authentication rate buckets use an in-memory random HMAC salt for socket-peer IPs. Behind Caddy the immediate proxy address shares limits. Do not trust arbitrary forwarded headers; add trusted-proxy-aware infrastructure limits for larger deployment. Open registration, blocking and quotas do not prevent Sybil abuse.

Photo re-rendering removes original EXIF; redaction needs user review, and blur can leave recognizable context. PDF/Office warnings are not complete metadata sanitization. OCR and link cards run locally. External links can reveal IP through the browser; tracking cleanup covers known parameters only. Clipboard expiry and screen-recording curtains reduce incidental disclosure, but do not prevent screenshots, malicious keyboards, device compromise or recipient copying.

Review App Store privacy disclosures against actual hosting and APNs operation. No independent security audit, signed physical distribution, or production rollout is included in this branch.
