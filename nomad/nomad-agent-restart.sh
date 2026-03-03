#!/bin/bash
# nomad-agent-restart.sh — Restart Nomad agents on Android phones.
# Run from your Mac.
#
# Restarts the Nomad agent process so it picks up config changes
# (e.g. artifact limits, plugin settings). Jobs are rescheduled
# automatically by the server after the node rejoins.
#
# Usage:
#   bash nomad-agent-restart.sh                   # restart both phones
#   bash nomad-agent-restart.sh --node phoneserver2   # restart one phone
#   bash nomad-agent-restart.sh --drain            # drain before restart
#
# Requires:
#   - SSH access to phones (port 8022)
#   - nomad-start-remote.sh already deployed (via setup-cluster.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
PHONE1="${PHONE1:-phoneserver}"
PHONE2="${PHONE2:-phoneserver2}"
TARGET=""
DRAIN=false

export NOMAD_ADDR="${NOMAD_ADDR:-http://${PHONE1}:4646}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)  TARGET="$2"; shift 2 ;;
    --drain) DRAIN=true; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

log()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
err()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

phone_exec() {
  local host="$1"; shift
  ssh -p "$SSH_PORT" -o ConnectTimeout=10 "$host" "$@"
}

# ---------------------------------------------------------------------------
# Look up Nomad node ID by hostname (for drain)
# ---------------------------------------------------------------------------
get_node_id() {
  local name="$1"
  nomad node status 2>/dev/null | awk -v n="$name" '$4 == n {print $1; exit}'
}

# ---------------------------------------------------------------------------
# Drain a node (wait for allocs to migrate) before restarting
# ---------------------------------------------------------------------------
drain_node() {
  local host="$1"
  local node_id
  node_id=$(get_node_id "$host")
  if [[ -z "$node_id" ]]; then
    warn "Could not find node ID for $host — skipping drain"
    return
  fi

  log "Draining $host ($node_id)..."
  if nomad node drain -enable -yes -detach "$node_id" 2>/dev/null; then
    # Wait for drain to complete (allocs migrated)
    local deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
      local status
      status=$(nomad node status -short "$node_id" 2>/dev/null | grep -c 'true' || true)
      # Check if all allocs have stopped
      local running
      running=$(nomad node status "$node_id" 2>/dev/null \
        | awk '/Allocations/,0' | grep -c 'running' || true)
      if [[ "$running" -eq 0 ]]; then
        ok "Node drained (0 running allocs)"
        return
      fi
      sleep 5
    done
    warn "Drain timed out — proceeding with restart anyway"
  else
    warn "Drain command failed — proceeding with restart anyway"
  fi
}

# ---------------------------------------------------------------------------
# Restart the Nomad agent on a phone via the start script
# ---------------------------------------------------------------------------
restart_agent() {
  local host="$1"
  local start_script="/data/data/com.termux/files/home/nomad-start-remote.sh"

  log "Restarting Nomad agent on $host..."

  # Check that the start script exists
  if ! phone_exec "$host" "test -f $start_script"; then
    # Deploy it first
    log "Start script not found on $host — deploying..."
    scp -q -P "$SSH_PORT" "$SCRIPT_DIR/nomad-start-remote.sh" "$host:$start_script"
    phone_exec "$host" "chmod +x $start_script"
    ok "Start script deployed"
  fi

  if $DRAIN; then
    drain_node "$host"
  fi

  # The start script kills existing nomad and restarts in tmux
  phone_exec "$host" "bash $start_script"

  # Wait for the agent to become healthy
  local deadline=$((SECONDS + 60))
  local addr
  if [[ "$host" == "$PHONE1" ]]; then
    addr="http://${PHONE1}:4646"
  else
    # Client nodes — check via the server API
    addr="$NOMAD_ADDR"
  fi

  log "Waiting for $host to rejoin cluster..."
  while (( SECONDS < deadline )); do
    local node_status
    node_status=$(nomad node status 2>/dev/null | grep "$host" | awk '{print $NF}') || true
    if [[ "$node_status" == "ready" ]]; then
      ok "$host is ready"

      # Re-enable scheduling if we drained
      if $DRAIN; then
        local node_id
        node_id=$(get_node_id "$host")
        if [[ -n "$node_id" ]]; then
          nomad node drain -disable -yes "$node_id" 2>/dev/null || true
          nomad node eligibility -enable "$node_id" 2>/dev/null || true
          ok "$host drain disabled, scheduling re-enabled"
        fi
      fi
      return
    fi
    sleep 3
  done
  warn "$host did not rejoin within 60s — check logs: ssh -p $SSH_PORT $host 'tail -50 ~/nomad.log'"
}

# ===========================================================================
# Main
# ===========================================================================

if [[ -n "$TARGET" ]]; then
  restart_agent "$TARGET"
else
  # Restart phone2 (client) first, then phone1 (server)
  # This way the server stays up to reschedule while client restarts
  log "Restarting all agents (client first, then server)"
  restart_agent "$PHONE2"
  restart_agent "$PHONE1"
fi

echo ""
log "Cluster status"
nomad node status 2>/dev/null || warn "Cannot reach Nomad API"

echo ""
log "Done!"
