# VO1D external bot executor

This is a working Node endpoint for separately keyed VO1D bots. It uses the official `@signalapp/libsignal-client` **0.70.0**, matching the iOS SDK pin, and the existing VO1D outer envelope. There is no replacement JavaScript ratchet. The encrypted file is compatible with **BotFather → bot → External executor** in iOS. The relay remains a ciphertext store.

## Start

Install Node 24 and pnpm 11.25.0 on the trusted executor machine. From this repository:

```bash
cd bot-worker
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
```

On iPhone, register and enable the bot, open its External executor screen, explicitly consent to moving this bot's keys, and save the `.vo1dbot` file with a strong password of at least 12 characters. This pauses the native worker before export and changes the server executor epoch. Keep the bot file and password outside the repository. The owner's keys/history are not exported. The file includes this bot's exact outbox, private addresses and serialized libsignal state; unlike an ordinary account backup, it does not reset the ratchet.

Create a protected password file using your trusted editor/password manager. Do not put the password in a command argument, a public environment variable, logs or source control. On Linux/macOS, make the directory private and both files mode `600`, owned by the process user:

```bash
chmod 700 /private/bot
chmod 600 /private/bot/password /private/bot/bot.vo1dbot
VO1D_BOT_PASSWORD_FILE=/private/bot/password node src/cli.mjs --vault /private/bot/bot.vo1dbot
```

The password file contains the exact password and optionally one trailing newline. The vault refuses symlinks, permissive POSIX permissions and oversized files. Windows requires equivalent ACL protection by the operator. A local exclusive lock prevents a second process using the same file; do not remove it while a worker is running. After an unclean exit, confirm that the old process is dead before removing only its `.worker-lock` file.

HTTPS is mandatory. A v3 onion address requires an explicit `VO1D_BOT_SOCKS_PROXY=socks5h://127.0.0.1:9050`; proxy failures never fall back to direct networking. SOCKS5h resolves the relay hostname through the proxy. Separate private requests omit account/bot headers; this is not a guarantee against timing or network correlation. TLS redirects are rejected. Cleartext localhost support exists only in the integration-test driver.

`deploy/vo1d-bot.service` supplies a systemd example for a dedicated user. Adjust its executable and installation paths, set up private state ownership, and install it on your host. The Dockerfile runs as `node`; mount a writable state directory owned by UID 1000 and a mode-600 password file readable by that UID. The container tag is not a reproducible production digest pin. Do not mount an entire personal home directory or account vault.

## Real handlers

By default the worker executes the configured `/start`, `/help` and fixed responses. Set `VO1D_BOT_HANDLER` to the absolute executable of a **trusted program** to implement your own bot behavior. The worker launches that program without a shell and passes one JSON object on stdin:

```json
{"event":{"kind":"message","message":{"text":"/start"}},"sender":{"id":"..."},"bot":{"id":"..."}}
```

The actual event/card objects contain all validated direct-message fields. Return exactly one JSON object on stdout, `{"text":"your reply"}` or `{"text":null}` to suppress a reply. Replies are limited to 4,000 characters, output to 20 KB, and execution to five seconds. Stderr is discarded; worker logs do not contain plaintext, credentials or identifiers. No bot keys, token or password are passed to the handler. The trusted process still has the filesystem/network access granted by its host, so isolate it as needed. Never evaluate message text as a program or shell command. Handler failures retain the packet for retry; handlers must make their own external side effects idempotent using `event.id`/`message.id`.

The endpoint/handler can read messages voluntarily addressed to this bot. E2EE does not conceal a message from its intended bot. Groups, expired/one-view messages, malformed authors and foreign direct rooms do not trigger handlers. Only the bot endpoint decrypts; it receives no human-conversation ratchet keys.

## Persistence and return to iPhone

Each accepted packet commits updated records and the exact encrypted response in one encrypted atomic file before ACK. File writes use exclusive temporary creation, fsync, rename and POSIX directory fsync. Failed persistence does not ACK or mutate committed in-memory state. Retry state is bounded and uses the same ciphertext. The account worker credential is fenced by an owner-selected epoch and a renewable 90-second lease; competing instances are rejected. Private mailboxes intentionally keep their independent capability model, so the worker checks the lease before private polling/sending. These controls do not restrain a malicious holder of copied bot keys/capabilities.

For handback: stop the process, wait for it to exit, copy its **latest updated vault** to iPhone, check the explicit stop/latest-file confirmation, and import it into the same managed bot. iOS replaces the epoch and resumes with the current records; native and external writers must not run together. An old initial export or backup can roll a ratchet back and cannot reconstruct later session state. Server fencing does not attest that a file is the latest; operator stop/copy discipline is required. Token rotation stops the external credential; the owner may still import the latest file and resume using the new locally managed token. Complete key loss requires a new bot identity.

While external execution is active, native fixed-response edits and private-link mutations are paused to avoid editing stale worker state. Existing private invitations/mailboxes from handoff keep working. Return the latest file to iOS to manage those links or native responses; custom handler configuration belongs on its trusted host. Keeping bot command configuration synchronized independently is not implemented.

## Verification and licences

`pnpm test` covers the official PQXDH exchange, serialized record restart, bidirectional ratchet, replay, bindings, normal/private envelopes, password envelopes, lock/save ordering, poison packets, ACK ordering, routing, retry fairness and strict transport. `server/tests/test_external_worker.py` runs real loopback HTTP exchange and restart/dedup against the Python relay. The native CI generates disposable Node fixtures, runs Swift decryption/reply/file export, then checks the Swift output using Node. Test fixture keys are disposable public test data and must never be used for accounts.

Before distributing/hosting SDK-containing software, review [libsignal's AGPL-3.0 licence at the pinned source commit](https://github.com/signalapp/libsignal/blob/efe13e9b363d2c115dba61b76e5e53bbfc2874bc/LICENSE), [socks-proxy-agent's MIT licence](https://github.com/TooTallNate/proxy-agents/blob/main/packages/socks-proxy-agent/LICENSE), and the notices of all locked dependencies. These checks do not independently audit libsignal integration, host security, backup rollback or Tor traffic behavior.
