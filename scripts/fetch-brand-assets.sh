#!/usr/bin/env bash
# Downloads the SL_Proxy brand images and generates the asset catalog entries:
#   SL_Proxy/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  opaque 1024x1024 app icon
#   SL_Proxy/Assets.xcassets/Logo.imageset/logo.png                in-app logo (transparency kept)
#
#   APP_ICON_URL      source image for the app icon
#   IN_APP_LOGO_URL   source image for the in-app logo
#   ICON_BACKGROUND   hex colour placed behind transparent icon pixels (default 0F1014)
#   ICON_INSET        fraction of the icon canvas the artwork may occupy (default 1.0: the icon
#                     artwork is a full-bleed square, so it fills the whole canvas)
#   FORCE_ASSETS=1    regenerate even if the files already exist
#
# Download failures are non-fatal: the app falls back to the SL_Proxy wordmark.
set -uo pipefail

APP_ICON_URL="${APP_ICON_URL:-https://sailorsloot.xyz/wp-content/uploads/2026/11/4DEDB0B3-C5C8-4E16-A185-7ECECF16517A.jpg}"
IN_APP_LOGO_URL="${IN_APP_LOGO_URL:-https://sailorsloot.xyz/wp-content/uploads/2026/07/cropped-Untitled-design-4.png}"
ICON_BACKGROUND="${ICON_BACKGROUND:-0F1014}"
ICON_INSET="${ICON_INSET:-1.0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO_ROOT/SL_Proxy/Assets.xcassets"
ICONSET="$ASSETS/AppIcon.appiconset"
LOGOSET="$ASSETS/Logo.imageset"
ICON_OUT="$ICONSET/AppIcon-1024.png"
LOGO_OUT="$LOGOSET/logo.png"

if [ -f "$ICON_OUT" ] && [ -f "$LOGO_OUT" ] && [ "${FORCE_ASSETS:-0}" != "1" ]; then
  echo "Brand assets already present (set FORCE_ASSETS=1 to refresh)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$ICONSET" "$LOGOSET"

download() {
  curl -fsSL --retry 3 --connect-timeout 15 -A "SL_Proxy-build" "$1" -o "$2"
}

# --- App icon ---------------------------------------------------------------
if download "$APP_ICON_URL" "$WORK/icon-src.png"; then
  if swift "$REPO_ROOT/scripts/flatten-icon.swift" "$WORK/icon-src.png" "$ICON_OUT" 1024 "$ICON_BACKGROUND" "$ICON_INSET"; then
    echo "App icon written to $ICON_OUT"
  else
    echo "flatten-icon.swift failed, falling back to sips"
    sips -s format png -Z 1024 -p 1024 1024 --padColor "$ICON_BACKGROUND" "$WORK/icon-src.png" --out "$WORK/icon-padded.png" >/dev/null \
      && sips -s format jpeg "$WORK/icon-padded.png" --out "$WORK/icon.jpg" >/dev/null \
      && sips -s format png "$WORK/icon.jpg" --out "$ICON_OUT" >/dev/null \
      && echo "App icon written to $ICON_OUT (sips)"
  fi
  if [ -f "$ICON_OUT" ]; then
    cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  fi
else
  echo "warning: could not download the app icon from $APP_ICON_URL"
fi

# --- In-app logo ------------------------------------------------------------
if download "$IN_APP_LOGO_URL" "$WORK/logo-src.png"; then
  # Keep transparency; cap the longest edge so the bundle stays small.
  if sips -s format png -Z 1200 "$WORK/logo-src.png" --out "$LOGO_OUT" >/dev/null; then
    echo "In-app logo written to $LOGO_OUT"
  else
    cp "$WORK/logo-src.png" "$LOGO_OUT" && echo "In-app logo copied to $LOGO_OUT"
  fi
else
  echo "warning: could not download the in-app logo from $IN_APP_LOGO_URL"
fi

exit 0
