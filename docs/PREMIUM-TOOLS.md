# Founder and Premium tools

The first verified login on an empty deployment with `VO1D_FIRST_ACCOUNT_ADMIN=1`
receives permanent `@vo1d`, administrator authority, lifetime Premium and one each
of Chrome Unicorn, Cyber Skull, Crystal, Chromed Crown and Cute Ghost at serial 0.
Explicit reset bootstrapping follows the same verified-session path. Uploading a
public identity card is insufficient. Owner/username, gifts, grant receipt and
session creation share the transaction. The singleton receipt and unique serials
prevent duplicate grants, including concurrent first logins. Existing permanent
owners migrate without resetting accounts or paid issuance. Zero editions are
outside the ordinary paid supply. Founder gifts start visible in the collection
and can be hidden, transferred or listed through the ordinary ownership checks.
The grant is not reissued after a transfer or explicit deletion. This is an in-app
collection, with no blockchain minting or custody added.

The founder entitlement is separate from App Store subscription expiry. The
wallet includes optional `premiumLifetime`; `premiumUntil` remains compatible
with older clients. Ordinary subscriptions still require real Apple credentials.

New functional Premium tools:

- Local message translation using Apple's Translation framework on iOS 18+.
  Choose a target language in a message's Translate action. iOS requests language
  model downloads when necessary. A fresh server entitlement check occurs before
  starting translation; message plaintext is not sent to the VO1D server.
  Closing/locking/switching profiles invalidates the result; one-view text is not
  offered for translation. Actual model download and quality require a phone;
  simulator CI verifies compilation and surrounding access/session logic.
- Smart folders: combine direct/group/channel types, unread status, unmuted chats
  and attachments, with explicit exclusions and manual inclusions. Hidden rooms
  are always excluded. After expiry, manually selected rooms remain available;
  saved automatic rules remain in the encrypted vault for renewal.
- Saved Message tags: create, rename, color and delete up to 50 tags, assign more
  than one to a saved message, and filter the Saved chat by tag. Tag deletion
  removes assignments; tags never change or disclose the original message.
- Up to 100 named quick replies with unique slash shortcuts. `{name}`, `{me}`,
  `{date}` and `{time}` are substituted once into the composer, allowing review
  before sending. Unicode names cannot inject another placeholder. Existing free
  text snippets remain available. The composer shows matching slash suggestions.

Rules, tags and reply templates are optional encrypted vault state, separate for
each local profile. They are not published in profile events. Changing these
tools requires an unlocked active profile and a nonexpired server-issued wallet.

The profile editor has a live cover/avatar/status/gift preview, circular palette
choices, three pill-shaped sections and a persistent save action. A selected
featured gift (or explicit no-gift choice) is shared as an optional profile field
only with explicitly selected trusted recipients. Existing profile validation,
username reservation, photo size limits and encrypted sharing still apply.
