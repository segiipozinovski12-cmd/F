# @vo1d_bot_father and real E2EE bots

BotFather is the native management service in Settings and Contacts, also reachable by entering `@vo1d_bot_father` in Add Contact. That service username is reserved. It creates registered, separately keyed bots rather than synthetic network identities or server-side plaintext chat readers.

Each bot has an independent Ed25519/X25519 identity, libsignal state, Keychain namespace, encrypted vault and username ending `_bot`. The owner can create up to 20 bots, set up to 32 command responses, start/stop the worker, rotate its credential or delete it. Bot usernames share the normal uniqueness registry; other identities cannot take an occupied name.

## Native executor

The owner device publishes real signed PQXDH prekeys, receives bot-addressed ciphertext, decrypts it with libsignal, validates the direct room and message author, and encrypts replies with libsignal. `/start`, `/help` and configured commands produce real outgoing messages. Incoming groups and forged message authors do not cause responses. The SDK state and exact response ciphertext are persisted together before network transmission or acknowledgment; retries reuse the same bytes. Replies preserve an incoming message expiry.

Native workers execute while the owner's active profile can run in the foreground. They are scheduled after ordinary inbox/outbox work, in bounded rotating batches. They stop on profile change, cancellation, lock, disabled state, credential changes or handoff to the external worker. Only the active profile's native bots run. [The external Node executor](../bot-worker/README.md) supplies separately hosted operation and trusted executable handlers; this repository does not provide hosting or a Telegram protocol bridge.

Bots are labelled in contact details. A bot owner/executor can read messages voluntarily addressed to that bot; E2EE does not conceal those messages from the bot endpoint. The relay knows bot registration/owner association and ordinary bootstrap routing. A bot receives no key for unrelated human conversations.

The native worker bootstraps through the account inbox, also issues durable one-use private invitations, polls its own independent mailboxes and sends replies through a supplied private return capability. The external executor imports existing bot addresses/invitations and preserves this private exchange. Private link management remains on iOS and is paused during external execution to avoid editing stale worker records. Strict private delivery never silently falls back to account routing.

## Owner API

`POST /v2/bots` accepts a signed bot card, name, username, a client-generated 43-character base64url credential and an ownership signature made by the bot key:

```text
VO1D-BOT-CREATE-1
{ownerID}
{botID}
{username}
{name}
{SHA256(token)}
```

The authenticated owner and this proof prevent registering somebody else's public card as one's bot. Idempotent retries preserve the same credential. The server stores only its digest.

| Endpoint | Access |
| --- | --- |
| `GET /v2/bots` | List caller-owned bot metadata, never credentials |
| `GET /v2/bots/directory/{id}` | Public bot flag/name/command names for authenticated clients |
| `POST /v2/bots/{id}/settings` | Owner: enabled state and command names |
| `POST /v2/bots/{id}/token` | Owner: replace credential; old one stops working |
| `DELETE /v2/bots/{id}` | Owner: revoke bot and remove relay account data |
| `POST /v2/bots/{id}/executor` | Owner: select native/external epoch; fence earlier worker requests |
| `POST /v2/bots/worker/lease` | Scoped bot credential: claim/renew one 90-second process lease |

Bot identities cannot manage other bots or rename/release their username through the ordinary account API. Changing a registered bot's agreement key requires an explicit migration. Permanent @vo1d cannot be converted into a bot.

## External workers

Use `Authorization: BotCapability {token}` for the narrow worker credential. It permits only own encrypted inbox/ACK/send, signed prekey publication/inventory/claim and public-card lookup. It cannot use owner management, moderation, account deletion, push, blobs or calls. Sending another identity's envelope fails. Disabled/deleted bots and revoked credentials fail authentication; owner sanctions also block these workers.

A credential alone cannot decrypt messages or forge signatures. The external executor uses bot-owned private keys and durable libsignal state exported with explicit consent from iOS. Both Swift and Node use the pinned official SDK and [message protocol](PROTOCOL-V2.md); cross-SDK CI validates records, bidirectional replies and encrypted worker files. No Python ratchet substitute or relay-side plaintext Bot API is provided.

The external worker is runnable with Node, Docker or the supplied systemd example. The operator provisions the host. Handoff uses `VO1D-BOT-WORKER-1`, PBKDF2-HMAC-SHA256 (600,000 iterations, salt 16 bytes), AES-GCM and domain-associated data. Only bot keys/state/queue/capabilities are included. The native worker pauses before export. Return requires stopping the process and importing its latest file; an initial export cannot reconstruct later ratchet state. Local locks and fenced renewable leases reject competing honest processes but do not constrain a malicious key/capability holder or prove snapshot freshness.

Do not copy one ratchet snapshot to simultaneously active workers. The owner's ordinary identity/history export intentionally excludes bot credentials and bot ratchet state. Complete loss of the separate bot keys still requires creating a new identity; retained initial exports do not promise transparent recovery of ongoing sessions. Token rotation is durable/retryable after a lost response and stops the external credential. Native command response edits are paused while external execution is active; custom programs own their behavior/configuration on their trusted host. See [the complete start/stop/recovery runbook](../bot-worker/README.md).

Deleting a bot cannot erase messages already copied by users. Its username may be claimed by a new key identity; compare full fingerprints and do not treat name reuse as key continuity. Owner account deletion also revokes/removes its registered bots. Back up the operator database to preserve permanent admin ownership independently of bot lifecycle.
