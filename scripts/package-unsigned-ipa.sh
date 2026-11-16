#!/usr/bin/env bash
# Packages the unsigned .xcarchive for sideloading. Produces two IPAs in build/ipa/:
#
#   $IPA_BASENAME-unsigned.ipa  raw, no signature. AltStore / Sideloadly / ESign re-sign it. The
#                               user-space build needs no special entitlement, so a free Apple ID
#                               is enough.
#   $SIGNED_IPA_NAME            ad-hoc signed with Signing/MainApp.entitlements for TrollStore and
#                               TrollStore Lite (jailbroken iOS 17.x), which keep whatever
#                               entitlements the existing signature carries.
#
# If the archive still contains a tunnel extension (system VPN build on `main`) it is signed with
# Signing/PacketTunnel.entitlements and the Network Extension checks run as before.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/SL_Proxy.xcarchive}"
IPA_DIR="${IPA_DIR:-build/ipa}"
APP_NAME="${APP_NAME:-SL_Proxy}"                 # <APP_NAME>.app inside the archive
TUNNEL_NAME="${TUNNEL_NAME:-SL_ProxyTunnel}"     # optional <TUNNEL_NAME>.appex
IPA_BASENAME="${IPA_BASENAME:-$APP_NAME}"        # file name prefix of the produced IPAs
SIGNED_IPA_NAME="${SIGNED_IPA_NAME:-$IPA_BASENAME-trollstore.ipa}"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$ROOT/Signing/MainApp.entitlements}"
TUNNEL_ENTITLEMENTS="${TUNNEL_ENTITLEMENTS:-$ROOT/Signing/PacketTunnel.entitlements}"

APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[ -d "$APP" ] || { echo "App bundle not found at $APP"; exit 1; }

mkdir -p "$IPA_DIR"

stage_payload() {
  rm -rf "$IPA_DIR/Payload"
  mkdir -p "$IPA_DIR/Payload"
  cp -R "$APP" "$IPA_DIR/Payload/"
}

package() {
  local name="$1"
  (
    cd "$IPA_DIR"
    rm -f "$name"
    zip -qry "$name" Payload
  )
  echo "Wrote $IPA_DIR/$name"
}

# ---------------------------------------------------------------------------
# 1. Raw unsigned IPA (for tools that re-sign)
# ---------------------------------------------------------------------------
stage_payload
# Re-signers (Impactor, AltStore, Sideloadly) copy every entitlement they find in the existing
# signature, including an App Group, and then try to register "<group>.<TEAMID>" with Apple, which
# fails with "An Application Group with Identifier ... is not available". The raw IPA must carry no
# signature, profile or entitlements at all, so strip whatever the archive left behind.
RAW_APP="$IPA_DIR/Payload/$APP_NAME.app"
find "$RAW_APP" -type d -name "_CodeSignature" -prune -exec rm -rf {} +
find "$RAW_APP" -type f -name "embedded.mobileprovision" -delete
find "$RAW_APP" -type f -name "*.entitlements" -delete
if command -v codesign >/dev/null 2>&1; then
  while IFS= read -r bin; do
    codesign --remove-signature "$bin" 2>/dev/null || true
  done < <(find "$RAW_APP" -type f \( -perm -u+x -o -name "*.dylib" \) )
  while IFS= read -r fw; do
    codesign --remove-signature "$fw" 2>/dev/null || true
  done < <(find "$RAW_APP/Frameworks" -maxdepth 1 -type d -name "*.framework" 2>/dev/null)
  if codesign -d --entitlements :- "$RAW_APP" 2>/dev/null | grep -q "application-groups"; then
    echo "error: the unsigned IPA still carries an App Group entitlement"
    exit 1
  fi
fi
package "$IPA_BASENAME-unsigned.ipa"

# ---------------------------------------------------------------------------
# 2. Ad-hoc signed IPA for TrollStore / TrollStore Lite
# ---------------------------------------------------------------------------
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign not available; skipping $SIGNED_IPA_NAME"
  rm -rf "$IPA_DIR/Payload"
  exit 0
fi
[ -f "$APP_ENTITLEMENTS" ] || { echo "Entitlements file not found: $APP_ENTITLEMENTS"; exit 1; }

stage_payload
PAYLOAD_APP="$IPA_DIR/Payload/$APP_NAME.app"
APPEX="$PAYLOAD_APP/PlugIns/$TUNNEL_NAME.appex"

# Drop anything left over from the archive that could contradict the new entitlements.
find "$PAYLOAD_APP" -type d -name "_CodeSignature" -prune -exec rm -rf {} +
find "$PAYLOAD_APP" -type f -name "embedded.mobileprovision" -delete

sign() {
  codesign --force --sign - --generate-entitlement-der "$@"
}

# Inside-out: embedded frameworks, then the extension (if any), then the app.
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  [ -d "$fw" ] && sign "$fw"
done
if [ -d "$APPEX" ]; then
  [ -f "$TUNNEL_ENTITLEMENTS" ] || { echo "Entitlements file not found: $TUNNEL_ENTITLEMENTS"; exit 1; }
  sign --entitlements "$TUNNEL_ENTITLEMENTS" "$APPEX"
else
  echo "No tunnel extension in the archive (user-space build); signing the app only"
fi
sign --entitlements "$APP_ENTITLEMENTS" "$PAYLOAD_APP"

# ---------------------------------------------------------------------------
# 3. Verify the signatures
# ---------------------------------------------------------------------------
if ! codesign -d --entitlements :- "$PAYLOAD_APP" 2>/dev/null | grep -q "application-identifier"; then
  echo "error: application-identifier missing from the app signature"
  exit 1
fi
echo "Signature OK: $(basename "$PAYLOAD_APP")"

if [ -d "$APPEX" ]; then
  for bundle in "$APPEX" "$PAYLOAD_APP"; do
    if ! codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q "packet-tunnel-provider"; then
      echo "error: packet-tunnel-provider entitlement missing from $bundle"
      exit 1
    fi
  done
  entitlement_group() {
    local tmp
    tmp="$(mktemp)"
    codesign -d --entitlements :- "$1" 2>/dev/null > "$tmp"
    /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$tmp" 2>/dev/null || true
    rm -f "$tmp"
  }
  APP_GROUP="$(entitlement_group "$PAYLOAD_APP")"
  APPEX_GROUP="$(entitlement_group "$APPEX")"
  if [ -z "$APP_GROUP" ] || [ "$APP_GROUP" != "$APPEX_GROUP" ]; then
    echo "error: App Group mismatch: app='${APP_GROUP:-<none>}' tunnel='${APPEX_GROUP:-<none>}'"
    exit 1
  fi
  echo "Entitlements OK: Network Extension + App Group $APP_GROUP in app and tunnel"
fi

package "$SIGNED_IPA_NAME"
rm -rf "$IPA_DIR/Payload"
