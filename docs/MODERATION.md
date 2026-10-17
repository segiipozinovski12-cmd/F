# Opt-in moderation and permanent @vo1d

This branch adds a moderation channel, not access to conversation keys. The relay never receives a general chat decryption key. Evidence is selected on the reporting device and encrypted to the administrator's signed public card. Delegated moderators cannot decrypt evidence addressed only to @vo1d.

## Permanent first claim

The first authenticated, successful `POST /v1/username` claiming `vo1d` becomes the permanent owner in the same SQLite write transaction. Competing claims receive `409 Username is already taken`; username checks report occupied. Other reserved service names remain unavailable.

The owner cannot rename or release @vo1d. Account deletion, inactivity cleanup and process restart retain the owner tombstone and pinned public card. The same signing and agreement keys may re-register the account. Agreement-key replacement is rejected until a deliberate, separately reviewed migration exists. Verified owner MFA also survives account deletion, so deleting and re-registering is not an MFA reset.

Ownership is per authoritative relay database. Preserve that database and its backups. Deleting or maliciously rewriting the entire operator database is outside the permanence guarantee. Claim @vo1d with the intended identity before opening public registration, then configure MFA. There is no username-based takeover or automatic owner reassignment when keys are lost.

## Reporting flow

The iOS entry points are a contact profile, the chat menu and a message's context menu. Reasons: spam, harassment, threats, impersonation, illegal content and other. The sender may select up to ten available messages and explicitly include local attachments up to 64 KiB each. Remote files are not automatically downloaded. Comments are limited to 4,000 characters. The total ciphertext limit is 256 KiB.

Consent starts off. The screen shows the administrator fingerprint, selected content, retention and the fact that a moderator can save the disclosed evidence. A complaint can omit messages entirely. Reporting does not send the whole room, drafts, read capabilities, blob keys or unrelated messages. The administrator card is pinned per relay in the encrypted vault; a changed card stops subsequent reporting.

Selected content uses the existing `VO1D-ENVELOPE-1` seal: ephemeral X25519, HKDF-SHA256, AES-GCM with authenticated headers and Ed25519 signatures. This preserves existing wire compatibility. It is separate from ordinary libsignal conversations and has **no report forward secrecy after compromise of the administrator's static agreement key**. Standard primitives do not make the custom envelope an independently audited protocol. Report-specific protocol review is a release gate; ordinary new chat messages continue to use pinned libsignal PQXDH/Double Ratchet.

The exact signed ciphertext is saved before transmission. Reconnection retries those same bytes. Matching duplicates are idempotent; changed payloads under the same report ID are rejected. Both API and client validate domain, recipient, reason/source and limits. The moderator compares decrypted subject/reason/source to queue metadata. New appeals also bind the originating case inside the encrypted content.

The relay knows reporter ID, subject ID, reason, source, time, status and ciphertext size. This is metadata-minimizing reporting, not anonymous reporting. A self-signed first administrator card is TOFU: verify the initial fingerprint over a trusted channel.

## API and access

All endpoints require normal account authentication. Moderator operations additionally require `X-Moderation-Token` obtained after MFA. Call-only and bot credentials cannot use the moderator API.

| Endpoint | Purpose |
| --- | --- |
| `GET /v2/reports/config` | Signed @vo1d recipient and limits |
| `POST /v2/reports` | Explicit consent and sealed envelope only |
| `GET /v2/reports/mine` | The caller's report status, no evidence |
| `GET /v2/reports/notices` | The caller's active decisions |
| `POST /v2/appeals` | Caller-owned active decision and sealed appeal |
| `GET /v2/moderation/access` | Own role and MFA enrollment status |
| `POST /v2/moderation/mfa/setup` | Ten-minute enrollment secret, role required |
| `POST /v2/moderation/mfa/verify` | TOTP verification and a 15-minute session |
| `POST /v2/moderation/mfa/recovery-codes` | MFA session plus fresh OTP: rotate eight recovery codes |
| `POST /v2/moderation/mfa/recover` | Account keys plus one recovery code: reset MFA, revoke all sessions |
| `POST /v2/moderation/logout` | Revoke moderator sessions |
| `GET /v2/moderation/queue` | Bounded queue metadata |
| `POST /v2/moderation/assign` | Revision-checked assignment or release |
| `GET /v2/moderation/report/{id}` | Owner-only sealed selected evidence |
| `GET /v2/moderation/appeals` | Appeal queue metadata |
| `GET /v2/moderation/appeal/{id}` | Owner-only sealed appeal |
| `POST /v2/moderation/decision` | Status and optional explicit sanction |
| `POST /v2/moderation/appeal-decision` | Independent appeal outcome, scoped to the original case |
| `GET, POST /v2/moderation/roles` | Owner-only moderator management |
| `GET /v2/moderation/audit` | Last 200 hash-linked events |
| `GET /v2/moderation/metrics` | Aggregate counts, age and evidence storage |

`owner` can grant/revoke roles and decrypt evidence on the owner device. `admin` can process the queue and issue warnings, restrictions, bans or lift a decision. `reviewer` can process queue status but cannot sanction or decrypt owner-addressed evidence. Roles never imply access to another user's conversation keys.

Decisions require an expected revision to prevent two moderators silently overwriting one another. Restrictions last 60 seconds to 30 days; native action buttons default to one day. No automatic ban follows complaint count. A more severe active sanction cannot silently be replaced with a weaker one. Appeals are available only to the sanctioned subject; submission and exact retries are idempotent.

## MFA and operator setup

Set a persistent `VO1D_MODERATION_KEY` in the deployment secret manager: 32 random bytes in standard base64. It encrypts server-side TOTP secrets with AES-GCM and identity-bound associated data; it is not an evidence decryption key. Docker Compose forwards this variable. If absent or incorrect, enrollment/authentication fail closed with a generic operator error.

Example generation on the operator's machine:

```bash
python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())'
```

Never commit the result. Back up this secret independently with the database and keep the identity backup and authenticator recovery material secure. Enrollment cannot overwrite a verified authenticator. MFA implements [RFC 6238 TOTP](https://datatracker.ietf.org/doc/html/rfc6238) using standard-library HMAC: SHA-1, six digits, 30-second steps, a bounded clock window, replay counters and rate limits. Moderator tokens are stored as digests, bound to the particular account session and revoked on role removal. Native sessions/content are cleared on background, lock, profile changes and timeout.

The first successful enrollment verification returns eight independent 128-bit one-use recovery codes once; only domain-separated SHA-256 digests are stored. Existing moderators can generate a new set with an MFA session and a fresh unused OTP. Recovery requires both current account authentication (private signing keys) and one code. It consumes all old codes, resets the authenticator and revokes normal/moderator sessions; the owner must authenticate and enroll again. It does not reassign @vo1d or recover lost private keys. Role removal deletes the corresponding codes. Attempts share the MFA rate limit; concurrent consumption is serialized and tested. The native panel clears displayed codes on background/lock/profile changes and encourages separate offline storage. Restore from a historical operator backup discards these codes; see [OPERATIONS.md](OPERATIONS.md).

## Retention and abuse boundaries

- Evidence ciphertext and sender-card snapshots are cleared at expiry, at most seven days. Expired reads return `410`.
- Case/appeal metadata remains for 90 days so a 30-day decision can still be appealed after evidence expires.
- Audit retains at most 50,000 hash-linked events. It detects inconsistent changes against a trusted checkpoint; it is not tamper-proof against an operator replacing the entire database and chain.
- Reports are limited to five per identity/day, one per subject/hour, 10,000 retained cases and 64 MiB shared by report/appeal envelopes. Enrollment/verification attempts have their own rate limit.
- Selected text is a reporter's assertion, not independent proof of another sender's authorship. Moderators must review context and appeals; quotas do not eliminate Sybil accounts or coordinated false reports.
- Account-authorized sending, uploads and call authority are restricted by sanctions; calls recheck authority and restrictions. Identity-free private capabilities cannot be globally banned by account ID without destroying that privacy boundary. Local blocking, invitation consent, capability revocation, proof-of-work and bounded queues remain necessary.
- Logical SQLite deletion does not guarantee erasure of WAL, filesystem snapshots, recipient copies or files a moderator explicitly saved.

Complete operator recovery drills, hardware MFA/lock QA, privacy disclosures and independent review before treating this as a production moderation service.

## Queue and review workflow

Queues support `limit=1..100`, an opaque `cursor` and status filtering. Reports additionally accept `reason`, an ID-prefix `search` (8–64 characters), and `assignment=all|mine|unassigned`. Cases are traversed by immutable `(created,id)` ordering, including equal timestamps. `nextCursor=null` ends a traversal; new arrivals and changed filters require a refresh. Cursors are bound to the filters and requesting moderator, and confer no authorization. Metadata pages contain neither reporter ID nor evidence. The iOS dashboard defaults to active cases, loads 50 at a time and offers both report and appeal continuation.

`POST /v2/moderation/assign` takes `{report,assignee,expectedUpdated}`, with explicit JSON null to release. Reviewers may claim free cases or release their own; administrators can assign any active moderator. Closed cases cannot be assigned. Role revocation releases that person's cases and advances their revisions. Reviewers cannot change cases assigned to someone else. Assignment and decisions share the same monotonically advancing revision.

`POST /v2/moderation/appeal-decision` takes `{appeal,outcome,expectedUpdated}`; outcome is `upheld` or `overturned`. Only admins/owner may decide. The original sanction author cannot review their own decision, except the permanent owner who must explicitly send `acknowledgeSelfReview:true`; this exception is named in the audit. The author is recorded in case metadata so expiry or replacement of a sanction does not erase the separation check. Overturning removes only a sanction whose subject **and original report ID** match: a newer independent sanction stays active. Repeated/stale/closed decisions return 409. Delegated review still has metadata access only; evidence remains encrypted solely for @vo1d.
