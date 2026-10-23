#!/bin/bash
# Prepare and compile an unsigned device build, then open Xcode for installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$(uname -s)" != Darwin ]; then
  echo "This command requires a Mac with Xcode installed." >&2
  exit 1
fi
if [ "$EUID" -eq 0 ]; then
  echo "Run this command as your Mac user, without sudo, so Xcode can write its build files." >&2
  exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Open Xcode once and finish installing its iOS components." >&2
    exit 1
  fi
fi
DERIVED_DATA="$ROOT/build/iphone-validation"
BUILD_LOG="$ROOT/build/iphone-validation.log"
python3 scripts/configure_xcode_cache.py ios/VO1DMessenger.xcodeproj "$DERIVED_DATA"
: > "$BUILD_LOG"
trap 'echo "Preparation/build failed. Full log: $BUILD_LOG" >&2' ERR
python3 scripts/generate_project.py
xcodebuild -resolvePackageDependencies -project ios/VO1DMessenger.xcodeproj -scheme VO1DMessenger \
  -derivedDataPath "$DERIVED_DATA" 2>&1 | tee -a "$BUILD_LOG"
xcodebuild build -quiet -project ios/VO1DMessenger.xcodeproj -scheme VO1DMessenger \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO 2>&1 | tee -a "$BUILD_LOG"
python3 scripts/validate_ios_bundle.py "$DERIVED_DATA/Build/Products/Debug-iphoneos/VO1DMessenger.app"
open ios/VO1DMessenger.xcodeproj
echo "Choose your Team and connected iPhone in Xcode, then press Command-R to sign and install."
