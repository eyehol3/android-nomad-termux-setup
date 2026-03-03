#!/bin/bash
# setup-cluster.sh — Deploy Nomad configs to phones and restart the cluster.
# Run from your Mac.
#
# Prerequisites:
#   - Both phones ran setup.sh and have Nomad installed in proot
#   - SSH access via port 8022 (ssh -p 8022 phoneserver)
#   - phoneserver / phoneserver2 in your Mac's /etc/hosts
#
# Usage:
#   bash setup-cluster.sh                       # configs + restart
#   bash setup-cluster.sh --deploy-binary       # also SCP the nomad-android binary
#   PHONE1=myphone1 PHONE2=myphone2 bash setup-cluster.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
PHONE1="${PHONE1:-phoneserver}"
PHONE2="${PHONE2:-phoneserver2}"
DEPLOY_BINARY=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --deploy-binary) DEPLOY_BINARY=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# Proot rootfs paths (on-device)
PROOT_ROOT="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/debian"
PROOT_CONF="$PROOT_ROOT/etc/nomad.d/nomad.hcl"
PROOT_BIN="$PROOT_ROOT/usr/local/bin/nomad-android"
TERMUX_HOME="/data/data/com.termux/files/home"

# Health-check tuning
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"   # seconds
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"   # seconds between polls

log()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
err()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helper: run a single command on a phone (no heredocs, no stdin piping)
# ---------------------------------------------------------------------------
phone_exec() {
  local host="$1"; shift
  ssh -p "$SSH_PORT" -o ConnectTimeout=10 "$host" "$@"
}

# ---------------------------------------------------------------------------
# Resolve phone 1 IP (needed for client.hcl on phone 2)
# ---------------------------------------------------------------------------
resolve_ip() {
  local host="$1"
  local ip
  ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}') \
    || ip=$(awk -v h="$host" '$0 !~ /^#/ && $0 ~ h {print $1; exit}' /etc/hosts 2>/dev/null) \
    || ip=$(dig +short "$host" 2>/dev/null | head -1) \
    || true
  [[ -n "$ip" ]] || err "Cannot resolve IP for $host. Add it to /etc/hosts or set PHONE1_IP."
  echo "$ip"
}

# ---------------------------------------------------------------------------
# Verify the installed binary is the patched build
# ---------------------------------------------------------------------------
verify_binary() {
  local host="$1"
  log "Verifying patched binary on $host..."
  if phone_exec "$host" "grep -q nomad-probe $PROOT_BIN"; then
    ok "Binary contains nomad-probe marker (patched)"
  else
    err "Binary on $host is NOT patched (nomad-probe marker missing).
  Rebuild with build.sh and re-run with --deploy-binary."
  fi
}

# ---------------------------------------------------------------------------
# Deploy binary to a phone (optional, gated by --deploy-binary)
# ---------------------------------------------------------------------------
deploy_binary() {
  local host="$1"
  local local_binary="$SCRIPT_DIR/../nomad-android"
  [[ -f "$local_binary" ]] || local_binary="$SCRIPT_DIR/../../nomad-android"
  [[ -f "$local_binary" ]] || err "Cannot find nomad-android binary to deploy. Build it first with build.sh."

  local size
  size=$(wc -c < "$local_binary" | tr -d ' ')
  [[ "$size" -gt 1000000 ]] || err "nomad-android is only ${size} bytes — looks like a git-lfs pointer, not the real binary."

  log "Deploying nomad-android (${size} bytes) to $host..."
  scp -q -P "$SSH_PORT" "$local_binary" "$host:$PROOT_BIN"
  phone_exec "$host" "chmod +x $PROOT_BIN"
  ok "Binary deployed"
}

# ---------------------------------------------------------------------------
# Deploy config file to a phone
# ---------------------------------------------------------------------------
deploy_config() {
  local host="$1" config_file="$2" label="${3:-$(basename "$config_file")}"
  log "Deploying $label to $host..."
  scp -q -P "$SSH_PORT" "$config_file" "$host:$PROOT_CONF"
  ok "Config deployed"
}

# ---------------------------------------------------------------------------
# SCP the start script to a phone and start Nomad
# ---------------------------------------------------------------------------
deploy_and_start() {
  local host="$1"
  local remote_script="$TERMUX_HOME/nomad-start-remote.sh"

  log "Deploying nomad-start-remote.sh to $host..."
  scp -q -P "$SSH_PORT" "$SCRIPT_DIR/nomad-start-remote.sh" "$host:$remote_script"
  phone_exec "$host" "chmod +x $remote_script"
  ok "Start script deployed"

  log "Starting Nomad on $host..."
  phone_exec "$host" "bash $remote_script"
}

# ---------------------------------------------------------------------------
# Poll until Nomad API is healthy (retry loop, no sleep-and-hope)
# ---------------------------------------------------------------------------
wait_for_health() {
  local addr="$1" label="$2"
  local deadline=$((SECONDS + HEALTH_TIMEOUT))

  log "Waiting for Nomad at $addr (timeout ${HEALTH_TIMEOUT}s)..."
  while (( SECONDS < deadline )); do
    if curl -sf "${addr}/v1/agent/health" > /dev/null 2>&1; then
      ok "$label is healthy"
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  err "$label did not become healthy within ${HEALTH_TIMEOUT}s.
  Check logs: ssh -p $SSH_PORT <phone> 'tail -50 ~/nomad.log'"
}

# ---------------------------------------------------------------------------
# Wait for expected number of nodes in the cluster
# ---------------------------------------------------------------------------
wait_for_nodes() {
  local expected="$1"
  local deadline=$((SECONDS + HEALTH_TIMEOUT))

  log "Waiting for $expected node(s) to be ready..."
  while (( SECONDS < deadline )); do
    local count
    count=$(nomad node status 2>/dev/null | grep -c 'ready' || true)
    if [[ "$count" -ge "$expected" ]]; then
      ok "$count node(s) ready"
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  warn "Only saw $count/$expected nodes ready after ${HEALTH_TIMEOUT}s"
  nomad node status 2>/dev/null || true
}

# ===========================================================================
# Main
# ===========================================================================

PHONE1_IP="${PHONE1_IP:-$(resolve_ip "$PHONE1")}"
log "Phone 1 ($PHONE1) IP: $PHONE1_IP"

# --- Check SSH connectivity ---
log "Checking SSH connectivity..."
phone_exec "$PHONE1" "echo ok" > /dev/null || err "Cannot SSH to $PHONE1"
ok "$PHONE1 reachable"
phone_exec "$PHONE2" "echo ok" > /dev/null || err "Cannot SSH to $PHONE2"
ok "$PHONE2 reachable"

# --- Optionally deploy binary ---
if $DEPLOY_BINARY; then
  deploy_binary "$PHONE1"
  deploy_binary "$PHONE2"
fi

# --- Verify binary is patched (on both phones) ---
verify_binary "$PHONE1"
verify_binary "$PHONE2"

# --- Ensure phoneserver hostname resolves inside proot on both phones ---
log "Configuring proot /etc/hosts..."
PROOT_HOSTS="$PROOT_ROOT/etc/hosts"
for phone in "$PHONE1" "$PHONE2"; do
  if ! phone_exec "$phone" "grep -q 'phoneserver' $PROOT_HOSTS 2>/dev/null"; then
    phone_exec "$phone" "echo '$PHONE1_IP phoneserver' >> $PROOT_HOSTS"
    ok "$phone: added phoneserver → $PHONE1_IP to proot /etc/hosts"
  else
    ok "$phone: phoneserver already in proot /etc/hosts"
  fi
done

# --- Create artifacts directory on phone1 ---
log "Ensuring artifacts directory on $PHONE1..."
phone_exec "$PHONE1" "mkdir -p /data/data/com.termux/files/home/artifacts"
ok "~/artifacts/ ready on $PHONE1"

# --- Render client.hcl with actual IP ---
CLIENT_HCL_RENDERED=$(mktemp)
sed "s/PHONESERVER_IP/$PHONE1_IP/g" "$SCRIPT_DIR/client.hcl" > "$CLIENT_HCL_RENDERED"
trap "rm -f $CLIENT_HCL_RENDERED" EXIT

# ===================== Phone 1: server + client ============================
log "Setting up $PHONE1 (server + client)"
deploy_config "$PHONE1" "$SCRIPT_DIR/server.hcl"
deploy_and_start "$PHONE1"

# Poll until phone1 API is up before starting phone2
export NOMAD_ADDR="http://${PHONE1}:4646"
wait_for_health "$NOMAD_ADDR" "$PHONE1"

# ===================== Phone 2: client only ================================
log "Setting up $PHONE2 (client)"
deploy_config "$PHONE2" "$CLIENT_HCL_RENDERED" "client.hcl"
deploy_and_start "$PHONE2"

# ===================== Verify cluster ======================================
wait_for_nodes 2

log "Cluster status"
nomad node status
echo ""
echo "  Dashboard: $NOMAD_ADDR"

echo ""
log "Done! Next: bash deploy-jobs.sh"
