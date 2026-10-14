# Parser fuzzing

The existing XCTest and relay suites include bounded seeded mutations. `scripts/fuzz_relay.py` additionally runs [Google Atheris](https://github.com/google/atheris), a coverage-guided libFuzzer engine, against the repository's Python HTTP/JSON validation paths. The development dependency is pinned to the [3.1.0 CPython 3.12 Linux wheel and published SHA-256](https://pypi.org/project/atheris/3.1.0/).

Run on Linux x86_64 with Python 3.12:

```bash
pip install --require-hashes -r server/requirements.lock
pip install --require-hashes --only-binary=:all: -r tools/fuzz-requirements.lock
mkdir -p build-evidence/fuzz build-evidence/fuzz-corpus
python scripts/fuzz_relay.py build-evidence/fuzz-corpus -runs=5000 -max_len=65536 -timeout=5 -rss_limit_mb=512 -artifact_prefix=build-evidence/fuzz/
```

`python scripts/fuzz_relay.py --replay` validates the 110 initial seeds without Atheris and works on Windows. Every run creates disposable keys, sessions and a local temporary database; it never connects to a deployed relay. Rate limiting is disabled only on that test instance to keep fuzzing from degenerating into 429 responses. Production rate limits remain enabled and have their own tests. Inputs select report, appeal, bot, prekey, moderation, envelope and private-mailbox endpoints.

An unexpected 500, uncaught error, timeout or memory-budget failure fails the run. CI uploads its local log and any crash corpus. Minimize a crash with libFuzzer, add a deterministic regression test, repair it, and rerun the exact candidate. A bounded green run is not exhaustive coverage. This harness does not instrument native libsignal, CryptoKit, Tor, Swift decoders or C/C++ with ASan/UBSan; those need separate native fuzz targets and review. Never add production payloads, moderator evidence or real credentials to a fuzz corpus.
