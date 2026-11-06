#!/usr/bin/env bash
# Build a simulator copy of the iPhone app for Appetize.io, so people can try Stack in a browser
# (for example from a QR code in a presentation) without installing anything.
#
#   STACK_API_URL=https://your-stack-api bash scripts/appetize-build.sh
#
# Writes .jac/appetize/Stack-appetize.zip. Upload it at https://appetize.io/upload, or with their API.
# The URL must be a public HTTPS backend: Appetize's simulators cannot reach 127.0.0.1 or plain HTTP.
set -euo pipefail
cd "$(dirname "$0")/.."

url=${STACK_API_URL:-}
[[ "$url" == https://* ]] || { echo 'Set STACK_API_URL to the public HTTPS backend, for example STACK_API_URL=https://stack.example.com' >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo 'xcodebuild is not installed (install Xcode 15.4 or newer).' >&2; exit 3; }
command -v xcodegen >/dev/null || { echo 'xcodegen is not installed (brew install xcodegen).' >&2; exit 3; }

out=.jac/appetize
derived=$out/DerivedData
rm -rf "$out/Stack-appetize.zip" "$out/Stack.app"
mkdir -p "$out"

python3 scripts/ci/resume-review/prepare.py
(cd ios && STACK_API_URL="$url" xcodegen generate --spec project.yml --project .)

# Release, both simulator architectures, ad hoc signed: Appetize runs on Intel and Apple silicon hosts.
xcodebuild build \
  -project ios/Stack.xcodeproj \
  -scheme Stack \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  "STACK_API_URL=$url" \
  STACK_APPLE_SIGN_IN_ENABLED=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO

app=$derived/Build/Products/Release-iphonesimulator/Stack.app
baked=$(/usr/libexec/PlistBuddy -c 'Print :StackAPIBaseURL' "$app/Info.plist")
[[ "$baked" == "$url" ]] || { echo "Built app points at '$baked', not '$url'." >&2; exit 1; }

cp -R "$app" "$out/Stack.app"
(cd "$out" && ditto -c -k --sequesterRsrc --keepParent Stack.app Stack-appetize.zip)
rm -rf "$out/Stack.app"
echo "Wrote $out/Stack-appetize.zip ($(du -h "$out/Stack-appetize.zip" | cut -f1)), backend $url"
