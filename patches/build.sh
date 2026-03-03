#!/usr/bin/env bash
# ============================================================================
# Build nomad-android from source
#
# Clones Nomad, anet, and go-sockaddr, applies patches, and cross-compiles
# a statically linked linux/arm64 binary suitable for Android (Termux/proot).
#
# Requirements: Go 1.23+, git
# For UI:       Node.js 20+, pnpm 10+
#
# Set NO_UI=1 to skip the UI build and produce a smaller binary.
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

log "Applying patch: 04-nomad-skip-cgroups.patch (Nomad: skip cgroups in proot)"
cd "$BUILD_DIR/nomad"
git apply "$PATCHES_DIR/04-nomad-skip-cgroups.patch"

log "Applying patch: 05-nomad-mount-fallback.patch (Nomad: fallback when mount fails)"
cd "$BUILD_DIR/nomad"
git apply "$PATCHES_DIR/05-nomad-mount-fallback.patch"

log "Applying patch: 06-nomad-executor-cgroups.patch (Nomad: executor skip cgroups when OFF)"
cd "$BUILD_DIR/nomad"
git apply "$PATCHES_DIR/06-nomad-executor-cgroups.patch"

# -- Tidy --------------------------------------------------------------------
log "Running go mod tidy"
cd "$BUILD_DIR/nomad"
go mod tidy

# -- UI (optional) -----------------------------------------------------------
GO_BUILD_TAGS=""
if [ "${NO_UI:-}" = "1" ]; then
  log "Skipping UI build (NO_UI=1)"
elif [ -f "$BUILD_DIR/nomad/command/agent/bindata_assetfs.go" ]; then
  # The upstream commit already ships pre-generated bindata — just use it
  log "Using pre-generated UI assets from upstream commit"
  GO_BUILD_TAGS="-tags ui"
else
  # Need to build the Ember UI from scratch and generate bindata
  check_tool node
  check_tool pnpm

  NODE_VERSION=$(node --version)
  log "Building Nomad UI (Node $NODE_VERSION)"

  log "Installing JS dependencies"
  cd "$BUILD_DIR/nomad"
  pnpm install --frozen-lockfile=false --fetch-timeout 300000

  log "Building Ember application"
  pnpm -F nomad-ui build

  log "Installing go-bindata-assetfs tool"
  go install github.com/hashicorp/go-bindata/go-bindata@bf7910af899725e4938903fb32048c7c0b15f12e
  go install github.com/elazarl/go-bindata-assetfs/go-bindata-assetfs@234c15e7648ff35458026de92b34c637bae5e6f7

  log "Generating static asset bindings"
  cd "$BUILD_DIR/nomad"
  go-bindata-assetfs -pkg agent -prefix ui -modtime 1480000000 -tags ui -o bindata_assetfs.go ./ui/dist/...
  mv bindata_assetfs.go command/agent/

  GO_BUILD_TAGS="-tags ui"
  log "UI assets embedded successfully"
fi

# -- Build -------------------------------------------------------------------
log "Building nomad-android (linux/arm64)"
cd "$BUILD_DIR/nomad"
GOOS=linux GOARCH=arm64 go build \
  -ldflags "-checklinkname=0" \
  $GO_BUILD_TAGS \
  -o "$OUTPUT" \
  .

# -- Verify ------------------------------------------------------------------
log "Build complete!"
ls -lh "$OUTPUT"
file "$OUTPUT"

echo ""
echo "Binary: $OUTPUT"
echo "Copy to phone: scp $OUTPUT phoneserver:files/"
