# Embedded Tor dependency

`Tor.framework` release v409.13.1 from https://github.com/iCepa/Tor.framework,
source inspected at `51cc492a817bbbc8a647b493d7dde2c0b765ae41`.
The XCFramework SHA-256 is pinned to the upstream podspec. SwiftPM verifies it.
Tor 0.4.9.13, libevent 2.1.13, OpenSSL 3.6.4, liblzma 5.8.4, per upstream release.
Upstream requires Xcode 27 for building its sources and says its builds are not
reproducible. This app consumes its published native binary; compile/link tests
are necessary on the selected SDK, followed by device routing and DNS capture.

The framework wrapper is MIT. Tor is BSD licensed; OpenSSL and dependency
notices must accompany distributions. Original source and licenses are in the
upstream release/repository. Native artifact pinning is not a reproducible-build
claim. `EmbeddedTorCore` uses only the documented tor_api.h public API.

Tor permits one instance per process. After shutdown, a new run can expose Tor
BUG 23847; the app keeps the instance alive and requests a process restart after
fatal exit rather than starting concurrent or repeated instances.
