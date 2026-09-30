#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNAL_ROOT="$ROOT/Vendor/libsignal"
EXPECTED=efe13e9b363d2c115dba61b76e5e53bbfc2874bc
test "$(git -C "$SIGNAL_ROOT" rev-parse HEAD)" = "$EXPECTED"
TARGET="${1:-aarch64-apple-ios-sim}"
MODE="${2:-debug}"
case "$TARGET" in aarch64-apple-ios|aarch64-apple-ios-sim) ;; *) exit 2 ;; esac
rustup target add --toolchain nightly-2025-02-25 "$TARGET"
# Rust calls the simulator target "ios-sim"; LLVM accepts "ios-simulator".
# bindgen appends these flags after its inferred target and needs the SDK headers.
SDK=iphoneos
if [ "$TARGET" = aarch64-apple-ios-sim ]; then
  SDK=iphonesimulator
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--target=arm64-apple-ios-simulator -isysroot $(xcrun --sdk "$SDK" --show-sdk-path)"
fi
export SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
cd "$SIGNAL_ROOT"
export IPHONEOS_DEPLOYMENT_TARGET=13
export RUSTFLAGS="--cfg aes_armv8 ${RUSTFLAGS:-}"
# Native C LTO can discard ring's C symbols before the Rust archive is linked.
# Keep native objects intact; Rust release LTO remains enabled.
# OPENSSL_SMALL globally removes a ring P-256 symbol required by its Rust code.
# Do not pass BoringSSL-only preprocessor switches to every native dependency.
export CFLAGS="-fno-lto ${CFLAGS:-}"
ARGS=(build --locked -p libsignal-ffi --target "$TARGET")
FEATURES=log/release_max_level_info
if [ "$TARGET" = aarch64-apple-ios-sim ]; then FEATURES="$FEATURES,libsignal-bridge-testing"; fi
if [ "$MODE" = release ]; then
  export CARGO_PROFILE_RELEASE_LTO=fat
  ARGS+=(--release)
fi
cargo "${ARGS[@]}" --features "$FEATURES"
PLATFORM=iphonesimulator
CONFIGURATION=Debug
if [ "$TARGET" = aarch64-apple-ios ]; then PLATFORM=iphoneos; fi
if [ "$MODE" = release ]; then CONFIGURATION=Release; fi
mkdir -p "$SIGNAL_ROOT/artifacts/$PLATFORM/$CONFIGURATION"
cp "$SIGNAL_ROOT/target/$TARGET/$MODE/libsignal_ffi.a" "$SIGNAL_ROOT/artifacts/$PLATFORM/$CONFIGURATION/libsignal_ffi.a"
