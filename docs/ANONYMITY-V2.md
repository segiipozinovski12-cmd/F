# VO1D 2: implementation record

Work branch: `codex/anonymous-v2`, based on verified 1.3. No release or deployment is implied by this branch.

## Selected protocol dependency

Signal libsignal v0.70.0, commit `efe13e9b363d2c115dba61b76e5e53bbfc2874bc`, is pinned as a Git submodule. Upstream implements Double Ratchet/PQXDH, signed and one-time prekeys and sender keys. Its Swift API is not supported for third-party products and may change; pinning and interoperability tests are required. Upstream is AGPL-3.0-only; retain notices and fulfil applicable source/licence obligations when distributing. Integration and transport remain unaudited even when using an upstream protocol implementation.

## Delivery rules

- Plaintext queued events remain inside the encrypted local vault. The HTTP API must never serialize a deferred event.
- Advance session state and persist its exact ciphertext in one vault write before sending. Retry sends those same bytes, never re-encrypts the event.
- Existing v1 history remains readable. V2 conversations must not silently downgrade; missing bundles or changed keys stop delivery and show an actionable error.
- Receipt of an authenticated ciphertext and the resulting session state must be persisted before ACK. Failed authentication rolls back state.
- Metadata-minimizing transport requires separate capability mailboxes, isolated connections and private invitations. Signal message encryption alone does not hide routing metadata.

The full 60-item implementation ledger and external validation evidence will be recorded here as work lands. Independent audit, physical-device APNs testing and host configuration cannot be represented as completed software features.
