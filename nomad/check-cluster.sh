#!/bin/bash
# check-cluster.sh — Read-only diagnostic for the Nomad cluster on Android phones.
# Run from your Mac. Does not modify anything.
#
# Usage:
#   bash check-cluster.sh
#   PHONE1=myphone1 PHONE2=myphone2 bash check-cluster.sh
set -euo pipefail

SSH_PORT="${SSH_PORT:-8022}"
PHONE1="${PHONE1:-phoneserver}"
PHONE2="${PHONE2:-phoneserver2}"
export NOMAD_ADDR="${NOMAD_ADDR:-http://${PHONE1}:4646}"
PROOT_BIN="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/debian/usr/local/bin/nomad-android"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo -e "\033[1;32m  ✓ $*\033[0m"; }
fail() { FAIL=$((FAIL+1)); echo -e "\033[1;31m  ✗ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
hdr()  { echo -e "\n\033[1;34m=== $* ===\033[0m"; }

phone_exec() {
  local host="$1"; shift
  ssh -p "$SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes "$host" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. SSH connectivity
# ---------------------------------------------------------------------------
hdr "SSH Connectivity"

for phone in "$PHONE1" "$PHONE2"; do
  if phone_exec "$phone" "echo ok" > /dev/null; then
    ok "$phone — SSH reachable"
  else
    fail "$phone — SSH unreachable"
  fi
done

# ---------------------------------------------------------------------------
# 2. tmux sessions
# ---------------------------------------------------------------------------
hdr "Nomad tmux Sessions"

for phone in "$PHONE1" "$PHONE2"; do
  if phone_exec "$phone" "tmux has-session -t nomad"; then
    ok "$phone — tmux 'nomad' session alive"
  else
    fail "$phone — tmux 'nomad' session NOT found"
  fi
done

# ---------------------------------------------------------------------------
# 3. Binary verification
# ---------------------------------------------------------------------------
hdr "Binary Verification"

for phone in "$PHONE1" "$PHONE2"; do
  if phone_exec "$phone" "grep -q nomad-probe $PROOT_BIN"; then
    ok "$phone — binary is patched (nomad-probe marker found)"
  else
    fail "$phone — binary is NOT patched or missing"
  fi
done

# ---------------------------------------------------------------------------
# 4. Nomad API health
# ---------------------------------------------------------------------------
hdr "Nomad API Health"

if curl -sf "${NOMAD_ADDR}/v1/agent/health" > /dev/null 2>&1; then
  ok "Nomad API at $NOMAD_ADDR is healthy"
else
  fail "Nomad API at $NOMAD_ADDR is unreachable"
fi

# ---------------------------------------------------------------------------
# 5. Node status
# ---------------------------------------------------------------------------
hdr "Node Status"

if NODE_OUTPUT=$(nomad node status 2>/dev/null); then
  echo "$NODE_OUTPUT"
  READY_COUNT=$(echo "$NODE_OUTPUT" | grep -c "ready" || true)
  if [[ "$READY_COUNT" -ge 2 ]]; then
    ok "$READY_COUNT nodes ready"
  elif [[ "$READY_COUNT" -ge 1 ]]; then
    warn "Only $READY_COUNT node(s) ready (expected 2)"
  else
    fail "No nodes ready"
  fi
else
  fail "Cannot query node status (API down?)"
fi

# ---------------------------------------------------------------------------
# 6. Job status
# ---------------------------------------------------------------------------
hdr "Job Status"

if JOB_OUTPUT=$(nomad job status 2>/dev/null); then
  if [[ -z "$JOB_OUTPUT" || "$JOB_OUTPUT" == "No running jobs" ]]; then
    warn "No jobs registered"
  else
    echo "$JOB_OUTPUT"
    echo ""
    # Per-job alloc summary
    while IFS= read -r jobname; do
      [[ -z "$jobname" ]] && continue
      ALLOC_LINE=$(nomad job status -short "$jobname" 2>/dev/null \
        | awk '/Allocations/,0 { if (NR>1 && NF>0 && $0 !~ /^ID/) print; }' | head -1)
      if [[ -n "$ALLOC_LINE" ]]; then
        echo "  $jobname → $ALLOC_LINE"
      else
        echo "  $jobname → (no allocations)"
      fi
    done < <(nomad job status 2>/dev/null | awk 'NR>1 && NF>0 {print $1}')
  fi
else
  fail "Cannot query job status"
fi

# ---------------------------------------------------------------------------
# 7. Recent log lines (filtered: skip /proc/filesystems spam)
# ---------------------------------------------------------------------------
hdr "Recent Logs (last 5 non-spam lines)"

for phone in "$PHONE1" "$PHONE2"; do
  echo -e "\n  \033[1m$phone:\033[0m"
  LINES=$(phone_exec "$phone" "grep -v 'failed to collect disk stats' ~/nomad.log 2>/dev/null | tail -5" 2>/dev/null || echo "  (could not read log)")
  if [[ -n "$LINES" ]]; then
    echo "$LINES" | sed 's/^/    /'
  else
    echo "    (empty or no log file)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hdr "Summary"
echo -e "  Passed: \033[1;32m$PASS\033[0m   Failed: \033[1;31m$FAIL\033[0m"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
