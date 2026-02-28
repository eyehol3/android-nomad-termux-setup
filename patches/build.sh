#!/usr/bin/env bash
# ============================================================================
# Build nomad-android from source
#
# Clones Nomad, anet, and go-sockaddr, applies patches, and cross-compiles
# a statically linked linux/arm64 binary suitable for Android (Termux/proot).
#
# Requirements: Go 1.23+, git
# ============================================================================
set -euo pipefail

# -- Config ------------------------------------------------------------------
NOMAD_REPO="https://github.com/hashicorp/nomad"
NOMAD_COMMIT="d304b7de5d679f83644b3ea4119fb180dce0036f"

ANET_REPO="https://github.com/wlynxg/anet"
ANET_COMMIT="5501d401a269290292909e6cc75f105571f97cfa"

SOCKADDR_REPO="https://github.com/hashicorp/go-sockaddr"
SOCKADDR_COMMIT="b607e6a5e1054e46c7b94d4db4c9f9ae41062158"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR"
BUILD_DIR="${BUILD_DIR:-/tmp/nomad-android-build}"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/../nomad-android}"

# -- Helpers -----------------------------------------------------------------
log() { echo -e "\n\033[1;34m>>> $*\033[0m"; }

check_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required but not found"; exit 1; }
}

# -- Preflight ---------------------------------------------------------------
check_tool go
check_tool git

GO_VERSION=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1)
log "Using $GO_VERSION"

# -- Clone -------------------------------------------------------------------
log "Setting up build directory: $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Cloning Nomad @ $NOMAD_COMMIT"
git clone --depth 100 "$NOMAD_REPO" "$BUILD_DIR/nomad"
cd "$BUILD_DIR/nomad"
git checkout "$NOMAD_COMMIT" 2>/dev/null || {
  git fetch --depth 500 origin
  git checkout "$NOMAD_COMMIT"
}

log "Cloning anet @ $ANET_COMMIT"
git clone --depth 50 "$ANET_REPO" "$BUILD_DIR/nomad/anet"
cd "$BUILD_DIR/nomad/anet"
git checkout "$ANET_COMMIT"

log "Cloning go-sockaddr @ $SOCKADDR_COMMIT"
git clone --depth 50 "$SOCKADDR_REPO" "$BUILD_DIR/nomad/go-sockaddr"
cd "$BUILD_DIR/nomad/go-sockaddr"
git checkout "$SOCKADDR_COMMIT"

# -- Apply patches -----------------------------------------------------------
log "Applying patch: 01-nomad-anet.patch (Nomad: use anet instead of net)"
cd "$BUILD_DIR/nomad"
git apply "$PATCHES_DIR/01-nomad-anet.patch"

log "Applying patch: 02-go-sockaddr-anet.patch (go-sockaddr: use anet)"
cd "$BUILD_DIR/nomad/go-sockaddr"
git apply "$PATCHES_DIR/02-go-sockaddr-anet.patch"

log "Applying patch: 03-anet-linux-compat.patch (anet: extend to linux builds)"
cd "$BUILD_DIR/nomad/anet"
git apply "$PATCHES_DIR/03-anet-linux-compat.patch"

# -- Tidy --------------------------------------------------------------------
log "Running go mod tidy"
cd "$BUILD_DIR/nomad"
go mod tidy

# -- Build -------------------------------------------------------------------
log "Building nomad-android (linux/arm64)"
cd "$BUILD_DIR/nomad"
GOOS=linux GOARCH=arm64 go build \
  -ldflags "-checklinkname=0" \
  -o "$OUTPUT" \
  .

# -- Verify ------------------------------------------------------------------
log "Build complete!"
ls -lh "$OUTPUT"
file "$OUTPUT"

echo ""
echo "Binary: $OUTPUT"
echo "Copy to phone: scp $OUTPUT phoneserver:files/"
