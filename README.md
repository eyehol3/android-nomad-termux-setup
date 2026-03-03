# android-nomad-termux-setup

Run [HashiCorp Nomad](https://www.nomadproject.io/) on Android phones via Termux + proot-distro.

Patched Nomad build that replaces `net.Interfaces()` with [anet](https://github.com/wlynxg/anet) to work around Android's netlink socket restrictions, with additional patches for cgroup and mount issues in proot. The same anet fix is applied to [go-sockaddr](https://github.com/hashicorp/go-sockaddr).

## What's included

| Path | Description |
|------|-------------|
| `nomad-android` | Nomad 1.11.3-dev, linux/arm64, statically linked (git-lfs) |
| `setup.sh` | One-shot Termux setup: packages, SSH, proot Debian, Nomad config, boot script |
| `patches/` | Patch files + build script to reproduce `nomad-android` from source ([details](patches/README.md)) |
| `nomad/` | Cluster management: configs, job specs, deploy scripts ([details](nomad/README.md)) |

## Prerequisites

- 2× Android devices (ARM64)
- [Termux](https://f-droid.org/en/packages/com.termux/) + [Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/) + [Termux:API](https://f-droid.org/en/packages/com.termux.api/) from F-Droid
- Mac with `nomad` CLI (`brew install nomad`) and SSH access to both phones
- Phone hostnames in Mac's `/etc/hosts` (`phoneserver`, `phoneserver2`)

## Setup

### 1. Per-phone setup (run on each phone in Termux)

```bash
pkg install -y git git-lfs
git lfs install
git clone https://github.com/eyeh0l3/android-nomad-termux-setup
cd android-nomad-termux-setup
bash setup.sh
```

This installs packages, configures SSH (port 8022), sets up proot Debian, installs the Nomad binary, and configures Termux:Boot auto-start.

### 2. Deploy cluster (run from Mac)

```bash
cd nomad/
bash setup-cluster.sh            # push configs, start Nomad, verify 2-node cluster
bash deploy-jobs.sh              # submit all job specs
```

`setup-cluster.sh` pushes `server.hcl` to phone 1 (server + client) and a rendered `client.hcl` to phone 2 (client only), starts Nomad on both, and waits until both nodes are ready.

To also deploy the binary: `bash setup-cluster.sh --deploy-binary`

### 3. Deploy app code

```bash
bash nomad-deploy.sh --app ytsumm-bot    # build artifact + upload + restart
bash nomad-deploy.sh --all               # all apps from nomad-deploy.conf
```

Each app needs a `build.sh` in its source directory that produces a tarball via Docker cross-compilation. The tarball is uploaded to phone 1's `~/artifacts/` and served via the `artifact-server` job (Python http.server on port 8080). Nomad jobs fetch artifacts from there.

App source paths are configured in `nomad/nomad-deploy.conf`.

## After setup

SSH: `ssh -p 8022 phoneserver`

Shell aliases (added by `setup.sh`):
| Alias | Action |
|-------|--------|
| `nomad-start` | Start Nomad in tmux |
| `nomad-stop` | Send Ctrl+C to Nomad |
| `nomad-logs` | Attach to Nomad tmux (Ctrl+B D to detach) |
| `nomad-status` | `nomad node status` |
| `debian` | `proot-distro login debian` |

Day-to-day from Mac (with `export NOMAD_ADDR=http://phoneserver:4646`):
```bash
nomad node status                        # cluster health
nomad job status                         # all jobs
nomad job restart ytsumm-bot             # restart a job
nomad alloc logs -f <alloc-id>           # stream logs
bash nomad/check-cluster.sh              # full diagnostic
bash nomad/nomad-agent-restart.sh        # restart Nomad agents
```

## How the patched build works

Android 11+ restricts netlink sockets for non-system apps, breaking Go's `net.Interfaces()`. The [anet](https://github.com/wlynxg/anet) library works around this via `ioctl` instead of `RTM_GETLINK`. Additional patches handle proot-specific issues.

| Patch | What it does |
|-------|-------------|
| `01-nomad-anet` | Nomad uses `anet` instead of `net` for interface discovery |
| `02-go-sockaddr-anet` | go-sockaddr `GetAllInterfaces()` uses `anet` |
| `03-anet-linux-compat` | anet build tags extended to `linux`, custom netlink path via `init()` |
| `04-nomad-skip-cgroups` | Functional cgroup v1 probe — falls back to OFF in proot |
| `05-nomad-mount-fallback` | Graceful fallback when mount operations fail in proot |
| `06-nomad-executor-cgroups` | Executor skips cgroup setup when mode is OFF |

Build from source: `cd patches && ./build.sh` (or `NO_UI=1 ./build.sh` to skip the web UI). See [patches/README.md](patches/README.md) for details.

## Task drivers

Only `raw_exec` works in proot (no real cgroups/namespaces). The `exec`, `docker`, and `java` drivers require kernel features proot cannot provide.

## Known limitations

- `/proc/filesystems` permission denied — disk stats collection fails (non-blocking)
- No hardware MAC addresses from `anet.Interfaces()`
- Link speed detection unavailable (falls back to 1000 Mbits)
- Landlock not supported in proot
