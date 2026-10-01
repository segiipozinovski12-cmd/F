#!/bin/bash
# Prepare and compile an unsigned device build, then open Xcode for installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$(uname -s)" != Darwin ]; then
  echo "This command requires a Mac with Xcode installed." >&2
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
python3 scripts/generate_project.py
xcodebuild -resolvePackageDependencies -project ios/VO1DMessenger.xcodeproj -scheme VO1DMessenger
xcodebuild build -quiet -project ios/VO1DMessenger.xcodeproj -scheme VO1DMessenger \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/iphone-validation CODE_SIGNING_ALLOWED=NO
python3 scripts/validate_ios_bundle.py build/iphone-validation/Build/Products/Debug-iphoneos/VO1DMessenger.app
open ios/VO1DMessenger.xcodeproj
echo "Choose your Team and connected iPhone in Xcode, then press Command-R to sign and install."
