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
explicit tradeoffs for private delivery/Tor, including discovery address exchange, invitation requirements in maximum mode,
background limitations, latency and metadata exposure.

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

56 reactions use a scrollable picker, grouped emoji/count chips, reversible
selection, and six motion styles: hearts, flame, laughter, electric sparks,
celebration and orbit. Picker feedback starts after dismissal so its effect is
visible; emoji chips pulse with count changes. Effects do not
replay simply because a historical message scrolls into view. Motion and particle
work only occurs for a new change; there is no continuous reaction timer.

Archive is revealed by pulling down, with animated entry and exit. Existing solo
group/channel creation and explicit incoming-call microphone handling remain.

## Security fixes in this update

* Account/emergency deletion and mailbox/blob cleanup are fenced after network
  waits so they cannot reset or modify a newly opened identity. A delayed deletion
  regression verifies that the other vault and identity keys remain intact.
* A delayed username, contact lookup, privacy update or avatar import is fenced to
  the identity and transport generation that initiated it. Contact-request rollback
  no longer spans a network wait or overwrites a subsequently opened identity.
* Privacy/trust sync snapshots the original account's list before sending and
  aborts after a switch; it cannot send the next identity's contacts to the old API.
* Legacy profile requests no longer cause automatic metadata replies. Editing
  local details no longer broadcasts a profile update to every trusted contact.
* Nearby discovery/invitation callbacks from an old browser/advertiser are fenced
  after stop or identity switch, in addition to existing session packet fencing.
* Cancelled microphone prompts cannot start recording later; recorder cleanup only
  deactivates a session it owns and never deactivates an active call.
* Delayed attachment imports/downloads and biometric results are identity-fenced;
  an old chat cannot save its draft into another identity.
* Disabling device authentication now requires device authentication too; a late
  biometric response cannot unlock another identity.
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

## Calls, discovery, entry and cleanup

Outgoing calls show preparation and ringing, retain a pending invitation while the
peer reconnects, refresh expired account authorization, and keep WSS alive with
pings. Local hangup stops media immediately and sends a final signal; media or
CallKit failures also release the server route. Audio capture uses the input
node's output bus format. Internet connectivity is required: calls use data, not
cellular telephone minutes. No telephone-number routing or per-country fee exists.

Everyday and Private Delivery profiles allow an explicit encrypted contact request
from a four-character code or username. The recipient approves before a chat and
call trust are established. A Private Delivery introduction contains only the
address exchange; regular message events cannot fall back to public delivery.
The third, Tor/private-address profile rejects public introductions. Public
lookup/introduction exposes identity IDs to the relay; it does not match a private
invitation's metadata properties.

Settings can disable the next-launch access-key prompt while keeping device
biometrics separate. The default remains protected; Private Space requires its
entry protection. Inactive chats can be removed locally after 1 hour, 24 hours,
7 days or 30 days, or automatic removal can be switched off. Active chats, drafts,
scheduled messages and pending delivery are protected from this cleanup. The last
message activity is retained after disappearing messages expire. Other devices and
exported backups remain outside local cleanup.

Apple push uses neutral payloads for both ordinary and private queues. A private
mailbox subscription requires its read capability. Opting in links those random
mailboxes to an Apple device token; it does not add account/sender IDs to the
private queue. Maximum mode opts out. Account switches, token invalidation,
notification disable and mailbox deletion revoke subscriptions. A readiness check
reports missing APNs configuration; an unsigned/free-team Debug build cannot
receive remote push. `VO1D_ENABLE_DEBUG_PUSH=1` when generating the Xcode project
opts a paid Apple Developer team into development APNs. Production requires a
valid Apple APNs provider key on Railway, matching topic and signed entitlements.

## Permanent administrator and requested account reset

The earlier resets on 2026-10-16 and at 15:16 UTC on 2026-10-17 retained rollback
backups. The latest explicit user request asks to remove server accounts and
those backups permanently. Its unique rollout is
`vo1d-user-request-20261017-c9eb809a`; it runs before HTTP starts only when
`VO1D_REQUESTED_RESET` exactly matches that ID on the guarded production service.
Normal deployments do not arm it. After a verified reset, the helper removes the
named prior account backup directories and records its completion marker. Clear
the arming variable after checking health and the runtime receipt. It is idempotent
if a restart occurs before disarming. Local iPhone histories cannot be erased by
resetting the server.

This reset opts in to automatic permanent `@vo1d` ownership for the first new
registration that completes a signed, single-use authentication challenge. Public
card upload or a replay alone cannot win. Enrollment version 2 and the new account
epoch require an updated client and an explicit registration action; enrollment
permission is consumed after its first use. The winning username cannot be renamed,
released or transferred by account deletion. MFA remains required for owner powers;
the persistent MFA encryption key stays in Railway and is not committed.

## Validation

Server suites cover discovery/visibility, explicit first claim and races,
permanent-owner recovery, retired endpoints and legacy account-deletion cleanup.
Native regressions exercise delayed network responses across session switches,
trust-list isolation, silent profile-request rejection, reconnect queue policy,
legacy vault/theme decoding and thumbnail bounds. Both macOS CI runners also build
Debug/Release device code, run XCTest, check app bundles and run Swift/Node Signal
interop. Physical two-phone call quality, offline radio range, haptics and visual
motion still require device QA; simulator builds cannot establish these results.
