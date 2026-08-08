#!/bin/sh

set -eu

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
device_id="${BUDDY_DEVICE_ID:-00008150-0002449C0E04401C}"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/buddy-device-build.XXXXXX")"
build_log="$derived_data/xcodebuild.log"

cleanup() {
  rm -rf "$derived_data"
}
trap cleanup EXIT HUP INT TERM

expected_client_id="$(awk -F ' = ' '$1 == "BUDDY_GITHUB_CLIENT_ID" { value = $2 } END { print value }' Config/Shared.xcconfig)"
expected_client_secret="$(awk -F ' = ' '$1 == "BUDDY_GITHUB_CLIENT_SECRET" { value = $2 } END { print value }' Config/Shared.xcconfig)"

if [ -z "$expected_client_id" ] || [ -z "$expected_client_secret" ]; then
  echo "Buddy's source-controlled GitHub OAuth configuration is incomplete." >&2
  exit 1
fi

if ! DEVELOPER_DIR="$developer_dir" xcodebuild build \
  -project Buddy.xcodeproj \
  -scheme Buddy \
  -configuration Release \
  -destination "platform=iOS,id=$device_id" \
  -derivedDataPath "$derived_data" \
  > "$build_log" 2>&1; then
  cat "$build_log" >&2
  echo "Buddy device build failed." >&2
  exit 1
fi

app_path="$derived_data/Build/Products/Release-iphoneos/Buddy.app"
info_plist="$app_path/Info.plist"
configured_client_id="$(/usr/libexec/PlistBuddy -c 'Print :BuddyGitHubClientID' "$info_plist")"
configured_client_secret="$(/usr/libexec/PlistBuddy -c 'Print :BuddyGitHubClientSecret' "$info_plist")"

if [ "$configured_client_id" != "$expected_client_id" ] ||
   [ "$configured_client_secret" != "$expected_client_secret" ]; then
  echo "Refusing to install: the signed app does not contain Buddy's expected GitHub OAuth configuration." >&2
  exit 1
fi

unset expected_client_secret configured_client_secret

DEVELOPER_DIR="$developer_dir" xcrun devicectl device install app \
  --device "$device_id" \
  "$app_path"
DEVELOPER_DIR="$developer_dir" xcrun devicectl device process launch \
  --device "$device_id" \
  --timeout 15 \
  com.hemsoft.buddy
