#!/bin/bash
# Separate native candidate upload. Never invokes Expo or changes the existing release route.
set -euo pipefail
STACK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$STACK_ROOT"
: "${STACK_API_URL:?Missing API origin}"
: "${APPLE_TEAM_ID:?Missing Apple team}"
: "${ASC_KEY_ID:?Missing ASC key ID}"
: "${ASC_ISSUER_ID:?Missing ASC issuer}"
: "${ASC_AUTH_KEY_PATH:?Missing ASC key path}"
: "${GITHUB_RUN_NUMBER:?Actions run number required}"
: "${GITHUB_RUN_ATTEMPT:?Actions attempt required}"
[[ $(uname -s) == Darwin && -s "$ASC_AUTH_KEY_PATH" ]] || exit 3
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 3
# Version 0.2.0 distinguishes the native beta from Expo 0.1.0. Reserve a separate numeric range.
BUILD_NUMBER="$((1000 + GITHUB_RUN_NUMBER)).$GITHUB_RUN_ATTEMPT"
CI_DIR="$STACK_ROOT/.jac/ci-ios-swift-upload"
ARCHIVE="$CI_DIR/Stack.xcarchive"
APP="$ARCHIVE/Products/Applications/Stack.app"
mkdir -p "$CI_DIR"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_AUTH_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
bash scripts/ci/ios-swift.sh all
xcodebuild archive -project ios/Stack.xcodeproj -scheme Stack -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$CI_DIR/DerivedData" "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER=com.matthewkooy.stack MARKETING_VERSION=0.2.0 \
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" "STACK_API_URL=$STACK_API_URL"
python3 - "$APP/Info.plist" "$BUILD_NUMBER" "$STACK_API_URL" <<'PY'
import plistlib, sys
from urllib.parse import urlsplit
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
expected = {'CFBundleIdentifier': 'com.matthewkooy.stack', 'CFBundleShortVersionString': '0.2.0',
            'CFBundleVersion': sys.argv[2], 'StackAPIBaseURL': sys.argv[3]}
if any(info.get(key) != value for key, value in expected.items()):
    raise SystemExit('Native archive identity, version or API configuration does not match this run.')
if info.get('ITSAppUsesNonExemptEncryption') is not False:
    raise SystemExit('Native archive must declare non-exempt encryption as Boolean false.')
origin = urlsplit(sys.argv[3])
if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password:
    raise SystemExit('Native release requires an HTTPS API origin without credentials.')
if info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'):
    raise SystemExit('Native release must not allow arbitrary network loads.')
print('Native archive identity, version, HTTPS origin and export compliance validated.')
PY
cat > "$CI_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$CI_DIR/export" \
  -exportOptionsPlist "$CI_DIR/ExportOptions.plist" "${AUTH[@]}"
IPA_PATH="$CI_DIR/export/Stack.ipa"
[[ -s "$IPA_PATH" ]] || { echo 'Native IPA missing.' >&2; exit 1; }
xcrun altool --upload-app --type ios --file "$IPA_PATH" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
printf 'Swift native version 0.2.0 build %s uploaded; Apple processing remains to be checked.\n' "$BUILD_NUMBER"
