#!/bin/bash
# nomad-deploy.sh — Build app artifacts via Docker and deploy to the Nomad cluster.
# Run from your Mac.
#
# Usage:
#   ./nomad-deploy.sh --app ytsumm-bot                    # Build & deploy (reads nomad-deploy.conf)
#   ./nomad-deploy.sh --app ytsumm-bot --src ~/my/path    # Override source path
#   ./nomad-deploy.sh --all                                # Build & deploy all apps
#   ./nomad-deploy.sh --app ytsumm-bot --build-only        # Build tarball only, no upload/restart
#   ./nomad-deploy.sh --app ytsumm-bot --platform linux/amd64  # Override platform
#
# Requires:
#   - Docker (with arm64 support — native on Apple Silicon)
#   - SSH access to phone1 (port 8022)
#   - Nomad CLI (brew install nomad)
#   - nomad-deploy.conf alongside this script (for --all or config-based deploys)
#   - A build.sh in each project's source directory (see below)
#
# Each project must provide its own build.sh:
#   Contract: bash build.sh <output-dir> <platform>
#   It must produce <output-dir>/<app>-<arch>.tar.gz
#   <arch> is derived from <platform> (e.g. linux/arm64 → arm64).
#   See telegram-youtube-summarizer/build.sh for a reference implementation.
#
# Flow per app:
#   1. Run project's build.sh (Docker cross-compile → tarball with deps)
#   2. SCP tarball to phone1's ~/artifacts/
#   3. nomad job restart -reschedule (forces new alloc → fresh artifact download)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/nomad-deploy.conf"

# ---------------------------------------------------------------------------
# Configuration — edit these or override via environment variables
# ---------------------------------------------------------------------------
SSH_PORT="${SSH_PORT:-8022}"
PHONE1="${PHONE1:-phoneserver}"
ARTIFACT_DIR="/data/data/com.termux/files/home/artifacts"
ARCH_SUFFIX="arm64"
PLATFORM="linux/arm64"

export NOMAD_ADDR="${NOMAD_ADDR:-http://${PHONE1}:4646}"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
APP=""
SRC=""
ALL=false
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)        APP="$2"; shift 2 ;;
    --src)        SRC="$2"; shift 2 ;;
    --platform)   PLATFORM="$2"; shift 2 ;;
    --all)        ALL=true; shift ;;
    --build-only) BUILD_ONLY=true; shift ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)            echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# Derive arch suffix from platform (linux/arm64 → arm64)
ARCH_SUFFIX="${PLATFORM##*/}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
err()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Temp dir for build output (cleaned on exit)
# ---------------------------------------------------------------------------
BUILD_OUT=$(mktemp -d)
trap "rm -rf $BUILD_OUT" EXIT

# ---------------------------------------------------------------------------
# Config file helpers
# ---------------------------------------------------------------------------
get_app_src() {
  local target="$1"
  [[ -f "$CONF" ]] || err "Config file not found: $CONF"
  while read -r name src; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ "$name" == "$target" ]]; then
      echo "${src/#\~/$HOME}"
      return 0
    fi
  done < "$CONF"
  return 1
}

get_all_apps() {
  [[ -f "$CONF" ]] || err "Config file not found: $CONF"
  while read -r name rest; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    echo "$name"
  done < "$CONF"
}

# ---------------------------------------------------------------------------
# Upload tarball to artifact server on phone1
# ---------------------------------------------------------------------------
upload_artifact() {
  local app="$1"
  local tarball="${app}-${ARCH_SUFFIX}.tar.gz"
  [[ -f "$BUILD_OUT/$tarball" ]] || err "Tarball not found: $BUILD_OUT/$tarball"

  log "Uploading $tarball to $PHONE1:$ARTIFACT_DIR/"
  ssh -p "$SSH_PORT" -o ConnectTimeout=10 "$PHONE1" "mkdir -p $ARTIFACT_DIR"
  scp -q -P "$SSH_PORT" "$BUILD_OUT/$tarball" "$PHONE1:$ARTIFACT_DIR/$tarball"
  ok "Uploaded"
}

# ---------------------------------------------------------------------------
# Restart (reschedule) a job so it picks up the new artifact
# ---------------------------------------------------------------------------
restart_job() {
  local app="$1"
  local job_file="$SCRIPT_DIR/jobs/${app}.nomad.hcl"

  # If job isn't registered yet, submit the spec
  if ! nomad job status "$app" > /dev/null 2>&1; then
    if [[ -f "$job_file" ]]; then
      log "Job '$app' not registered — submitting $job_file..."
      nomad job run -detach "$job_file"
      ok "Job registered (allocation will download the artifact)"
    else
      warn "No job spec found at $job_file — skipping"
    fi
    return
  fi

  # Job exists — reschedule to force new alloc with fresh artifact download
  log "Restarting $app (reschedule)..."
  if nomad job restart -reschedule -yes "$app" 2>/dev/null; then
    ok "Job restarted"
  else
    # Might be a periodic job with no running allocs, or other edge case
    warn "Reschedule failed — re-running job spec..."
    if [[ -f "$job_file" ]]; then
      nomad job run -detach "$job_file"
      ok "Job spec re-submitted"
    else
      warn "No job spec found — next allocation will use the new artifact"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Ensure the artifact HTTP server is running on phone1
# ---------------------------------------------------------------------------
ensure_artifact_server() {
  if nomad job status artifact-server > /dev/null 2>&1; then
    # Check if actually serving
    if curl -sf "http://${PHONE1}:8080/" > /dev/null 2>&1; then
      ok "Artifact server is running"
      return
    fi
  fi

  local job_file="$SCRIPT_DIR/jobs/artifact-server.nomad.hcl"
  [[ -f "$job_file" ]] || err "Artifact server job spec not found: $job_file"

  log "Starting artifact server..."
  nomad job run "$job_file"

  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if curl -sf "http://${PHONE1}:8080/" > /dev/null 2>&1; then
      ok "Artifact server is running"
      return
    fi
    sleep 3
  done
  warn "Artifact server may not be ready yet — continuing anyway"
}

# ---------------------------------------------------------------------------
# Deploy one app: build → upload → restart
#
# Each project must have a build.sh in its source directory.
# Contract: bash build.sh <output-dir> <platform>
#   → produces <output-dir>/<app>-<arch>.tar.gz
# ---------------------------------------------------------------------------
deploy_one() {
  local app="$1" src="$2"
  [[ -d "$src" ]] || err "Source directory not found: $src"
  [[ -f "$src/build.sh" ]] || err "No build.sh in $src — each project needs its own build.sh (see header for contract)"

  log "Building $app via project build.sh"
  echo "  Source:   $src"
  echo "  Platform: $PLATFORM"
  bash "$src/build.sh" "$BUILD_OUT" "$PLATFORM"

  if ! $BUILD_ONLY; then
    upload_artifact "$app"
    restart_job "$app"
  fi
}

# ===========================================================================
# Main
# ===========================================================================

if $ALL; then
  log "Deploying all apps from $CONF"
  if ! $BUILD_ONLY; then
    ensure_artifact_server
  fi
  while IFS= read -r app; do
    src=$(get_app_src "$app") || err "No config found for '$app'"
    deploy_one "$app" "$src"
  done < <(get_all_apps)
else
  [[ -n "$APP" ]] || err "Specify --app NAME or --all. See --help for usage."

  # Try config file first, CLI --src overrides
  if [[ -z "$SRC" ]]; then
    SRC=$(get_app_src "$APP" 2>/dev/null) || true
  fi
  [[ -n "$SRC" ]] || err "Specify --src /path/to/source or add '$APP' to $CONF"
  SRC="${SRC/#\~/$HOME}"

  if ! $BUILD_ONLY; then
    ensure_artifact_server
  fi
  deploy_one "$APP" "$SRC"
fi

echo ""
log "Done!"
