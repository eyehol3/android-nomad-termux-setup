#!/data/data/com.termux/files/usr/bin/bash
# nomad-start-remote.sh — Reliably (re)start Nomad inside proot on a phone.
# SCP'd to ~/nomad-start-remote.sh by setup-cluster.sh, then invoked via SSH.
#
# This avoids the SSH heredoc hang problem — everything runs from a local file.
set -euo pipefail

LOG="$HOME/nomad.log"

# Bind mounts: expose Termux paths inside proot so raw_exec tasks can
# use the existing venvs, npm, etc. at their original absolute paths.
BIND_FLAGS="--bind /data/data/com.termux/files/home/serve:/data/data/com.termux/files/home/serve --bind /data/data/com.termux/files/usr:/data/data/com.termux/files/usr"

# ---------------------------------------------------------------------------
# 1. Kill any existing Nomad tmux session / process
# ---------------------------------------------------------------------------
echo "Stopping existing Nomad..."
tmux kill-session -t nomad 2>/dev/null || true
sleep 1
pkill -f 'nomad-android agent' 2>/dev/null || true
sleep 1

# ---------------------------------------------------------------------------
# 2. Start Nomad in a detached tmux session
# ---------------------------------------------------------------------------
echo "Starting Nomad..."
tmux new-session -d -s nomad \
  "proot-distro login $BIND_FLAGS debian -- nomad-android agent -config=/etc/nomad.d/ 2>&1 | tee $LOG"

# ---------------------------------------------------------------------------
# 3. Verify tmux session came up
# ---------------------------------------------------------------------------
sleep 3
if tmux has-session -t nomad 2>/dev/null; then
  echo "OK: Nomad started in tmux session 'nomad'"
else
  echo "FAIL: tmux session did not start"
  tail -20 "$LOG" 2>/dev/null || true
  exit 1
fi
