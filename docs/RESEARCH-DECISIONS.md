# Decisions for research items 16, 23, 32 and 48

These are documented design decisions, not implemented production features. No UI toggle claims the properties described below.

## Independent hops and cover traffic — 16 / 23

Current Tor connections, padding buckets and queue delay reduce particular disclosures but do not establish resistance to a global timing observer. Adding a second HTTP relay controlled by the same operator would not establish an independent trust boundary.

Loopix combines independently delayed forwarding and cover loops in a mix network, with provider support for offline reception. Our inference is that comparable protection requires a network protocol and operator ecosystem, rather than occasional dummy packets added to the existing endpoint. Tor's documented correlation limitations remain relevant. Sources: [Loopix paper](https://www.usenix.org/system/files/conference/usenixsecurity17/sec17-piotrowska.pdf), [Tor attack model](https://support.torproject.org/about-tor/security/attacks-on-onion-routing/), [Tor padding specification](https://spec.torproject.org/padding-spec/).

Decision: preserve fail-closed Tor as the current route; do not advertise traffic-analysis resistance. A separate experimental mix transport should require three independent operators, an externally reviewed envelope/receipt format, packet-loss accounting, bounded queues, and measurement of bandwidth/latency/battery on iOS. Operator independence and resistance to active dropping need review; the number of hops alone is not a security proof. Cover traffic must be budgeted and maintained across quiet and busy periods. iOS cannot promise unrestricted continuous background execution, so experiments should explicitly report foreground and suspended behaviour. Acceptance requires adversarial timing/correlation experiments and real measurements; none have been run for this app.

## Poll secrecy from the creator — 32

Existing private polls disclose votes to the creator and only aggregate counts to other members. This must remain explicit. Removing voter names or deleting a dictionary does not make the creator unable to decrypt ballots.

Helios provides publicly verifiable encrypted voting and separates tally verification from assumptions about ballot privacy; trustees are part of that privacy boundary. The paper targets settings without coercion resistance. Source: [Helios paper](https://www.usenix.org/event/sec08/tech/full_papers/adida/adida.pdf).

Decision: a future secret-ballot mode needs threshold tally keys held by distinct trustees, encrypted ballots, eligibility credentials, replay/revote policy, verifiable tally and minimum participation rules. The poll creator must not possess enough trustee shares to decrypt alone. Small groups and intermediate results can reveal an individual's choice by subtraction; require a closed tally and a clearly stated collusion threshold. Use an audited implementation rather than implementing voting cryptography from this sketch. Current app polls are not suitable for this claim, high-stakes elections or coercion resistance.

## Anonymous quota and access credentials — 48

Current capability proof-of-work and IP/rate limits bound abuse but do not provide unlinkable proof of eligibility. They can disadvantage users sharing a Tor exit or reverse proxy, and an attacker can create more identities.

Privacy Pass issuance and blind RSA signatures provide standardized building blocks, with distinct roles and explicit privacy assumptions. Sources: [RFC 9578](https://www.rfc-editor.org/rfc/rfc9578), [RFC 9474](https://www.rfc-editor.org/rfc/rfc9474).

Decision: do not invent a blind-token protocol inside the relay. A deployment must first choose independent issuer/attester roles and a non-identifying eligibility policy. Tokens should be domain-separated by service, class and expiry, redeemed once with bounded spent-token retention, and issued/redeemed over separate sessions. Timing, issuer collusion and redemption logs can undermine unlinkability. Production acceptance requires a supported audited library, interop vectors, concurrency/expiry tests and an external review of role separation. No issuance endpoint or anonymous-credential guarantee is shipped in this branch.
