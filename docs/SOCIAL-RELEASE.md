# VO1D NEXT · free interface and privacy update

Branch: `codex/vo1d-next`. Build on a Mac with `bash scripts/open_iphone.sh`.
The script prepares the pinned SDK and opens Xcode; choose a signing Team and an
attached iPhone, then Run. Release signing/distribution remains the owner's step.

## Current interface

Premium, voucher redemption, signed collectible UI, profile previews and profile
request controls have been removed. All accounts have 30 simultaneous stories and
60 folders. Old entitlement JSON fields are ignored when opening the vault; retired
server records are retained and scrubbed if their owner deletes the account.
There is no issuer, checkout, blockchain transaction or subscription endpoint.

Onboarding asks for a display name. A searchable username is optional in Settings;
a display name is not a username. Everyday mode enables discovery without changing
an already selected Tor/SOCKS route. Both onboarding and connection settings show
explicit tradeoffs for private delivery/Tor, including disabled search, invitation
requirements, background limitations, latency and metadata exposure.

Settings → Appearance offers five dark app palettes, a default chat palette,
per-conversation overrides, optional static texture, text size and compact rows.
Choices live in each identity's encrypted vault and are not sent to peers.
Actions use rounded controls, press feedback and smooth layout transitions. New
chat rows and unlock content fade in; reply/edit/selection/recording transitions
animate. Reduce Motion disables movement. Sensitive content hides immediately on
lock rather than waiting for an exit animation.

Story creation is in the top header, with live story circles directly beneath it.
Story viewing opens stories only. Stories use explicit trusted-contact audiences,
Signal encryption, at most 24-hour transport/content expiry, size/queue quotas,
original-audience deletion and bounded tombstones. They are excluded from backups.
Recipients may save copies; remote deletion cannot remove those copies.

32 reactions use a scrollable picker, grouped emoji/count chips, reversible
selection, and a visible on-message burst when reactions change. Effects do not
replay simply because a historical message scrolls into view. Motion and particle
work only occurs for a new change; there is no continuous reaction timer.

Archive is revealed by pulling down, with animated entry and exit. Existing solo
group/channel creation and explicit incoming-call microphone handling remain.

## Security fixes in this update

* A delayed username, contact lookup, privacy update or avatar import is fenced to
  the identity and transport generation that initiated it. Contact-request rollback
  no longer spans a network wait or overwrites a subsequently opened identity.
* Privacy/trust sync snapshots the original account's list before sending and
  aborts after a switch; it cannot send the next identity's contacts to the old API.
* Legacy profile requests no longer cause automatic metadata replies. Editing
  local details no longer broadcasts a profile update to every trusted contact.
* Nearby discovery/invitation callbacks from an old browser/advertiser are fenced
  after stop or identity switch, in addition to existing session packet fencing.
* Foreground account synchronization waits for local access/biometric gates.
  Separately opted-in delegated background calls retain their explicit policy.
* The local access field masks typed characters. Lock and capture curtains stay
  immediate, even when general UI transitions are enabled.
* Avatar/story imports use bounded ImageIO thumbnails instead of rendering a full
  decompressed source. Original image metadata is not forwarded in the JPEG.
  Attachment filename anonymization uses the existing bounded extension policy.

Official libsignal PQXDH/Double Ratchet remains the message protocol. Existing call
v3 handshakes use signed ephemeral X25519, directional AES-256-GCM keys and replay
checks. Calls are not post-quantum and do not have a continuously advancing call
ratchet. This update is not an independent cryptographic audit or evidence of
superiority over Signal or Session. A relay can still correlate account/bootstrap,
call peers and timings; Tor does not make a compromised phone safe or eliminate
traffic analysis. External browsers and APNs use their own platform networking.

## Connectivity

Loss of connectivity automatically keeps the durable encrypted queue and suppresses
repeated connection attempts. Network return wakes transient retries immediately,
without bypassing permanent failures, scheduled times or privacy batch delays.
It uses the selected route; Tor failure never enables direct fallback.

Opt-in Nearby delivery uses Multipeer Connectivity and requires verified trusted
contacts, a fresh signed challenge, an existing Signal session and required local
transport encryption. Signed acknowledgments remove saved ciphertext only after a
receiver commit. Nearby-only packets cannot escape through the account relay.
Nearby stops on lock, background and identity switch. Uploaded blob references
still require network access. No unknown-device mesh routing is implemented.

Communication across 1000 km requires a real carrier/relay/network path. Queueing
cannot create such a path. Nearby does not secretly enable radios, override iOS
permissions, or broadcast a public account identity without local opt-in.

## Permanent administrator

Login/registration never automatically assigns a username. The first authenticated
explicit claim of `@vo1d` owns it permanently. Concurrent claims have one winner;
rename/account deletion cannot transfer ownership. Existing permanent ownership is
preserved by this update, including any owner assigned by the earlier rollout.
Owner powers remain protected by MFA. The production service was missing the
persistent MFA-encryption key; it has now been configured in Railway environment
variables and takes effect at the next deployment. It is not stored in the repo.

## Prior account reset: do not repeat

The earlier user-authorized reset completed on 2026-10-16 at 22:24 UTC:
`accountReset=vo1d-user-request-20261016-8f5ef8e8`.
Its private rollback backup remains on the persistent Railway volume at
`/data/reset-backup-vo1d-user-request-20261016-8f5ef8e8`.
The startup invocation has been removed. This update does not reset any account,
username, message, local vault or existing administrator. The public account epoch
and explicit enrollment marker continue to stop old clients silently enrolling
previously reset accounts.

## Validation

Server suites cover discovery/visibility, explicit first claim and races,
permanent-owner recovery, retired endpoints and legacy account-deletion cleanup.
Native regressions exercise delayed network responses across session switches,
trust-list isolation, silent profile-request rejection, reconnect queue policy,
legacy vault/theme decoding and thumbnail bounds. Both macOS CI runners also build
Debug/Release device code, run XCTest, check app bundles and run Swift/Node Signal
interop. Physical two-phone call quality, offline radio range, haptics and visual
motion still require device QA; simulator builds cannot establish these results.
