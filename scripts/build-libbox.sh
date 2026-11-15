#!/usr/bin/env bash
# Builds Frameworks/Libbox.xcframework (sing-box core for iOS) from a pinned release.
# Requires: Go 1.22+, Xcode command line tools.
#   SINGBOX_VERSION  git tag to build (default v1.11.15)
#   GO_TOOLCHAIN     Go release to use, fetched automatically (default go1.23.10)
#   FORCE_REBUILD=1  rebuild even if the framework already exists
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-v1.11.15}"
export GOTOOLCHAIN="${GO_TOOLCHAIN:-go1.23.10}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Frameworks"
OUT="$OUT_DIR/Libbox.xcframework"

if [ -d "$OUT" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "Libbox.xcframework already present at $OUT (set FORCE_REBUILD=1 to rebuild)"
  exit 0
fi

command -v go >/dev/null 2>&1 || { echo "Go is required (brew install go)"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "Xcode command line tools are required"; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning sing-box $SINGBOX_VERSION"
git clone --quiet --depth 1 --branch "$SINGBOX_VERSION" https://github.com/SagerNet/sing-box.git "$WORK_DIR/sing-box"
cd "$WORK_DIR/sing-box"

# sing-box's cmd/internal/build_libbox does not search PATH: it requires $GOPATH/bin/gomobile.
# `go install` writes to $GOBIN (if the runner image sets one) or to the first GOPATH entry, so
# pin both to the same single directory before installing the toolchain.
export GOPATH="${GOPATH:-$(go env GOPATH)}"
export GOPATH="${GOPATH%%:*}"
export GOBIN="$GOPATH/bin"
export PATH="$PATH:$GOBIN"
mkdir -p "$GOBIN"
echo "Using $(go version) (GOTOOLCHAIN=$GOTOOLCHAIN, GOPATH=$GOPATH, GOBIN=$GOBIN)"

echo "Installing gomobile toolchain"
make lib_install
for tool in gomobile gobind; do
  if [ ! -x "$GOBIN/$tool" ]; then
    echo "error: $tool was not installed to $GOBIN, which is where build_libbox looks for it"
    echo "--- go env"
    go env GOPATH GOBIN GOROOT GOTOOLCHAIN
    echo "--- $GOBIN"
    ls -la "$GOBIN" || true
    echo "--- PATH lookup"
    command -v "$tool" || echo "$tool not on PATH either"
    exit 1
  fi
done
echo "gomobile toolchain ready in $GOBIN"

echo "Building Libbox for iOS"
# Newer releases use `-target apple -platform ios`; older ones use `-target ios`.
if ! go run ./cmd/internal/build_libbox -target apple -platform ios; then
  echo "Falling back to legacy build flags"
  go run ./cmd/internal/build_libbox -target ios
fi

[ -d Libbox.xcframework ] || { echo "Libbox.xcframework was not produced"; exit 1; }

mkdir -p "$OUT_DIR"
rm -rf "$OUT"
mv Libbox.xcframework "$OUT"
echo "Libbox.xcframework ready at $OUT"
