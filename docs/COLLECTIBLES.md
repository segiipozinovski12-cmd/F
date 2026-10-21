# VO1D profiles, collectibles and Premium

This release extends the existing iOS messenger and relay. The migration only
creates tables and inserts missing collection definitions. It does not reset
accounts, usernames, keys, mailboxes, messages, call authority or the account
epoch. Do not arm `VO1D_REQUESTED_RESET` to deploy this release.

## User experience

The tab bar contains Chats, People, Showcase, Profile and Settings. Profile has a
cover, story-ring avatar, description, status, Premium badge, stories and gifts.
Edit Profile can share the profile with explicitly selected trusted contacts
through the existing Signal event transport. Profile text/photos/stories are not
published to the commerce server. Existing story audiences and 24-hour expiration
remain in force. Shared stories have progress, pause and previous/next controls.

The five original procedural 3D artworks are Singularity, Sovereign, Prism, Orbit and
Nova. Cards are rendered locally into cached 512px previews. No remote image tracking or
emoji substitute is used. Purchased gifts start without collectible attributes.
Their collection serial, original price in VO1Dcoin and owner are server records.
Gifts are initially hidden; owners may display/hide them in their profile. Public
gift data deliberately includes an account identity/username, collection, serial
and traits. A marketplace listing is public even when hidden from the profile.

| Collection | Maximum supply | Gift price, VO1Dcoin | Upgrade, VO1Dcoin |
| --- | ---: | ---: | ---: |
| Singularity | 2,000 | 25,000 | 500 |
| Sovereign | 5,000 | 10,000 | 350 |
| Prism | 10,000 | 4,000 | 250 |
| Orbit | 35,000 | 1,500 | 150 |
| Nova | 55,000 | 500 | 100 |

Total maximum issuance: **107,000**. The relay assigns serials from 1 within each
collection; transfers and secondary sales keep the original number and traits.
Deleting an account through the pre-existing account deletion policy retires its
owned artifacts without recycling numbers or decreasing issued supply.

The existing permanently pinned administrator (`moderation.owner`, not a client
username comparison) sees publication controls inside Showcase. Each collection
starts as a draft. Publishing a gift and releasing its upgrade are separate,
confirmed actions with server audit records. A sold-out collection can still
receive an upgrade release. Deployment never publishes automatically.

## Ownership, settlement and retries

All state changes run inside one SQLite write transaction using the relay's WAL
database, full synchronization and existing worker-safe write serialization.
Wallet debit, issuance, serial allocation, ownership and the ledger commit or roll
back together. A secondary sale debits the buyer, credits the seller and moves
ownership atomically, without commission. A listed gift cannot be transferred or
upgraded. Removing a listing invalidates its ID; the next listing gets a new ID.
Clients submit the expected price and cannot replace it with their own price.

Every collectible mutation requires a UUID `requestID`. `(owner, requestID)` is
unique and bound to the request route and content digest. An exact retry returns
the committed response; using that key for another operation returns 409. New
upgrade requests cannot reroll an already upgraded gift. Bot credentials cannot
authorize economy operations. Transfers respect blocks in either direction and
reset visibility to hidden for the recipient.

## Upgrade odds

`secrets.randbelow(10000)` draws each category independently. The integer weight
tables are in `server/commerce.py`. The rarest background is black Obsidian;
Midnight is also rarer than bright colors. Monochrome can combine with any
background and pattern. None of these probabilities depend on spending history,
client animation, account role or previously drawn traits.

| Category | Probabilities |
| --- | --- |
| Background | Jade 30%, Azure 27%, Lavender 23%, Rose 14%, Midnight 4.5%, Obsidian 1.5% |
| Pattern | Stardust 35%, Orbits 28%, Diamonds 22%, Runes 11%, Eclipse 3.5%, Pure Void 0.5% |
| Model | Original 40%, Pearl 28%, Aurora 20%, Liquid Gold 9%, Crimson Chrome 2.6%, Monochrome 0.4% |

Each category sums to 100%. The probability of Monochrome + Obsidian + Pure Void
is 0.00003%. The server commits the result before the background → pattern → model
reveal. Interruption does not discard or reroll it. The UI respects Reduce Motion.
The approximate value uses the collection price and a disclosed rarity heuristic:
`price * mean((10000 / traitWeight) ** 0.32)`. This is not a market quote, cash
redemption value or guaranteed resale price. Collectibles are internal VO1D assets;
this implementation does not mint blockchain tokens or export to a blockchain.

## Configure real App Store payments

No client-side balance editing, test top-up endpoint or voucher mint is provided.
Create these products in **the app's own App Store Connect account**:

| Product identifier | Type | Delivery | Suggested starting USD tier |
| --- | --- | --- | ---: |
| `io.vo1d.coins.500` | Consumable | 500 VO1Dcoin | $0.99 |
| `io.vo1d.coins.2750` | Consumable | 2,750 VO1Dcoin | $4.99 |
| `io.vo1d.coins.6000` | Consumable | 6,000 VO1Dcoin | $9.99 |
| `io.vo1d.coins.16000` | Consumable | 16,000 VO1Dcoin | $24.99 |
| `io.vo1d.premium.monthly` | Auto-renewable subscription, 1 month | VO1D_PREMIUM | $3.99 |

These tiers are proposed configuration, not hard-coded charges. Set and localize
actual prices in App Store Connect. The iOS wallet displays `Product.displayPrice`
from StoreKit in the purchaser's storefront currency. Gift purchase prices remain
in VO1Dcoin; no invented USD conversion is displayed.

Set these private server variables using the App Store Server API integration key:

- `VO1D_APPLE_ISSUER_ID`
- `VO1D_APPLE_KEY_ID`
- `VO1D_APPLE_PRIVATE_KEY`: PEM P-256 `.p8` contents; literal `\n` is supported
- `VO1D_APPLE_BUNDLE_ID`: exact shipping bundle ID, default `io.vo1d.messenger`
- `VO1D_APPLE_ENVIRONMENT`: `Production` (default), or `Sandbox` on a separate test relay

Configure App Store Server Notifications V2 to POST to
`https://<relay>/v3/storekit/notifications`. The notification payload is only an
untrusted transaction lookup hint. The server fetches the live transaction from
Apple's authenticated, fixed HTTPS endpoint and checks the identity-bound
`appAccountToken`, bundle, environment, transaction ID, ownership and quantity.
It never trusts notification-provided prices, expiration, product or revocation.
Renewals and refunds are idempotent. A refunded coin purchase removes the credit;
any already-spent amount becomes refund debt. Further payments/sale proceeds
settle the debt before producing spendable coins. Purchases and transfers are
blocked while debt remains. A refund cannot make the spendable balance negative.

Do not use the production relay for StoreKit local/Xcode purchases. Sandbox
transactions are rejected in production. Without credentials the relay returns
503 and does not grant coins or Premium. No Apple credentials belong in source.
Payment verification runs outside the SQLite write transaction, so Apple's
latency does not hold the database lock used for chat/call traffic.

The iOS app finishes a StoreKit transaction only after server acknowledgement.
Unfinished transactions, transaction updates, current subscription entitlements,
foreground recovery and explicit Restore Purchases cover interrupted purchases.
A transaction is globally unique and stays bound to the original VO1D identity,
including after account deletion, preventing reuse on another identity.

## VO1D_PREMIUM

The subscription enables the profile badge, Aurora/Ember/Frost palettes and voice
transcription. Existing themes remain free. Subscription expiry is the verified
Apple transaction expiry, never `now + 30 days` on each replay. Notifications
update expiry/revocation even when the app is closed. Every new transcription also
rechecks the most recent recorded subscription with Apple.

Voice transcription is invoked beneath every existing voice player. The user can
select the language. It uses Apple's on-device Speech framework with
`requiresOnDeviceRecognition = true`. The authenticated relay authorizes Premium
first; it receives no audio or transcript. The recording is written to a protected
temporary file and removed on success, error, cancellation or view dismissal.
Locking/switching accounts cancels recognition and clears displayed text. There is
no per-message VO1Dcoin charge. A missing local language model produces an explicit
error rather than silently uploading private audio. Existing playback speed,
waveform, recording and call audio coordination are retained.

## Verification

Run `python -m unittest discover -s server/tests -v` with the pinned dependencies.
New economy tests cover migration/data preservation, supply/serial limits,
concurrent last-unit and marketplace purchases, ownership attacks, retries,
independent odds, visibility, settlement rollback, payment replay, refunds,
notifications, subscription expiry and transcription entitlement. StoreKit tests
cover fixed-host lookup, missing credentials, account/bundle/environment/quantity
checks and family-sharing rejection. iOS model tests cover entitlement expiration,
original-gift decoding, serial formatting and mutation payload boundaries.

Regenerate the Xcode project with `python3 scripts/generate_project.py`; the
`--project-only` option updates file registration without fetching native SDKs.
The existing CI builds simulator/device Debug and device Release on macOS 15 and
26, and runs existing chat, cryptography, privacy and call tests. A real Sandbox
purchase and local Speech language availability must be verified on an iPhone
with configured App Store products before release.

## Local 3D inspection and payment readiness

Each collection has its own solid geometry and six material treatments. The detail
screen and upgrade reveal use a live studio scene; the full-screen inspector adds
pan, pinch, accessible rotation/zoom buttons and three lighting setups. These
controls only change the view, never the owned traits. Grids use bounded, cached
512px renders of the same models. Scenes stop automatic motion when hidden,
inactive, Reduce Motion is enabled, or Low Power Mode is active. Assets and
reflection lighting are generated locally without third-party asset requests.

`GET /v3/economy/catalog` exposes the non-secret `paymentsConfigured` boolean.
It checks presence of the Apple credentials, the P-256 key and supported server
environment. This is configuration readiness, not a live Apple authorization
check. The client fails closed for older servers and rechecks the catalog in the
current unlocked session before opening the Apple payment sheet. Product setup,
Apple approval and real sandbox/production purchase testing are still required.
Unfinished verified transactions remain recoverable until the relay acknowledges
that exact purchase; merely enabling the readiness flag never credits a wallet.
