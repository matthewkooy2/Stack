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
# Fail closed before tests/archive; the workflow restores approved assets first.
python3 scripts/ci/ios-signing.py export-options "$CI_DIR/ExportOptions.plist"
SIGNING=(DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$IOS_SIGNING_IDENTITY" PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_UUID"
  "OTHER_CODE_SIGN_FLAGS=--keychain $IOS_SIGNING_KEYCHAIN")
# Revalidate GitHub-owned evidence for direct invocations as well as the workflow.
python3 scripts/ci/ios-native-proof.py release-upload
python3 scripts/ci/resume-review/prepare.py
(cd ios && xcodegen generate --spec project.yml --project .)
xcodebuild archive -project ios/Stack.xcodeproj -scheme Stack -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$CI_DIR/DerivedData" "${SIGNING[@]}" \
  PRODUCT_BUNDLE_IDENTIFIER=com.matthewkooy.stack MARKETING_VERSION=0.2.0 \
  STACK_APPLE_SIGN_IN_ENABLED=YES STACK_APPLE_ENTITLEMENTS=Stack/StackApple.entitlements \
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" "STACK_API_URL=$STACK_API_URL"
python3 - "$APP/Info.plist" "$BUILD_NUMBER" "$STACK_API_URL" <<'PY'
import plistlib, sys
from urllib.parse import urlsplit
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
expected = {'CFBundleIdentifier': 'com.matthewkooy.stack', 'CFBundleShortVersionString': '0.2.0',
            'CFBundleVersion': sys.argv[2], 'StackAPIBaseURL': sys.argv[3]}
mismatched = [key for key, value in expected.items() if info.get(key) != value]
if mismatched:
    raise SystemExit('Native archive configuration does not match this run: ' + ', '.join(mismatched))
if info.get('ITSAppUsesNonExemptEncryption') is not False:
    raise SystemExit('Native archive must declare non-exempt encryption as Boolean false.')
origin = urlsplit(sys.argv[3])
if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password:
    raise SystemExit('Native release requires an HTTPS API origin without credentials.')
if info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'):
    raise SystemExit('Native release must not allow arbitrary network loads.')
print('Native archive identity, version, HTTPS origin and export compliance validated.')
PY
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$CI_DIR/export" \
  -exportOptionsPlist "$CI_DIR/ExportOptions.plist"
IPA_PATH="$CI_DIR/export/Stack.ipa"
[[ -s "$IPA_PATH" ]] || { echo 'Native IPA missing.' >&2; exit 1; }
xcrun altool --upload-app --type ios --file "$IPA_PATH" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
printf 'Swift native version 0.2.0 build %s uploaded; Apple processing remains to be checked.\n' "$BUILD_NUMBER"
