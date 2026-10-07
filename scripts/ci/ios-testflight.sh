#!/bin/bash
set -euo pipefail

STACK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$STACK_ROOT"

# upload signs, exports, and sends the build to TestFlight. validate archives
# unsigned for pull requests, which receive no signing secrets.
MODE=${STACK_TESTFLIGHT_MODE:-upload}
case "$MODE" in
  upload|validate) ;;
  *) echo 'STACK_TESTFLIGHT_MODE must be upload or validate.' >&2; exit 1 ;;
esac

: "${STACK_API_URL:?Set the STACK_API_URL secret to the public HTTPS API origin.}"
: "${GITHUB_RUN_NUMBER:?This script must run from GitHub Actions.}"
: "${GITHUB_RUN_ATTEMPT:?This script must run from GitHub Actions.}"
if [[ "$MODE" == upload ]]; then
  : "${APPLE_TEAM_ID:?Set the APPLE_TEAM_ID Actions variable to the Apple Developer Team ID.}"
  : "${ASC_KEY_ID:?Set the ASC_KEY_ID secret.}"
  : "${ASC_ISSUER_ID:?Set the ASC_ISSUER_ID secret.}"
  : "${ASC_AUTH_KEY_PATH:?The workflow must provide ASC_AUTH_KEY_PATH.}"
  if [[ ! -s "$ASC_AUTH_KEY_PATH" ]]; then
    echo 'App Store Connect API key file is missing or empty.' >&2
    exit 1
  fi
  if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'APPLE_TEAM_ID must be the 10-character Apple Developer Team ID.' >&2
    exit 1
  fi
fi

CI_DIR=${STACK_IOS_CI_DIR:-$STACK_ROOT/.jac/ci-ios}
DERIVED_DATA=${STACK_IOS_DERIVED_DATA:-$CI_DIR/DerivedData}
ARCHIVE=$CI_DIR/Stack.xcarchive
APP=$ARCHIVE/Products/Applications/Stack.app

export STACK_BUILD_MODE=release
export STACK_BUILD_NUMBER="$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT"
export STACK_PUSH_ENABLED=0
export CI=1
export EXPO_NO_TELEMETRY=1
export NPM_CONFIG_CACHE="$STACK_ROOT/.jac/npm-cache"
export PIP_CACHE_DIR="$STACK_ROOT/.jac/pip-cache"
# Jac 0.37.21 fails to type-check its own client runtime when the extracted
# runtime lives inside the project, which is scripts/jac's default cache.
export STACK_JAC_CACHE_HOME="${STACK_JAC_CACHE_HOME:-${RUNNER_TEMP:?RUNNER_TEMP must be set outside the project.}/jac-tool-cache}"

case "$(uname -s)" in
  Darwin) ;;
  *) echo 'TestFlight builds require the hosted macOS runner.' >&2; exit 1 ;;
esac

case "$(./scripts/jac --version)" in
  *"jac 0.37.21 "*) ;;
  *) echo 'Native CI requires Jac 0.37.21.' >&2; exit 1 ;;
esac

# Never let a previous archive or IPA satisfy this run's checks.
rm -rf "$ARCHIVE" "$CI_DIR/export"
mkdir -p "$CI_DIR"

node native/build-config.js --check
./scripts/jac install --no-npm
./scripts/jac setup mobile
cp native/package.json native/package-lock.json native/app.config.js native/build-config.js .jac/mobile-rn/
(
  cd .jac/mobile-rn
  npm ci --no-audit --no-fund
  node node_modules/expo/bin/cli prebuild --platform ios --no-install
)

cp native/Podfile.lock .jac/mobile-rn/ios/Podfile.lock
(cd .jac/mobile-rn/ios && LANG=en_US.UTF-8 pod install)
python3 - <<'PY'
from pathlib import Path
import re

def portable_lock(path):
    content = Path(path).read_text()
    content, count = re.subn(r'^  ExpoModulesCore: [0-9a-f]{40}$',
                            '  ExpoModulesCore: CHECKOUT_PATH_DEPENDENT',
                            content, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit('Expected exactly one ExpoModulesCore podspec checksum')
    return content

if portable_lock('native/Podfile.lock') != portable_lock('.jac/mobile-rn/ios/Podfile.lock'):
    raise SystemExit('Native dependency lock changed beyond the Expo checkout-path checksum')
PY
./scripts/jac run --no-serve scripts/compile-mobile.jac

if [[ "$MODE" == upload ]]; then
  AUTH=(-allowProvisioningUpdates
    -authenticationKeyPath "$ASC_AUTH_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  SIGNING=("${AUTH[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic)
else
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild -workspace .jac/mobile-rn/ios/Stack.xcworkspace -scheme Stack \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" -archivePath "$ARCHIVE" \
  "${SIGNING[@]}" archive \
  2>&1 | tee "$CI_DIR/archive.log"

if [[ ! -s "$APP/main.jsbundle" ]]; then
  echo 'Release archive is missing its embedded JavaScript bundle.' >&2
  exit 1
fi

BUILT_NUMBER=$(plutil -extract CFBundleVersion raw "$APP/Info.plist" 2>/dev/null || true)
if [[ "$BUILT_NUMBER" != "$STACK_BUILD_NUMBER" ]]; then
  echo "Release archive has CFBundleVersion '${BUILT_NUMBER:-missing}', expected '$STACK_BUILD_NUMBER'." >&2
  exit 1
fi

if [[ "$MODE" == validate ]]; then
  echo "Unsigned release archive $STACK_BUILD_NUMBER validated; skipped signing and upload."
  exit 0
fi

# Keep the verified build number; Xcode would otherwise renumber during export.
cat > "$CI_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$CI_DIR/export" \
  -exportOptionsPlist "$CI_DIR/ExportOptions.plist" \
  "${AUTH[@]}" \
  2>&1 | tee "$CI_DIR/export.log"

IPA_PATH=$CI_DIR/export/Stack.ipa
if [[ ! -s "$IPA_PATH" ]]; then
  echo 'Xcode did not export the expected Stack.ipa.' >&2
  exit 1
fi

xcrun altool --upload-app --type ios --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  2>&1 | tee "$CI_DIR/upload.log"
