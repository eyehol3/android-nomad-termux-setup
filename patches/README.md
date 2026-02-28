# Building nomad-android from source

These patches and the build script allow you to reproduce the `nomad-android` binary from upstream sources.

## What the patches do

| Patch | Target | Changes |
|-------|--------|---------|
| `01-nomad-anet.patch` | Nomad | Replace `net.Interfaces()`, `net.InterfaceByName()`, `intf.Addrs()` with `anet` equivalents in `client/fingerprint/network.go` and `command/agent/config.go`. Add `replace` directives in `go.mod` for local `anet` and `go-sockaddr`. |
| `02-go-sockaddr-anet.patch` | go-sockaddr | Replace `net.Interfaces()` and `intf.Addrs()` with `anet` in `GetAllInterfaces()` (`ifaddrs.go`). This is the function that resolves `-bind` address templates. |
| `03-anet-linux-compat.patch` | anet | Rename `interface_android.go` → `interface_fixup.go` and `netlink_android.go` → `netlink_fixup.go` to remove implicit `GOOS=android` build constraint. Add `//go:build android \|\| linux` tags. Create `init_linux.go` to force the custom netlink path on Linux. Add `InterfaceByName()` and `InterfaceByIndex()` to the non-android build. |

## Why these patches are needed

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

## Quick build

```bash
# Requires: Go 1.23+, git
cd patches
./build.sh
```

The binary is written to `../nomad-android` by default. Override with:
```bash
OUTPUT=/path/to/nomad-android ./build.sh
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
cd go-sockaddr && git apply /path/to/02-go-sockaddr-anet.patch && cd ..
cd anet && git apply /path/to/03-anet-linux-compat.patch && cd ..

# Build
go mod tidy
GOOS=linux GOARCH=arm64 go build -ldflags "-checklinkname=0" -o nomad-android .
```
