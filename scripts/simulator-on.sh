#!/bin/bash
# Boot (if needed), install and launch the Stack app on the dedicated simulator. Idempotent: never
# shuts anything down. Build first, or pass --build (STACK_API_URL is honored).
set -euo pipefail
cd "$(dirname "$0")/.."
D=68DEB5C0-C366-418B-B07B-2B7B0F8B1020
BUNDLE=com.matthewkooy.stack.swift
APP=.jac/ci-ios-swift/DerivedData/Build/Products/Debug-iphonesimulator/Stack.app

if [[ "${1:-}" == --build ]]; then
  STACK_IOS_DESTINATION="platform=iOS Simulator,id=$D" bash scripts/ci/ios-swift.sh build
fi
[[ -d "$APP" ]] || { echo "No build at $APP; run with --build." >&2; exit 1; }

state=$(xcrun simctl list devices | sed -n "s/.*$D) (\([A-Za-z]*\)).*/\1/p")
if [[ "$state" != Booted ]]; then
  echo "Booting simulator (state: ${state:-unknown})..."
  xcrun simctl boot "$D"
fi
xcrun simctl bootstatus "$D" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$D" 2>/dev/null || true
echo "Installing..."
xcrun simctl install "$D" "$APP"
xcrun simctl launch --terminate-running-process "$D" "$BUNDLE"
