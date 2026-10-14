# @vo1d_bot_father and real E2EE bots

BotFather is the native management service in Settings and Contacts, also reachable by entering `@vo1d_bot_father` in Add Contact. That service username is reserved. It creates registered, separately keyed bots rather than synthetic network identities or server-side plaintext chat readers.

Each bot has an independent Ed25519/X25519 identity, libsignal state, Keychain namespace, encrypted vault and username ending `_bot`. The owner can create up to 20 bots, set up to 32 command responses, start/stop the worker, rotate its credential or delete it. Bot usernames share the normal uniqueness registry; other identities cannot take an occupied name.

## Native executor

The owner device publishes real signed PQXDH prekeys, receives bot-addressed ciphertext, decrypts it with libsignal, validates the direct room and message author, and encrypts replies with libsignal. `/start`, `/help` and configured commands produce real outgoing messages. Incoming groups and forged message authors do not cause responses. The SDK state and exact response ciphertext are persisted together before network transmission or acknowledgment; retries reuse the same bytes. Replies preserve an incoming message expiry.

Workers execute while the owner's active profile can run in the foreground. They are scheduled after ordinary inbox/outbox work, in bounded rotating batches. They stop on profile change, cancellation, lock, disabled state or credential changes. Only the active profile's bots run. This does not provide 24/7 hosting, arbitrary server-side scripts, a Telegram protocol bridge or live multi-device synchronization.

Bots are labelled in contact details. A bot owner/executor can read messages voluntarily addressed to that bot; E2EE does not conceal those messages from the bot endpoint. The relay knows bot registration/owner association and ordinary bootstrap routing. A bot receives no key for unrelated human conversations.

The current built-in worker bootstraps through the account inbox and can send replies through a supplied private return capability. It does not issue its own one-use private invitation or provide complete account-independent private bot discovery. A profile requiring private delivery may need that future integration; it must not silently fall back to account delivery.

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

Bot identities cannot manage other bots or rename/release their username through the ordinary account API. Changing a registered bot's agreement key requires an explicit migration. Permanent @vo1d cannot be converted into a bot.

## External workers

Use `Authorization: BotCapability {token}` for the narrow worker credential. It permits only own encrypted inbox/ACK/send, signed prekey publication/inventory/claim and public-card lookup. It cannot use owner management, moderation, account deletion, push, blobs or calls. Sending another identity's envelope fails. Disabled/deleted bots and revoked credentials fail authentication; owner sanctions also block these workers.

A credential alone cannot decrypt messages or forge signatures. An external executor additionally needs bot-owned private keys and durable libsignal state, and must implement this repository's [message protocol](PROTOCOL-V2.md) with the pinned official SDK. The Swift `NativeBotWorker` is a working reference for state/ciphertext/ACK ordering. No unaudited Python ratchet substitute or plaintext Bot API is provided.

Hosting/handoff for an external executor, encrypted bot-key recovery, arbitrary handlers and private bot invitation issuance remain release follow-up work. Do not copy one ratchet snapshot to simultaneously active workers. The owner's ordinary identity/history export intentionally excludes bot credentials and bot ratchet state; losing the separate bot keys can require deleting the bot and creating a new identity. Token rotation is durable/retryable after a lost response.

Deleting a bot cannot erase messages already copied by users. Its username may be claimed by a new key identity; compare full fingerprints and do not treat name reuse as key continuity. Owner account deletion also revokes/removes its registered bots. Back up the operator database to preserve permanent admin ownership independently of bot lifecycle.
