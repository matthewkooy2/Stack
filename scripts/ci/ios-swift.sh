#!/bin/bash
# Build and test the SwiftUI app in ios/. Independent of the Expo/TestFlight pipeline: it signs
# nothing, uploads nothing and shares no state with scripts/ci/ios-testflight.sh.
#
#   scripts/ci/ios-swift.sh static   structural checks that need only Python (any OS)
#   scripts/ci/ios-swift.sh build    generate the project and compile for the simulator (macOS)
#   scripts/ci/ios-swift.sh test     build and run the unit tests (macOS)
#   scripts/ci/ios-swift.sh all      static, then test (default)
#
# Environment:
#   STACK_API_URL              API origin baked into the build (default http://127.0.0.1:8000)
#   STACK_IOS_DESTINATION      xcodebuild destination (default: an available iPhone simulator)
#   STACK_IOS_DERIVED_DATA     derived data directory (default .jac/ci-ios-swift/DerivedData)
set -euo pipefail

STACK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$STACK_ROOT"

MODE=${1:-all}
case "$MODE" in
  static|build|test|all) ;;
  *) echo 'Usage: ios-swift.sh [static|build|test|all]' >&2; exit 2 ;;
esac

static_checks() {
  python3 scripts/ci/ios-swift-static.py
}

require_mac() {
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "The Swift build needs macOS with Xcode. Ran only the static checks; build and test were not run." >&2
    exit 3
  fi
  command -v xcodebuild >/dev/null || { echo 'xcodebuild is not installed (install Xcode 15.4 or newer).' >&2; exit 3; }
  command -v xcodegen >/dev/null || { echo 'xcodegen is not installed (brew install xcodegen).' >&2; exit 3; }
}

pick_destination() {
  if [[ -n "${STACK_IOS_DESTINATION:-}" ]]; then
    printf '%s' "$STACK_IOS_DESTINATION"
    return
  fi
  # The first available iPhone simulator, so the route does not depend on a runner's device list.
  local name
  name=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [^(]*[^ (]\) (.*/\1/p' | head -n 1)
  if [[ -z "$name" ]]; then
    echo 'No iPhone simulator is installed.' >&2
    exit 3
  fi
  printf 'platform=iOS Simulator,name=%s' "$name"
}

generate() {
  export STACK_API_URL="${STACK_API_URL:-http://127.0.0.1:8000}"
  (cd ios && xcodegen generate --spec project.yml --project .)
}

run_xcodebuild() {
  local action=$1
  local destination derived result
  destination=$(pick_destination)
  derived=${STACK_IOS_DERIVED_DATA:-$STACK_ROOT/.jac/ci-ios-swift/DerivedData}
  result=$STACK_ROOT/.jac/ci-ios-swift/$action.xcresult
  rm -rf "$result"
  mkdir -p "$(dirname "$result")"
  # Signing is disabled: this route proves the source compiles and its tests pass, nothing more.
  xcodebuild "$action" \
    -project ios/Stack.xcodeproj \
    -scheme Stack \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    -resultBundlePath "$result" \
    "STACK_API_URL=${STACK_API_URL:-http://127.0.0.1:8000}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

case "$MODE" in
  static)
    static_checks
    ;;
  build)
    static_checks
    require_mac
    generate
    run_xcodebuild build
    ;;
  test)
    static_checks
    require_mac
    generate
    run_xcodebuild test
    ;;
  all)
    static_checks
    require_mac
    generate
    run_xcodebuild test
    ;;
esac
