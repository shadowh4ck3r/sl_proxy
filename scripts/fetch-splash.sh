#!/usr/bin/env bash
# Downloads the SL_Proxy splash image and writes the "Splash" image set:
#   SL_Proxy/Assets.xcassets/Splash.imageset/splash.png
#
#   SPLASH_URL     source image (default: the Sailorsloot splash on sailorsloot.xyz)
#   FORCE_ASSETS=1 regenerate even if the file already exists
#
# Download failures are non-fatal: SplashView falls back to the brand gradient and logo.
set -uo pipefail

SPLASH_URL="${SPLASH_URL:-https://sailorsloot.xyz/wp-content/uploads/2026/11/3F225F46-B241-4748-8678-E162EA81C2EB.jpg}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETDIR="$REPO_ROOT/SL_Proxy/Assets.xcassets/Splash.imageset"
OUT="$SETDIR/splash.png"

if [ -f "$OUT" ] && [ "${FORCE_ASSETS:-0}" != "1" ]; then
  echo "Splash image already present (set FORCE_ASSETS=1 to refresh)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$SETDIR"

if curl -fsSL --retry 3 --connect-timeout 15 -A "SL_Proxy-build" "$SPLASH_URL" -o "$WORK/splash-src"; then
  # Cap the long edge at 2400 px so the bundle stays small; fall back to a plain copy.
  if sips -s format png -Z 2400 "$WORK/splash-src" --out "$OUT" >/dev/null 2>&1; then
    echo "Splash image written to $OUT"
  else
    cp "$WORK/splash-src" "$OUT" && echo "Splash image copied to $OUT"
  fi
  cat > "$SETDIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "splash.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
else
  echo "warning: could not download the splash image from $SPLASH_URL"
fi

exit 0
