#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# Termux + proot-distro + Nomad setup script
# Run this in Termux on a fresh Android device.
# ============================================================================
set -euo pipefail

# -- Paths -------------------------------------------------------------------
HOME_DIR="/data/data/com.termux/files/home"
PREFIX="/data/data/com.termux/files/usr"
PROOT_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs/debian"
BOOT_DIR="$HOME_DIR/.termux/boot"
REPO_URL="https://github.com/eyeh0l3/nomad-android"  # TODO: set your repo

log() { echo -e "\n\033[1;34m>>> $*\033[0m"; }

# -- 1. System packages ------------------------------------------------------
log "Updating packages & installing base tools"
pkg update -y && pkg upgrade -y
pkg install -y \
  openssh \
  proot-distro \
  termux-services \
  termux-api \
  git \
  vim \
  python \
  nodejs \
  ffmpeg \
  libjpeg-turbo \
  tmux

# -- 2. Wake lock & storage ---------------------------------------------------
log "Setting up wake lock and storage"
termux-setup-storage || true
termux-wake-lock     || true

# -- 3. SSH -------------------------------------------------------------------
log "Configuring SSH"
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

# Add authorized key (idempotent)
AUTH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCxMacuNy2G0Zg81VHh90FdVzxkjFyJRp+Dfft+pOwkdOVlWbznzDV0ui6JYlffbO0fzPMotX9XLC9G2uNdBvUTJqRzGReOStxWrmphKUcQKsEAw+WCr0mRbxaNLhI5rNmn9nA4760fk7kMwqkBgcoK0hW8uMK57pwfzIsFtTVwM76j14SxtPMCPPWC1GOpc7oopaft2T7c/jmGtkdjZ7VSCKEdV2T/uGcH5jUYRs2Jp43PD5p9sQovKZbeZoAYwbKSufnuHEqR88EIBQB9CxlXjqHZSnJ63Kz/s0/4PQK7ctYtj663q8RBX4wJGvq1WmlbFlLKhFEIebuhxDGBrc+9v+QZoNLBz/E9Ix5wH9Z4vDOFE5L4D4mObLcFnuhevg4uyo7nopvL6CgDbZ8ZTIL6oGiWr8YA9QEma4okNSQW7liPrDWfH86/w1qOMZIt7OwDGpqh1PtLFQJArj7Uh6L33m7whZuIrA5jMuBFmGOng+GsnSZmG0pvb1N2hWbx3Kc= eyeh0l3@gmail.com"
grep -qF "$AUTH_KEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null \
  || echo "$AUTH_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"

# Start sshd now and enable via runit
sshd 2>/dev/null || true
sv-enable sshd 2>/dev/null || true

# -- 4. Python tooling -------------------------------------------------------
log "Installing pipx"
python3 -m pip install --user pipx 2>/dev/null || true
python3 -m pipx ensurepath 2>/dev/null || true
export PATH="$HOME_DIR/.local/bin:$PATH"

# -- 5. proot-distro (Debian) -------------------------------------------------
log "Installing proot-distro Debian"
if [ ! -d "$PROOT_ROOT" ]; then
  proot-distro install debian
else
  echo "Debian already installed, skipping."
fi

# -- 6. Nomad binary ----------------------------------------------------------
log "Installing nomad-android into proot Debian"
NOMAD_BIN="$PROOT_ROOT/usr/local/bin/nomad-android"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Look for binary: next to this script first, then ~/files/
if [ -f "$SCRIPT_DIR/nomad-android" ]; then
  cp "$SCRIPT_DIR/nomad-android" "$NOMAD_BIN"
elif [ -f "$HOME_DIR/files/nomad-android" ]; then
  cp "$HOME_DIR/files/nomad-android" "$NOMAD_BIN"
else
  echo "ERROR: nomad-android binary not found."
  echo "It should be next to setup.sh or at ~/files/nomad-android"
  exit 1
fi
chmod +x "$NOMAD_BIN"

# -- 7. Nomad config inside Debian --------------------------------------------
log "Writing Nomad config"
NOMAD_DATA="$PROOT_ROOT/opt/nomad/data"
NOMAD_CONF="$PROOT_ROOT/etc/nomad.d"
mkdir -p "$NOMAD_DATA" "$NOMAD_CONF"

cat > "$NOMAD_CONF/nomad.hcl" << 'NOMADEOF'
data_dir  = "/opt/nomad/data"
log_level = "INFO"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}
NOMADEOF

# -- 8. Nomad wrapper in Termux -----------------------------------------------
log "Creating nomad wrapper at ~/bin/nomad"
mkdir -p "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/nomad" << 'WRAPEOF'
#!/data/data/com.termux/files/usr/bin/bash
exec proot-distro login debian -- nomad-android "$@"
WRAPEOF
chmod +x "$HOME_DIR/bin/nomad"

# -- 9. App directories -------------------------------------------------------
log "Creating app directories inside proot"
SERVE_DIR="$PROOT_ROOT/opt/apps"
mkdir -p "$SERVE_DIR"

# -- 10. Boot script (Termux:Boot) --------------------------------------------
log "Setting up Termux:Boot auto-start"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/start.sh" << 'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/bash
LOG="$HOME/.termux/boot/boot.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "===== Boot started ====="

# Wake lock
termux-wake-lock && log "Wake lock acquired" || log "Wake lock failed"

# SSH
sshd && log "sshd started" || log "sshd failed"

# Wait for network
sleep 3

# Start Nomad in tmux (survives SSH disconnects)
if tmux has-session -t nomad 2>/dev/null; then
  log "Nomad tmux session already exists"
else
  tmux new-session -d -s nomad \
    'proot-distro login debian -- nomad-android agent -config=/etc/nomad.d/ 2>&1 | tee /tmp/nomad.log'
  log "Nomad started in tmux"
fi

log "===== Boot finished ====="
BOOTEOF
chmod +x "$BOOT_DIR/start.sh"

# -- 11. Convenience aliases ---------------------------------------------------
log "Adding shell aliases"
BASHRC="$HOME_DIR/.bashrc"
MARKER="# phoneserver-setup"
if ! grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" << ALIASEOF

$MARKER
alias nomad-logs='tmux attach -t nomad'
alias nomad-start='tmux new-session -d -s nomad "proot-distro login debian -- nomad-android agent -config=/etc/nomad.d/ 2>&1 | tee /tmp/nomad.log"'
alias nomad-stop='tmux send-keys -t nomad C-c'
alias nomad-status='nomad node status'
alias debian='proot-distro login debian'
export PATH="\$HOME/bin:\$HOME/.local/bin:\$PATH"
ALIASEOF
fi

# -- Done ---------------------------------------------------------------------
log "Setup complete!"
echo ""
echo "  SSH:    ssh -p 8022 <phone-ip>"
echo "  Start:  nomad-start  (or reboot with Termux:Boot)"
echo "  Logs:   nomad-logs   (Ctrl+B D to detach)"
echo "  Stop:   nomad-stop"
echo "  Status: nomad node status"
echo ""
echo "  Next: scp nomad-android to ~/files/ and re-run if binary was missing."
echo "  Then: reboot or run 'nomad-start' to launch Nomad."
