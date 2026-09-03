# FDO UKI Build Pipeline

This repository contains the build pipeline for creating Ubuntu UKI (Unified Kernel Image) with FDO Stage 2 support.

## Development Philosophy

**All development and building happens on devvm.** This is the source-of-truth for code, tools, and git repos. After building, we copy required components to deployment targets (pe2, k800, onlogic, etc.).

## Overview

The UKI is built from the Ubuntu mini-ISO and includes:
- Ubuntu 7.0.0-14-generic kernel
- Full Ubuntu initramfs (91MB)
- Custom init script for Stage 1 boot
- go-fdo-endpoint binary for Stage 2 FDO onboarding
- config_generic.yaml for FSIM handler configuration

## Architecture

### Stage 1 (UEFI)
- fdo-uefi-rs UEFI client boots from flash
- Reads TPM credentials
- Runs TO2 against FDO server
- Receives UKI via BMO inline delivery (~127MB, ~1,957 rounds)
- Chainloads UKI via EFI LoadImage/StartImage

### Stage 2 (Linux)
- UKI boots Linux with custom init
- Init mounts filesystems, starts udevd, configures DHCP
- go-fdo-endpoint reads TPM credentials (same as Stage 1)
- Runs TO2 against FDO server (with `-reuse-cred`)
- Receives sysconfig params and file payloads via FSIMs
- Handlers process the configuration
- New credentials written to TPM NV

## Building

### Prerequisites

- Ubuntu mini-ISO: `assets/ubuntu-mini-iso-26.10-snapshot1-mini-iso-amd64.iso`
- go-fdo-endpoint binary: `assets/fdo-endpoint` (built from go-fdo-endpoint with `-tags=tpm`)
- ukify (systemd-ukify package)
- cpio, gzip, mount, scp

### Asset Setup

Copy required assets to the `assets/` directory:

```bash
# Copy Ubuntu mini-ISO from pe2
scp pe2:/home/bkg/bkgvm/ubuntu-mini-iso-26.10-snapshot1-mini-iso-amd64.iso assets/

# Build go-fdo-endpoint on devvm
cd ~/go-fdo-endpoint
GOROOT=/home/bradgoodman/go GOPATH=/tmp/gopath /home/bradgoodman/go/bin/go build -tags=tpm -o ~/fdo-uki-build/assets/fdo-endpoint .
```

**Note**: The `go-fdo-endpoint` build requires the fdosys build tag fix (see go-fdo-endpoint repo).

### Build Script

```bash
./build-uki.sh
```

This will:
1. Extract kernel and initrd from the mini-ISO
2. Unpack the initrd
3. Add custom init script
4. Add go-fdo-endpoint binary
5. Add config_generic.yaml
6. Repack the initrd
7. Build UKI with ukify
8. Copy to local firmware server
9. Deploy to remote host (pe2)

Output:
- Local UKI: `/tmp/ubuntu-installer-fdo.efi`
- Local firmware server: `/tmp/fdo-firmware-server/ubuntu-installer.efi`
- Remote firmware server: `pe2:/tmp/fdo-firmware-server/ubuntu-installer.efi`

## Golden Reference

The current working UKI (built manually before this script) is preserved as a reference:
- Path: `golden/ubuntu-installer-fdo-stage2-verified-2026-09-03.efi`
- Size: ~122MB
- Kernel: 7.0.0-14-generic
- Initrd: ~106MB compressed
- Verified: Stage 1 + Stage 2 end-to-end (2026-09-03)

## Testing

### Server Setup

```bash
ssh pe2 ~/bkgvm/start-server.sh
```

This starts:
- swtpm (TPM simulator)
- FDO server with BMO, sysconfig, and payload FSIMs
- HTTP server for firmware delivery

### QEMU Boot

```bash
ssh pe2 ~/bkgvm/start4.sh
```

VNC is on `pe2:5902`.

## Configuration

### Kernel Cmdline

- `console=tty0` — Video console (VNC)
- `console=ttyS0` — Serial console

### go-fdo-endpoint Config

Located at `/etc/fdo/config_generic.yaml` in the initrd:
- FDO version: 200
- DI URL: `http://10.0.2.2:8080`
- Crypto: A128GCM, ECDH256
- Handlers: sysconfig (hostname, timezone, ntp-server), payload (json, octet-stream, text)

### Server Flags

- `-rv-bypass` — Skip rendezvous (direct TO2)
- `-reuse-cred` — Enable credential reuse protocol
- `-bmo` — Send UKI via BMO inline
- `-sysconfig` — Send sysconfig parameters
- `-payload` — Send file payloads

## Troubleshooting

### TPM Socket Issues

QEMU 10.2.1 has compatibility issues with swtpm sockets. Use the full `start4.sh` script instead of running QEMU separately.

### Credential Reuse

Ensure the server has `-reuse-cred` flag. Without it, go-fdo-endpoint will generate a new credential each time, breaking the multi-stage flow.

### VNC Connection

VNC is on port 5902 (`pe2:5902`). If connection fails, check that QEMU is running:
```bash
ssh pe2 "ps aux | grep qemu"
```

## Files

- `build-uki.sh` — Main build script
- `README.md` — This file
- `golden/` — Golden reference UKIs (preserved, not modified)
