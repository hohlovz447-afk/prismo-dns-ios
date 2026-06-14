#!/usr/bin/env bash
set -euo pipefail

# Builds Singbox.xcframework from the singbox/ Go module via gomobile bind.
# This powers the app's "Speed" mode (regular VLESS servers through sing-box).
#
# Mirrors build-xcframework.sh (the Prismo core) so CI reuses the same
# Go + gomobile + Xcode toolchain.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
GO_DIR="$ROOT_DIR/singbox"
OUT_DIR="$APPLE_DIR/Frameworks"
OUT="$OUT_DIR/Singbox.xcframework"

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
  echo "Xcode iOS SDK is not ready (run xcode-select / accept license)." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT"

cd "$GO_DIR"
# tools.go (build tag `tools`) pins golang.org/x/mobile so `go mod tidy`
# keeps it in the graph for `gomobile bind`.
go mod tidy
go mod download

# sing-box uses build tags to gate protocol support. Enable the ones we need
# (vless/reality/utls, grpc, websocket). `with_gvisor` provides the tun stack
# used later by the Network Extension.
gomobile bind \
  -target=ios,iossimulator \
  -tags="with_gvisor,with_quic,with_utls,with_grpc,with_wireguard" \
  -ldflags="-checklinkname=0 -s -w" \
  -o "$OUT" \
  ./mobile

echo "Built $OUT"
