#!/usr/bin/env bash
# Installs the Apple signing certificate and provisioning profiles into a temporary
# keychain and renders build/ExportOptions.plist. Source this script so the exported
# PROFILE_*_NAME / CODE_SIGN_IDENTITY_NAME variables are available to xcodebuild.
#
# Required CI variables (masked, base64 where noted):
#   APPLE_CERTIFICATE_P12               base64 of the .p12 distribution certificate
#   APPLE_CERTIFICATE_PASSWORD          password of the .p12
#   APPLE_TEAM_ID                       10-character Apple Team ID
#   APPLE_PROVISIONING_PROFILE_APP      base64 .mobileprovision for com.slproxy.app
#   APPLE_PROVISIONING_PROFILE_TUNNEL   base64 .mobileprovision for com.slproxy.app.tunnel
# Optional:
#   APPLE_EXPORT_METHOD        release-testing (default) | debugging | app-store-connect
#   APPLE_CODE_SIGN_IDENTITY   "Apple Distribution" (default) | "Apple Development"
set -euo pipefail

: "${APPLE_CERTIFICATE_P12:?APPLE_CERTIFICATE_P12 is required}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_PROVISIONING_PROFILE_APP:?APPLE_PROVISIONING_PROFILE_APP is required}"
: "${APPLE_PROVISIONING_PROFILE_TUNNEL:?APPLE_PROVISIONING_PROFILE_TUNNEL is required}"

EXPORT_METHOD="${APPLE_EXPORT_METHOD:-release-testing}"
SIGN_IDENTITY="${APPLE_CODE_SIGN_IDENTITY:-Apple Distribution}"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/slproxy-ci.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"

echo "Creating temporary keychain"
echo "$APPLE_CERTIFICATE_P12" | base64 --decode > "$WORK/cert.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
rm -f "$WORK/cert.p12"

PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"

# install_profile <base64> <label> -> prints the profile Name
install_profile() {
  local b64="$1" label="$2"
  local path="$WORK/$label.mobileprovision"
  echo "$b64" | base64 --decode > "$path"
  local plist uuid name
  plist="$(security cms -D -i "$path")"
  uuid="$(printf '%s' "$plist" | plutil -extract UUID raw -o - -)"
  name="$(printf '%s' "$plist" | plutil -extract Name raw -o - -)"
  cp "$path" "$PROFILES_DIR/$uuid.mobileprovision"
  printf '%s' "$name"
}

PROFILE_APP_NAME="$(install_profile "$APPLE_PROVISIONING_PROFILE_APP" app)"
PROFILE_TUNNEL_NAME="$(install_profile "$APPLE_PROVISIONING_PROFILE_TUNNEL" tunnel)"
export PROFILE_APP_NAME PROFILE_TUNNEL_NAME
export CODE_SIGN_IDENTITY_NAME="$SIGN_IDENTITY"

mkdir -p build
sed -e "s|__EXPORT_METHOD__|$EXPORT_METHOD|" \
    -e "s|__TEAM_ID__|$APPLE_TEAM_ID|" \
    -e "s|__SIGN_IDENTITY__|$SIGN_IDENTITY|" \
    -e "s|__PROFILE_APP__|$PROFILE_APP_NAME|" \
    -e "s|__PROFILE_TUNNEL__|$PROFILE_TUNNEL_NAME|" \
    ExportOptions.plist > build/ExportOptions.plist

echo "Signing ready: team=$APPLE_TEAM_ID identity='$SIGN_IDENTITY' app='$PROFILE_APP_NAME' tunnel='$PROFILE_TUNNEL_NAME' method=$EXPORT_METHOD"
