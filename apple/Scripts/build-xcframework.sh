#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
GO_DIR="$ROOT_DIR/engine"
OUT_DIR="$APPLE_DIR/Frameworks"
OUT="$OUT_DIR/Mobile.xcframework"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required (>= 1.25). Install with: brew install go" >&2
  exit 1
fi

if ! command -v gomobile >/dev/null 2>&1; then
  echo "gomobile not found. Install with:" >&2
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest" >&2
  echo "  gomobile init" >&2
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  cat <<'MSG' >&2
Xcode iOS SDK is not ready.

If Xcode is installed, finish the first-run setup from Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun this script.
MSG
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT"

cd "$GO_DIR"
go mod download

gomobile bind \
  -target=ios,iossimulator \
  -ldflags="-checklinkname=0" \
  -o "$OUT" \
  ./mobile

echo "Built $OUT"
