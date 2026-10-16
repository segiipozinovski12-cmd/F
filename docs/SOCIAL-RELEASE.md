# VO1D social / reliability update

This is source work on `codex/vo1d-next`. Production deployment, billing credentials,
Apple signing and physical two-phone checks are separate operations. Do not describe
this branch as independently audited or universally anonymous.

## Reliability and UX

* Four-character `@name` searches go to username discovery. Bare four-character
  values try compact ID, then username only on 400/404. Network errors do not
  silently change the lookup type.
* Searchable compact IDs are allocated by the relay; the app no longer invents a
  local four-character ID. Prekeys are published before onboarding completes.
  Missing recipient prekeys remain retryable rather than permanently stopping delivery.
* Reconnection reads server discovery and restores a saved username when available;
  a conflicting claim is surfaced without blocking local history. A persistent
  `/data` volume and the same relay origin on both phones remain necessary.
* Groups and channels can start with just the creator. Invitations remain opt-in;
  the receiver sees a message request until acceptance. Creation triggers a queue flush.
* Foreground wakes retain healthy call sockets. Outgoing calls request microphone
  permission and wait for WSS readiness; pushed answers re-read the resolved peer ID.
  Failures report offline/busy/consent details instead of silently closing the UI.
* Sending/reactions trigger immediate synchronization. Outbox processing precedes
  private-inbox polling, report delivery and bot work; ciphertext is still saved before send.
* The archive filter chip is removed. Pull down to reveal the archive row; pull
  again hides it. Context actions still move conversations in/out of the archive.
* Settings → My Profile previews the shared card. A chat menu opens the other
  profile. There are 32 reactions with reversible selection and animated updates;
  unlock/chat/archive transitions are animated, with reduced-motion handling on entry.

## Profiles and stories

Name/bio/avatar/status are transmitted only as Signal-encrypted control events to
trusted contacts. Profiles are not a public server directory. Opening another profile
requests an update, and saving your profile shares an update with trusted contacts.
Avatars are re-encoded and bounded to 160 KB. Username ownership remains in the
server discovery API; a display name is not an administrator credential.

Stories have a text/photo composer and an explicit per-story audience. Photo JPEGs
are re-encoded without original EXIF and limited to 400 KB. Five simultaneous own
stories are available without Premium, 30 with Premium. Both event and transport
expiry are at most 24 hours. Received stories validate author, UUID, size, expiry,
trusted contact and local profile scope. Deletion fans out to the saved original
audience; bounded tombstones prevent delete-before-delivery resurrection. Stories
are pruned on expiration and excluded from backup exports. Recipient copies,
screenshots and host backups cannot be erased remotely.

## Cryptography

New live messages, including initial contact packets, require the existing official
libsignal PQXDH/Double Ratchet. Legacy local history remains readable; unauthenticated
migration to the older live format is rejected. Calls use signed v3 ephemeral-X25519
handshakes with AES-256-GCM and replay checks. Direction/4096-frame epoch key derivation
separates traffic keys. Both phones need the new client for v3 calls. This is not
post-quantum calling or a continuously forward-secret call ratchet. Malformed audio
frames are discarded without taking down the receive loop. No numerical security
multiplier is claimed.

## Nearby without internet

Settings → Nearby uses Apple's Multipeer Connectivity over local Wi-Fi/Bluetooth,
with encryption required and a fresh random advertised device label. Both users
explicitly enable it and confirm the device connection. A random challenge signed
by the stored contact key authenticates the peer; only verified trusted contacts
are accepted. Existing Signal sessions are required: first-key exchange remains
online/private QR. The exact encrypted envelope is saved before transmission;
a recipient-signed ACK removes it only after the receiving vault has committed it.
Retries preserve ciphertext and message IDs. Nearby stops on background, lock,
identity reset or profile switch. No routing through unknown phones is implemented.

This is proximity delivery, not a global network without internet. Radio neighbors
can observe local presence; an accepted device receives your public key. Blob
references already uploaded to the relay need network access for downloading.
Physical distance, radio throughput and two-phone foreground operation require QA.

## Premium and collectibles

Real entitlement code is implemented; a billing provider is **not** connected.
Premium supplies 30 stories vs 5, 60 folders vs 20, and a signed profile badge/status.
Core encryption/Tor/calls/reactions stay free. Collectibles are signed VO1D
certificates shown in the profile, **not blockchain NFTs**.

On the relay host set `VO1D_COMMERCE_SIGNING_KEY` to a secret base64 Ed25519 32-byte
private key. Set its matching public key as `VO1D_COMMERCE_PUBLIC_KEY` when generating
the Xcode project. Never commit the private key. The generator preserves a previously
configured public pin. The app accepts only receipts signed by that pinned issuer
and bound to its identity. Missing pin fails closed. Single-use voucher redemption
is transactional, race-tested and idempotent; receipt history is account-scoped.

After independently verifying a payment, an operator can issue a voucher on the host:

```bash
python3 scripts/issue_voucher.py --db /data/relay.sqlite3 --owner USER_ID --days 30
python3 scripts/issue_voucher.py --db /data/relay.sqlite3 --kind collectible --label 'VOID #1' --symbol diamond.fill --owner USER_ID
```

No fake checkout, transaction hash or blockchain explorer proof is generated.
A real provider/chain contract, settlement verification, refund/revocation policy,
receipt recovery, legal/store distribution requirements and country availability
remain work. A blockchain transaction is not proof of communication anonymity.
Configured Tor/SOCKS routing remains the app's transport; external browser checkout
would not inherit it and therefore is not presented as anonymous in this update.

## Operator reset — not executed against production

The available environment has source/GitHub access, not a running Railway database
or deployment credentials. `scripts/reset_accounts.py` prepares the requested reset
without exposing a remote unauthenticated wipe endpoint. In a host checkout, stop
the relay first, then run:

```bash
python3 scripts/reset_accounts.py --db /data/relay.sqlite3
python3 scripts/reset_accounts.py --db /data/relay.sqlite3 --blob-dir /data/blobs --backup /data/reset-backup-UNIQUE --server-stopped --confirm DELETE-ALL-ACCOUNTS
```

The first command is a read-only preview. The second verifies a private SQLite backup,
moves blobs into that backup, replaces the database and clears old account/session/
username/moderator records. Requires Python 3.12 and a same-filesystem blob backup.
The first subsequent **signature-authenticated session**, not a bare public card
registration, atomically receives permanent `@vo1d` ownership. Other first-login
contenders cannot claim the same role. Control registration/network exposure until
the intended owner has claimed it, then configure MFA. Old device vaults and backups
are not remotely erased; reset/re-register the clients as needed. Retain the backup
for rollback and dispose of it separately when appropriate.

Railway must deploy this branch from `/server` with persistent `/data`. Merely
building the iPhone client neither upgrades that server nor resets accounts.
