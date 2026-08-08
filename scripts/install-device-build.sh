#!/bin/sh

set -eu

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
device_id="${BUDDY_DEVICE_ID:-00008150-0002449C0E04401C}"
keychain_service="${BUDDY_OAUTH_KEYCHAIN_SERVICE:-com.hemsoft.buddy.oauth}"
keychain_account="${BUDDY_OAUTH_KEYCHAIN_ACCOUNT:-github-oauth-client-secret}"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/buddy-device-build.XXXXXX")"
build_config="$derived_data/BuddyDeploy.xcconfig"
build_log="$derived_data/xcodebuild.log"

cleanup() {
  rm -rf "$derived_data"
}
trap cleanup EXIT HUP INT TERM

client_secret="$(security find-generic-password \
  -s "$keychain_service" \
  -a "$keychain_account" \
  -w 2>/dev/null)" || {
  echo "Buddy GitHub OAuth credential is missing from the login Keychain." >&2
  exit 1
}

if [ "${#client_secret}" -lt 20 ]; then
  echo "Buddy GitHub OAuth credential is unexpectedly short." >&2
  exit 1
fi

case "$client_secret" in
  *[!A-Za-z0-9_]*)
    echo "Buddy GitHub OAuth credential contains unsupported characters." >&2
    exit 1
    ;;
esac

umask 077
printf 'BUDDY_GITHUB_CLIENT_SECRET = %s\n' "$client_secret" > "$build_config"

if ! DEVELOPER_DIR="$developer_dir" xcodebuild build \
  -project Buddy.xcodeproj \
  -scheme Buddy \
  -configuration Release \
  -destination "platform=iOS,id=$device_id" \
  -derivedDataPath "$derived_data" \
  -xcconfig "$build_config" \
  > "$build_log" 2>&1; then
  echo "Buddy device build failed; build output was suppressed to protect OAuth configuration." >&2
  exit 1
fi

app_path="$derived_data/Build/Products/Release-iphoneos/Buddy.app"
info_plist="$app_path/Info.plist"
configured_client_id="$(/usr/libexec/PlistBuddy -c 'Print :BuddyGitHubClientID' "$info_plist")"
configured_client_secret="$(/usr/libexec/PlistBuddy -c 'Print :BuddyGitHubClientSecret' "$info_plist")"

if [ -z "$configured_client_id" ] || [ -z "$configured_client_secret" ]; then
  echo "Refusing to install: the signed app has incomplete GitHub OAuth configuration." >&2
  exit 1
fi

if [ "$configured_client_secret" != "$client_secret" ]; then
  echo "Refusing to install: the signed app does not contain the expected OAuth credential." >&2
  exit 1
fi

unset client_secret configured_client_secret

DEVELOPER_DIR="$developer_dir" xcrun devicectl device install app \
  --device "$device_id" \
  "$app_path"
DEVELOPER_DIR="$developer_dir" xcrun devicectl device process launch \
  --device "$device_id" \
  com.hemsoft.buddy
