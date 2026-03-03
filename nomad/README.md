# Nomad cluster for Android phones

Translates the `supervisord.conf` process management into a Nomad cluster running across two Android phones via Termux + proot-distro.

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│  phoneserver        │     │  phoneserver2        │
│  (server + client)  │◄───►│  (client only)       │
│                     │     │                      │
│  Nomad UI :4646     │     │                      │
│  RPC      :4647     │     │                      │
│  Serf     :4648     │     │                      │
└─────────────────────┘     └─────────────────────┘

Jobs (count=1 each, reschedule on failure):
  ytsumm-bot          service   Python telegram bot
  cron-checker-bot    periodic  Python, runs every 10 min
  mcpingbot           service   Python telegram bot
  textplease-bot      service   Python telegram bot
  recipe-book         service   Node.js web app
```

All jobs use `raw_exec` (only viable driver in proot) and can run on either node.  
Each telegram bot runs exactly **one instance** — if a node dies, Nomad reschedules to the other phone.

## Files

| File | Purpose |
|------|---------|
| `server.hcl` | Nomad agent config for phone 1 (server + client) |
| `client.hcl` | Nomad agent config for phone 2 (client only) |
| `jobs/*.nomad.hcl` | Job specs for each service |
| `nomad-start-remote.sh` | Start script SCP'd to phones — reliably (re)starts Nomad in tmux |
| `setup-cluster.sh` | Push configs + binary, start Nomad, verify cluster health |
| `deploy-jobs.sh` | Submit all job specs to the running cluster |
| `check-cluster.sh` | Read-only cluster diagnostic (SSH, tmux, nodes, jobs, logs) |

## Prerequisites

1. Both phones ran `setup.sh` from the parent directory
2. SSH works: `ssh -p 8022 phoneserver` and `ssh -p 8022 phoneserver2`
3. `nomad` CLI installed on your Mac (`brew install nomad`)
4. `phoneserver` / `phoneserver2` in your Mac's `/etc/hosts`

## Setup

### 1. Stop supervisor on the phones

Before switching to Nomad, stop the existing supervisor processes:

```bash
ssh -p 8022 phoneserver  "~/.local/bin/supervisorctl stop all && ~/.local/bin/supervisorctl shutdown"
ssh -p 8022 phoneserver2 "~/.local/bin/supervisorctl stop all && ~/.local/bin/supervisorctl shutdown" 2>/dev/null || true
```

### 2. Deploy cluster configs

```bash
cd nomad/
bash setup-cluster.sh
```

This will:
- Verify the installed binary is patched on both phones
- Push `server.hcl` to phoneserver and `client.hcl` (with rendered IP) to phoneserver2
- SCP `nomad-start-remote.sh` to both phones and start Nomad
- Poll the Nomad API health endpoint until it responds (up to 120s)
- Verify both nodes are `ready` in the cluster

To also deploy the binary:
```bash
bash setup-cluster.sh --deploy-binary
```

If you need to override hostnames or IPs:
```bash
PHONE1=myphone1 PHONE2=myphone2 PHONE1_IP=10.0.0.5 bash setup-cluster.sh
```

### 3. Check cluster health

```bash
bash check-cluster.sh
```

Read-only diagnostic — checks SSH, tmux sessions, binary, API health, node/job status, and recent logs.

### 4. Deploy jobs

```bash
bash deploy-jobs.sh
```

Or with an explicit address:
```bash
NOMAD_ADDR=http://10.0.0.5:4646 bash deploy-jobs.sh
```

### 5. Open the dashboard

Navigate to **http://phoneserver:4646** in your browser.

## Why bind mounts?

Nomad runs inside proot-distro Debian, but the apps (Python venvs, npm) live in Termux's filesystem at `/data/data/com.termux/files/...`. By default, these paths aren't visible inside proot.

`nomad-start-remote.sh` (SCP'd to the phones by `setup-cluster.sh`) starts Nomad with:
```
--bind /data/data/com.termux/files/home/serve:/data/data/com.termux/files/home/serve
--bind /data/data/com.termux/files/usr:/data/data/com.termux/files/usr
```

This makes the app directories and Termux binaries available at their original paths inside proot.

## Day-to-day commands

All commands run from your Mac with `NOMAD_ADDR=http://phoneserver:4646` (or `export` it).

```bash
# Cluster health
nomad node status

# Job status
nomad job status
nomad job status ytsumm-bot

# Restart a specific job
nomad job restart ytsumm-bot

# View logs
nomad alloc logs -f <alloc-id>

# Stop a job
nomad job stop ytsumm-bot

# Re-deploy a single job after editing
nomad job run jobs/ytsumm-bot.nomad.hcl

# Force reschedule (e.g., move to other phone)
nomad job eval -force-reschedule ytsumm-bot
```

## Deploying app code updates (future)

With Nomad, the deployment Makefile pattern changes from supervisor restarts to:

```makefile
deploy:
	rsync -avz --exclude node_modules --exclude .git . phoneserver:~/serve/recipe_book/
	ssh -p 8022 phoneserver "cd ~/serve/recipe_book && npm install --omit=dev"
	NOMAD_ADDR=http://phoneserver:4646 nomad job restart recipe-book
```

The `rsync` + `nomad job restart` replaces `supervisorctl restart`. Since Nomad handles placement, the app restarts on whichever node it's currently scheduled on. To redeploy app code to *all* nodes (so it can run anywhere after failover), rsync to both phones.

## Pinning a job to a specific node

By default, all jobs can run on any node. To restrict one:

```hcl
# Inside the job's group block:
constraint {
  attribute = "${node.unique.name}"
  value     = "phoneserver"
}
```

## Troubleshooting

**Cluster not forming**: Check that phoneserver2 can reach phoneserver on port 4647. Inside proot on phoneserver2, verify `/etc/hosts` or use the IP directly in `client.hcl`.

**Tasks fail immediately**: SSH into the phone, attach to tmux (`nomad-logs`), check `/tmp/nomad.log`. Common issue: proot bind mounts missing — re-run `setup-cluster.sh`.

**Python/npm not found**: The bind mounts aren't active. Verify the start command includes the `--bind` flags: `ssh -p 8022 phoneserver "cat ~/.termux/boot/start.sh"`.
