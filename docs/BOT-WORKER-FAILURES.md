# Native bot failure handling

Corrupt or unauthenticated payloads are rejected individually and acknowledged only after a durable replay marker is saved. The worker retains a bounded aggregate rejection count, without plaintext, sender IDs or token logging. A poison packet cannot keep other users' valid messages behind it forever. Failure to obtain a sender card over the network is retried; it is not treated as a bad payload.

Reply preparation uses a copy of the existing libsignal snapshot and vault state. A failed filesystem save neither advances the committed ratchet nor marks a legitimate message processed/rejected. The relay copy remains unacknowledged; the same packet can be retried when storage becomes writable. Native tests cover a corrupt packet followed by a real libsignal command/reply and a forced write failure followed by successful retry.

Outgoing bot deliveries retain exact ciphertext, retry delays and permanent-failure markers in the bot vault. Eligibility is checked before batch limits so failed queue heads do not starve later work. Private inbox polling rotates through bounded batches with a saved cursor. Limits remain 100 pending replies, 1,000 contacts, 5,000 replay markers and 512 local mailbox addresses. These bounds do not eliminate coordinated spam or provide a 24/7 execution service.
