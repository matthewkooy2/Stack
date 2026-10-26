#!/bin/bash
# Build the SwiftUI app and run it on your iPhone: one command, from anywhere.
#
#   scripts/ios-phone.sh              build, install and launch
#   scripts/ios-phone.sh --no-build   reinstall and relaunch what was built last (fast)
#   scripts/ios-phone.sh --launch     only relaunch the app that is already on the phone
#
# Before you run it: plug the phone in (or have it on the same Wi-Fi), unlock it, and keep it awake.
#
# Environment overrides:
#   STACK_PHONE      device name or UDID (default: the first paired physical iPhone)
#   STACK_IOS_TEAM   Apple developer team ID used for signing (default 38BZ2B7677)
#   STACK_API_URL    API origin baked into the build (default: the Tailscale desktop)
#   STACK_BUNDLE_ID  bundle ID (default com.matthewkooy.stack, replacing the Expo app on the phone)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

TEAM=${STACK_IOS_TEAM:-38BZ2B7677}
export STACK_API_URL=${STACK_API_URL:-https://ryans-desktop.tailfe312e.ts.net:8443}
# The production ID: the backend's Apple sign-in only accepts tokens issued for it. This replaces the Expo build
# of Stack on the phone. Set STACK_BUNDLE_ID=com.matthewkooy.stack.swift for a separate dev copy.
BUNDLE=${STACK_BUNDLE_ID:-com.matthewkooy.stack}
WORK=$ROOT/.jac/ci-ios-device
DERIVED=$WORK/DerivedData
APP=$DERIVED/Build/Products/Debug-iphoneos/Stack.app
mkdir -p "$WORK"

MODE=build
case "${1:-}" in
  --no-build) MODE=install ;;
  --launch) MODE=launch ;;
  "") ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

find_phone() {
  xcrun devicectl list devices --json-output "$WORK/devices.json" >/dev/null 2>&1 || die "Could not list devices. Is Xcode installed and selected?"
  python3 - "$WORK/devices.json" "${STACK_PHONE:-}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2].lower()
for device in json.load(open(path))["result"]["devices"]:
    hardware, props = device.get("hardwareProperties", {}), device.get("deviceProperties", {})
    if hardware.get("reality") != "physical" or device.get("connectionProperties", {}).get("pairingState") != "paired":
        continue
    name, udid = props.get("name", ""), hardware.get("udid", "")
    if not want or want in (name.lower(), udid.lower()):
        print(udid, name)
        break
PY
}

PHONE=$(find_phone)
[[ -n "$PHONE" ]] || die "No paired iPhone found. Plug it in, unlock it, tap Trust, and try again."
UDID=${PHONE%% *}
NAME=${PHONE#* }
say "iPhone: $NAME"

if [[ "$MODE" == build ]]; then
  say "Building (the first build takes a few minutes, later ones are quick)..."
  python3 scripts/ci/resume-review/prepare.py >/dev/null
  (cd ios && xcodegen generate --spec project.yml --project . >/dev/null)
  if ! xcodebuild build \
      -project ios/Stack.xcodeproj -scheme Stack -configuration Debug \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
      "STACK_API_URL=$STACK_API_URL" "STACK_BUNDLE_ID=$BUNDLE" STACK_APPLE_SIGN_IN_ENABLED=YES \
      STACK_APPLE_ENTITLEMENTS=Stack/StackApple.entitlements \
      >"$WORK/build.log" 2>&1; then
    grep -E "error:" "$WORK/build.log" | sort -u | head -15 || true
    die "Build failed. Full log: $WORK/build.log"
  fi
fi

if [[ "$MODE" != launch ]]; then
  [[ -d "$APP" ]] || die "Nothing built yet. Run without --no-build first."
  say "Installing..."
  xcrun devicectl device install app --device "$UDID" "$APP" >"$WORK/install.log" 2>&1 \
    || { tail -8 "$WORK/install.log"; die "Install failed. Is the phone unlocked and connected?"; }
fi

say "Launching..."
if ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE" >"$WORK/launch.log" 2>&1; then
  tail -6 "$WORK/launch.log"
  die "Could not launch. Unlock the phone and run: scripts/ios-phone.sh --launch
If it says the developer is not trusted: Settings > General > VPN & Device Management > trust your Apple ID."
fi
say "Running on $NAME."
