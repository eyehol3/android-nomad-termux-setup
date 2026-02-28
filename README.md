# android-nomad-termux-setup

Run [HashiCorp Nomad](https://www.nomadproject.io/) on Android phones via Termux + proot-distro.

This is a patched Nomad build that replaces `net.Interfaces()` with [anet](https://github.com/wlynxg/anet) to work around Android's netlink socket restrictions (`route ip+net: netlinkrib: permission denied`). The same fix is applied to [go-sockaddr](https://github.com/hashicorp/go-sockaddr) which Nomad uses for address resolution.

## What's included

| File | Description |
|------|-------------|
| `nomad-android` | Nomad 1.11.3-dev, linux/arm64, statically linked |
| `setup.sh` | One-shot Termux setup: packages, SSH, proot Debian, Nomad config, boot script |
| `patches/` | Patch files + build script to reproduce `nomad-android` from source ([details](patches/README.md)) |

## Prerequisites

- Android device (ARM64)
- [Termux](https://f-droid.org/en/packages/com.termux/) from F-Droid
- [Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/) (for auto-start on reboot)
- [Termux:API](https://f-droid.org/en/packages/com.termux.api/) (for wake lock)

## Quick start

```bash
# In Termux:
pkg install -y git
git clone https://github.com/eyehol3/android-nomad-termux-setup
cd android-nomad-termux-setup

# Run setup (binary is picked up automatically from the repo)
chmod +x setup.sh
bash setup.sh

# Start Nomad
nomad-start

# Check status
nomad node status

# Attach to logs (Ctrl+B D to detach)
nomad-logs
```

## After setup

SSH into the phone from your Mac:
```bash
ssh -p 8022 <phone-ip>
```

Useful aliases (added to `~/.bashrc`):
| Alias | Action |
|-------|--------|
| `nomad-start` | Start Nomad in a tmux session |
| `nomad-stop` | Send Ctrl+C to Nomad |
| `nomad-logs` | Attach to Nomad tmux session |
| `nomad-status` | `nomad node status` |
| `debian` | `proot-distro login debian` |

## Multi-phone cluster

**Phone 1** (server + client) — default config from `setup.sh`.

**Phone 2** (client only) — edit `/etc/nomad.d/nomad.hcl` inside proot:
```hcl
data_dir  = "/opt/nomad/data"
log_level = "INFO"
bind_addr = "0.0.0.0"

client {
  enabled = true
  servers = ["<phone1-ip>:4647"]
}
```

## How the patched build works

Android 11+ restricts netlink sockets for non-system apps, breaking Go's `net.Interfaces()` and `net.InterfaceAddrs()`. The [anet](https://github.com/wlynxg/anet) library works around this by using `ioctl` instead of `RTM_GETLINK` and skipping the `Bind()` call on netlink sockets.

This repo's build patches:
1. **Nomad** — `client/fingerprint/network.go` and `command/agent/config.go` use `anet` instead of `net`
2. **go-sockaddr** — `ifaddrs.go` `GetAllInterfaces()` uses `anet` instead of `net`
3. **anet** — build tags extended to `linux` (not just `android`), custom netlink path forced via `init()`

Build command:
```bash
GOOS=linux GOARCH=arm64 go build -ldflags "-checklinkname=0" -o nomad-android .
```

## Task drivers

Only `raw_exec` works in proot (no real cgroups/namespaces). The `exec`, `docker`, and `java` drivers require kernel features proot cannot provide.

## Known limitations

- `/proc/filesystems` permission denied — disk stats collection fails (non-blocking)
- No hardware MAC addresses from `anet.Interfaces()`
- Link speed detection unavailable (falls back to 1000 Mbits)
- Landlock not supported in proot
