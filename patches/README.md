# Building nomad-android from source

These patches and the build script allow you to reproduce the `nomad-android` binary from upstream sources.

## What the patches do

| Patch | Target | Changes |
|-------|--------|---------|
| `01-nomad-anet.patch` | Nomad | Replace `net.Interfaces()`, `net.InterfaceByName()`, `intf.Addrs()` with `anet` equivalents in `client/fingerprint/network.go` and `command/agent/config.go`. Add `replace` directives in `go.mod` for local `anet` and `go-sockaddr`. |
| `02-go-sockaddr-anet.patch` | go-sockaddr | Replace `net.Interfaces()` and `intf.Addrs()` with `anet` in `GetAllInterfaces()` (`ifaddrs.go`). This is the function that resolves `-bind` address templates. |
| `03-anet-linux-compat.patch` | anet | Rename `interface_android.go` → `interface_fixup.go` and `netlink_android.go` → `netlink_fixup.go` to remove implicit `GOOS=android` build constraint. Add `//go:build android \|\| linux` tags. Create `init_linux.go` to force the custom netlink path on Linux. Add `InterfaceByName()` and `InterfaceByIndex()` to the non-android build. |
| `04-nomad-skip-cgroups.patch` | Nomad | Add a functional probe to the cgroup v1 detection path — try `mkdir` on the freezer cgroup and fall back to `OFF` if it fails. This prevents the hard crash in proot environments where euid is faked to 0 but the kernel blocks real cgroup operations. |

## Why these patches are needed

### Netlink restrictions (patches 01-03)

Android 11+ restricts netlink socket operations for non-system apps:
- `Bind()` on `NETLINK` sockets is not allowed
- `RTM_GETLINK` is blocked

This breaks Go's `net.Interfaces()` and `net.InterfaceAddrs()` with:
```
route ip+net: netlinkrib: permission denied
```

The [anet](https://github.com/wlynxg/anet) library works around this by:
- Removing the `Bind()` call on netlink sockets
- Using `ioctl` (via `SIOCGIFNAME`, `SIOCGIFMTU`, `SIOCGIFFLAGS`) to get interface details from the index returned by `RTM_GETADDR`

Since we build with `GOOS=linux` (not `android`) for a statically linked binary that runs in proot, the anet patch extends the Android-specific implementation to also compile for Linux, and forces it active via an `init()` function.

### Cgroup v1 crash in proot (patch 04)

On Android devices with cgroup v1 kernels, `/sys/fs/cgroup` is mounted as `tmpfs`. Nomad detects this as CG1 mode and tries to `mkdir /sys/fs/cgroup/freezer/nomad` — which fails with "permission denied" because proot fakes `euid=0` but can't intercept real sysfs writes. On cgroup v2 devices this isn't an issue because Nomad's controller check gracefully falls back to OFF.

The patch adds a functional probe: before committing to CG1 mode, try creating a test directory in the freezer cgroup. If it fails, return OFF (disabled). This makes Nomad work on both cgroup v1 and v2 Android kernels.

## Quick build

```bash
# Requires: Go 1.23+, git, Node.js 20+, pnpm 10+
cd patches
./build.sh
```

The binary is written to `../nomad-android` by default. Override with:
```bash
OUTPUT=/path/to/nomad-android ./build.sh
```

### Without UI

To skip the Ember UI build (produces a smaller binary, no dashboard):
```bash
NO_UI=1 ./build.sh
```

## Base commits

| Repo | Commit | Date |
|------|--------|------|
| [hashicorp/nomad](https://github.com/hashicorp/nomad) | `d304b7de` | main branch (1.11.3-dev) |
| [wlynxg/anet](https://github.com/wlynxg/anet) | `5501d401` | latest |
| [hashicorp/go-sockaddr](https://github.com/hashicorp/go-sockaddr) | `b607e6a5` | v1.0.7 |

## Manual patching

If you prefer to apply patches manually:

```bash
# Clone repos
git clone https://github.com/hashicorp/nomad && cd nomad
git checkout d304b7de
git clone https://github.com/wlynxg/anet anet
git clone https://github.com/hashicorp/go-sockaddr go-sockaddr

# Apply
git apply /path/to/01-nomad-anet.patch
git apply /path/to/04-nomad-skip-cgroups.patch
cd go-sockaddr && git apply /path/to/02-go-sockaddr-anet.patch && cd ..
cd anet && git apply /path/to/03-anet-linux-compat.patch && cd ..

# Build (without UI)
go mod tidy
GOOS=linux GOARCH=arm64 go build -ldflags "-checklinkname=0" -o nomad-android .

# Build (with UI — requires Node.js 20+, pnpm 10+)
go mod tidy
pnpm install --frozen-lockfile=false --fetch-timeout 300000
pnpm -F nomad-ui build
go install github.com/hashicorp/go-bindata/go-bindata@bf7910af899725e4938903fb32048c7c0b15f12e
go install github.com/elazarl/go-bindata-assetfs/go-bindata-assetfs@234c15e7648ff35458026de92b34c637bae5e6f7
go-bindata-assetfs -pkg agent -prefix ui -modtime 1480000000 -tags ui -o bindata_assetfs.go ./ui/dist/...
mv bindata_assetfs.go command/agent/
GOOS=linux GOARCH=arm64 go build -tags ui -ldflags "-checklinkname=0" -o nomad-android .
```
