#!/bin/bash
set -euo pipefail

STACK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$STACK_ROOT"

: "${STACK_API_URL:?Set the STACK_API_URL Actions variable to the public HTTPS API origin.}"
: "${APPLE_TEAM_ID:?Set the APPLE_TEAM_ID Actions variable to the Apple Developer Team ID.}"
: "${ASC_KEY_ID:?Set the ASC_KEY_ID Actions secret.}"
: "${ASC_ISSUER_ID:?Set the ASC_ISSUER_ID Actions secret.}"
: "${ASC_AUTH_KEY_PATH:?The workflow must provide ASC_AUTH_KEY_PATH.}"
if [[ ! -s "$ASC_AUTH_KEY_PATH" ]]; then
  echo 'App Store Connect API key file is missing or empty.' >&2
  exit 1
fi
: "${GITHUB_RUN_NUMBER:?This script must run from GitHub Actions.}"

if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'APPLE_TEAM_ID must be the 10-character Apple Developer Team ID.' >&2
  exit 1
fi

export STACK_BUILD_MODE=release
export STACK_PUSH_ENABLED=0
export CI=1
export EXPO_NO_TELEMETRY=1
export NPM_CONFIG_CACHE="$STACK_ROOT/.jac/npm-cache"
export PIP_CACHE_DIR="$STACK_ROOT/.jac/pip-cache"

case "$(uname -s)" in
  Darwin) ;;
  *) echo 'TestFlight builds require the hosted macOS runner.' >&2; exit 1 ;;
esac

case "$(./scripts/jac --version)" in
  *"jac 0.37.21 "*) ;;
  *) echo 'Native CI requires Jac 0.37.21.' >&2; exit 1 ;;
esac

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

mkdir -p .jac/ci-ios
xcodebuild -workspace .jac/mobile-rn/ios/Stack.xcworkspace -scheme Stack \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath .jac/ci-ios/Stack.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_AUTH_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT" \
  2>&1 | tee .jac/ci-ios/archive.log

if [[ ! -s .jac/ci-ios/Stack.xcarchive/Products/Applications/Stack.app/main.jsbundle ]]; then
  echo 'Release archive is missing its embedded JavaScript bundle.' >&2
  exit 1
fi

cat > .jac/ci-ios/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath .jac/ci-ios/Stack.xcarchive \
  -exportPath .jac/ci-ios/export \
  -exportOptionsPlist .jac/ci-ios/ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_AUTH_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  2>&1 | tee .jac/ci-ios/export.log

IPA_PATH=.jac/ci-ios/export/Stack.ipa
if [[ ! -s "$IPA_PATH" ]]; then
  echo 'Xcode did not export the expected Stack.ipa.' >&2
  exit 1
fi

xcrun altool --upload-app --type ios --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  2>&1 | tee .jac/ci-ios/upload.log
