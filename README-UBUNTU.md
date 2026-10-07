# Ubuntu 26.04.1 Live-Server Installer (FDO UKI)

[← Overview](README.md) · Test results: [TEST-UBUNTU-UKI.md](TEST-UBUNTU-UKI.md) · Work tracker: [TODO-UBUNTU-UKI.md](TODO-UBUNTU-UKI.md)

![FDO UKI Architecture](doc/fdo-uki-architecture.svg)

## How It Works

This pipeline solves the problem of securely onboarding a bare-metal device with no pre-installed OS, no bootloader, and no trusted network — using only UEFI firmware and a TPM.

**Build time:** We crack open a standard vendor Ubuntu ISO, extract its kernel and initramfs, inject an FDO device agent ([go-fdo-endpoint](../go-fdo-endpoint)) and casper hooks into the initramfs, and reassemble everything into a single EFI binary (UKI) using `objcopy`. The original ISO is kept intact as a separate asset. In the future, the OS vendor (e.g. Canonical) would supply the UKI and ISO directly — end users would never need to run this build pipeline.

**Server setup:** The FDO server ([go-fdo](../go-fdo)) is loaded with four things, each serving a different role:

| Asset | Scope | Source | FSIM |
| ------- | ------- | -------- | ------ |
| **UKI** | Static — same for all devices | OS vendor (or build pipeline) | BMO |
| **Full vendor ISO** | Static — same for all devices | OS vendor (or build pipeline) | Payload |
| **Autoinstall YAML** | Per-device — machine-specific config | Operator-specified | Payload |
| **Ownership Voucher** | Per-device — device identity | Device manufacturing (DI) | FDO protocol |

SSH host keys are not loaded onto the server — they are **negotiated automatically** during onboarding via the Credentials FSIM. The server stores them for later verification.

**Device onboarding** happens in three stages with no manual intervention:

1. **Stage 1 (UEFI):** The device's UEFI FDO client ([fdo-uefi-rs](../fdo-uefi-rs)) presents its Ownership Voucher, authenticates via TPM, runs FDO TO2, and receives the UKI via **BMO FSIM** (Bare Metal Onboarding). It chainloads the UKI into Linux.

2. **Stage 2 (Linux/initrd):** The go-fdo-endpoint in the UKI's initramfs generates SSH host keys, then runs FDO TO2 (credential reuse). The server delivers the autoinstall YAML and streams the full ISO to `/dev/pmem0` via **Payload FSIM**. The endpoint sends the SSH host keys and device IP back to the server via **Credentials FSIM**.

3. **Stage 3 (Install):** Casper (Ubuntu's live boot system) finds the ISO on `/dev/pmem0`, mounts the squashfs, and hands off to Subiquity for unattended installation. Late-commands copy the FDO-generated SSH keys to the installed system and prevent cloud-init from regenerating them.

**Result:** A fully installed Ubuntu system whose SSH host keys were generated during onboarding and registered with the FDO server — eliminating the Trust On First Use (TOFU) problem. The operator can verify the device's identity on first SSH connection.

See [TEST-UBUNTU-UKI.md](TEST-UBUNTU-UKI.md) for verified flows and [TODO-UBUNTU-UKI.md](TODO-UBUNTU-UKI.md) for phased installer work.

## Building and Testing

The installer path builds a UKI from the Ubuntu 26.04.1 LTS live-server ISO:

```bash
./build-ubuntu-installer-uki.sh
```

It downloads and verifies the pinned ISO (config in `config/ubuntu-installer.env`), extracts the matching kernel/initrd, preserves native casper, injects the FDO premount hook and TPM endpoint, reserves `/dev/pmem0`, and builds:

```text
firmware/ubuntu-26.04.1-live-server-fdo.efi
```

To deploy to a test host after building:

```bash
DEPLOY=1 DEPLOY_HOST=<hostname> ./build-ubuntu-installer-uki.sh
```

The verified end-to-end flow:

1. FDO TO1/TO2 with credential reuse and TPM-backed identity
2. SSH host keys generated and transmitted to server via Credentials FSIM
3. Autoinstall YAML delivered via `application/vnd.canonical.autoinstall+yaml`
4. Full 2.728 GiB Ubuntu ISO streamed to `/dev/pmem0`
5. Casper mounts ISO, squashfs layers construct live root
6. Subiquity reads `/autoinstall.yaml` via `subiquity.autoinstallpath`
7. Unattended installation: partitioning, extract, curthooks, late-commands
8. Late-commands copy FDO SSH host keys to target, disable cloud-init key regeneration
9. VM powers off; installed qcow2 boots to `fdo-installed` login prompt
10. SSH host keys on installed system match FDO-registered keys exactly

**Current Status (2026-09-11)**:

- FDO onboarding (TO1/TO2) with credential reuse works
- Ubuntu ISO streaming to /dev/pmem0 works
- Autoinstall.yaml delivery via FDO works
- Subiquity autoinstall triggers and completes unattended installation
- SSH host keys generated in initramfs (Go implementation)
- SSH host keys transmitted to server via FDO Credentials FSIM
- SSH host keys preserved on installed system (cloud-init key regeneration disabled)
- Installed VM SSH keys verified to match FDO-registered keys exactly
- Installed VM boots to `fdo-installed` login prompt

See `TEST-UBUNTU-UKI.md` for hashes/results and `TODO-UBUNTU-UKI.md` for production hardening work.

### End-to-End Test

The `test-installer-pe2.sh` script runs the full onboarding flow on a QEMU test host:

```bash
# On the test host (requires swtpm, qemu, server-installer, quick-di-tpm)
./test-installer-pe2.sh
```

All paths are configurable via environment variables (`FDO_SERVER`, `FDO_QUICK_DI`, `FDO_EFI_DISK`, `FDO_FIRMWARE_DIR`). See the script header for details.

### Boot Installed VM

```bash
./boot-installed-vm.sh /tmp/fdo-installer-test-<timestamp>/target.qcow2
```

## Theory of Operation: Installer UKI Build

This section describes what `build-ubuntu-installer-uki.sh` does — how we crack open the Ubuntu ISO, modify its initramfs, and reassemble everything into a single EFI binary that the UEFI FDO client can chainload.

### Why a UKI?

See [Why a UKI?](README.md#why-a-uki) in the overview.

### Step 1: Download and Verify the Ubuntu ISO

The script downloads the pinned Ubuntu 26.04.1 LTS live-server ISO (2.728 GiB) and verifies its SHA-256 hash and file size. The ISO URL, hash, and size are pinned in `config/ubuntu-installer.env`. This ISO is not embedded in the UKI — it will be streamed to the device separately during onboarding (see Phase 4 in TODO).

### Step 2: Extract the Kernel and Initramfs

The ISO is loop-mounted read-only and we extract:

- `/casper/vmlinuz` — the Ubuntu kernel
- `/casper/initrd` — the Ubuntu initramfs (concatenated cpio archives)

These are the same kernel/initramfs that Ubuntu's live installer would boot. We use them verbatim (same kernel version, same module set) so that the resulting system is binary-compatible with the ISO's squashfs root.

### Step 3: Unpack the Initramfs

Ubuntu's initramfs is actually three concatenated cpio archives:

1. **`early`** — early microcode updates (Intel/AMD CPU microcode)
2. **`early2`** — firmware blobs needed before the main init
3. **`main`** — the real initramfs with `/init`, busybox, casper scripts, etc.

We use `unmkinitramfs` to split these into separate directory trees (`$ROOTFS_DIR/early`, `$ROOTFS_DIR/early2`, `$ROOTFS_DIR/main`). All modifications go into `main` only.

### Step 4: Inject FDO Components

Into the `main` archive we add:

| Component | Destination | Purpose |
| ----------- | ------------- | --------- |
| `fdo-endpoint` (built from go-fdo-endpoint with `-tags=tpm`) | `/usr/local/bin/fdo-endpoint` | FDO device agent — runs TO2, receives payloads, sends SSH keys |
| `rootfs-installer/etc/fdo/config.yaml` | `/etc/fdo/config.yaml` | Endpoint FSIM configuration (payload destinations, MIME handlers) |
| `rootfs-installer/scripts/casper-premount/20fdo-receive` | `/scripts/casper-premount/20fdo-receive` | Hook that runs FDO onboarding before casper mounts the live media |
| `rootfs-installer/scripts/casper-bottom/62fdo-autoinstall` | `/scripts/casper-bottom/62fdo-autoinstall` | Hook that copies FDO-delivered autoinstall into the live root |
| `rootfs-installer/scripts/generate-ssh-host-keys.sh` | `/scripts/generate-ssh-host-keys.sh` | Generates SSH host keys using fdo-endpoint's `-gen-ssh-keys` |

### Step 5: Patch Casper's ORDER Files

Ubuntu's casper uses `ORDER` files to control hook execution order. We insert our hooks at specific positions:

- **casper-premount/ORDER**: Insert `20fdo-receive` _before_ `20iso_scan`. This runs FDO onboarding to stream the ISO to `/dev/pmem0` before casper tries to find live media.
- **casper-bottom/ORDER**: Insert `62fdo-autoinstall` _before_ `99casperboot`. This copies the autoinstall config into the live root before casper hands off to systemd.

This is critical — simply dropping an executable into the scripts directory is not enough. Casper only runs scripts listed in ORDER.

### Step 6: Reconstruct the Initramfs

The three archives must be reassembled in exact order:

1. `early` and `early2` — repackaged as uncompressed newc cpio archives
2. `main` — repackaged as a gzip-compressed newc cpio archive

The concatenated result replaces the original initramfs. The kernel's initramfs unpacker knows to process multiple concatenated cpio archives.

### Step 7: Compute Kernel Command Line

The command line is computed dynamically:

```text
boot=casper ip=dhcp live-media=/dev/pmem0 memmap=2796M!4G nokaslr
autoinstall subiquity.autoinstallpath=/autoinstall.yaml
console=tty0 console=ttyS0
```

Key parameters:

- `memmap=NM!4G` — Reserves N MiB of RAM starting at 4 GiB as a persistent memory region (`/dev/pmem0`). N is computed from the ISO size, rounded up to 4 MiB alignment. This is where the ISO will be streamed to during FDO onboarding.
- `live-media=/dev/pmem0` — Tells casper to look for the live media on `/dev/pmem0` instead of scanning USB/CD.
- `autoinstall` — Triggers Subiquity's unattended install mode.
- `subiquity.autoinstallpath=/autoinstall.yaml` — Points Subiquity directly at the FDO-delivered autoinstall config.

### Step 8: Build the UKI

We use `objcopy` to pack sections into the systemd EFI stub:

| Section | Content | VMA |
| --------- | --------- | ----- |
| `.osrel` | `/etc/os-release` | `0x20000` |
| `.cmdline` | Computed command line | `0x30000` |
| `.linux` | Ubuntu kernel | `0x2000000` |
| `.initrd` | Modified initramfs | Aligned after kernel |

The `.initrd` VMA is computed dynamically: kernel base + kernel size, rounded up to 1 MiB alignment. This is necessary because the initramfs is ~100+ MiB and must not overlap the kernel.

The result is a single `.efi` file (~106 MiB) that UEFI can load and execute directly.

### Runtime Flow

When the UKI boots:

1. UEFI stub loads kernel + initramfs from the PE sections
2. Kernel boots, creates `/dev/pmem0` from the `memmap=` reservation
3. Casper's `ORDER` runs `20fdo-receive` during premount:
   - `generate-ssh-host-keys.sh` creates ed25519/ecdsa/rsa key pairs
   - `fdo-endpoint` runs direct TO2 against the FDO server
   - Server sends autoinstall YAML (small, fast) -> written to `/run/fdo/autoinstall/user-data`
   - Server sends the full ISO (~2.7 GiB) -> streamed to `/dev/pmem0`
   - Endpoint sends SSH host keys + device IP back to server via `fdo.credentials` FSIM
4. Casper's `20iso_scan` finds ISO9660 on `/dev/pmem0`, mounts it
5. Casper mounts squashfs layers, constructs the overlay live root
6. `62fdo-autoinstall` copies autoinstall config to `/root/autoinstall.yaml` (which becomes `/autoinstall.yaml` after root switch)
7. Systemd starts, Subiquity reads `/autoinstall.yaml`
8. Unattended installation runs (partitioning, extraction, late-commands)
9. Late-commands copy SSH keys, write cloud-init preservation config, write completion marker
10. VM powers off

## Simple UKI (mini-ISO): the original two-stage proof of concept

### Overview

The UKI is built from the Ubuntu mini-ISO and includes:

- Ubuntu 7.0.0-14-generic kernel
- Full Ubuntu initramfs (91MB)
- Custom init script for Stage 1 boot
- go-fdo-endpoint binary for Stage 2 FDO onboarding
- config_generic.yaml for FSIM handler configuration

### Architecture

#### Stage 1 (UEFI)

- fdo-uefi-rs UEFI client boots from flash
- Reads TPM credentials
- Runs TO2 against FDO server
- Receives UKI via BMO inline delivery (~127MB, ~1,957 rounds)
- Chainloads UKI via EFI LoadImage/StartImage

#### Stage 2 (Linux)

- UKI boots Linux with custom init
- Init mounts filesystems, starts udevd, configures DHCP
- go-fdo-endpoint reads TPM credentials (same as Stage 1)
- Runs TO2 against FDO server (with `-reuse-cred`)
- Receives sysconfig params and file payloads via FSIMs
- Handlers process the configuration
- New credentials written to TPM NV

### Building the Simple UKI

Prerequisites:

- Ubuntu mini-ISO placed in `assets/` (or set `MINI_ISO_URL` in `config/simple-uki.env`)
- go-fdo-endpoint binary: `assets/fdo-endpoint` (built from go-fdo-endpoint with `-tags=tpm`)
- objcopy, cpio, gzip, mount

```bash
# Build go-fdo-endpoint
cd ../go-fdo-endpoint
go build -tags=tpm -o ../fdo-uki-build/assets/fdo-endpoint .

# Build the UKI
./build-uki.sh
```

This will:

1. Extract kernel and initrd from the mini-ISO
2. Unpack the initrd
3. Inject init script, fdo-endpoint, and config from `rootfs-simple/`
4. Repack the initrd
5. Build UKI with objcopy
6. Optionally deploy to `$DEPLOY_HOST` (set in `config/simple-uki.env`)

Output: `firmware/ubuntu-installer-fdo.efi`

### Golden Reference

The current working UKI (built manually before this script) is preserved as a reference:

- Path: `golden/ubuntu-installer-fdo-stage2-verified-2026-09-03.efi`
- Size: ~122MB
- Kernel: 7.0.0-14-generic
- Initrd: ~106MB compressed
- Verified: Stage 1 + Stage 2 end-to-end (2026-09-03)

## Files

- `build-uki.sh` — Simple UKI build (mini-ISO kernel, custom init, small payloads)
- `build-ubuntu-installer-uki.sh` — Full Ubuntu installer UKI build (live-server ISO kernel/initramfs)
- `test-installer-pe2.sh` — End-to-end test: TPM init, FDO server, QEMU, autoinstall, verification
- `boot-installed-vm.sh` — Boot an installed qcow2 for manual inspection
- `config/ubuntu-installer.env` — Pinned ISO URL, hash, size, UKI filename
- `config/simple-uki.env` — Simple UKI build configuration (mini-ISO name, deploy target)
- `config/autoinstall-test.yaml` — Test autoinstall config (hostname, user, SSH, late-commands)
- `rootfs-simple/` — Overlay files for the simple UKI build:
  - `init` — Custom init script (mounts filesystems, DHCP, runs fdo-endpoint)
  - `etc/fdo/config_generic.yaml` — Endpoint FSIM config (sysconfig, payload handlers)
- `rootfs-installer/` — Overlay files for the installer UKI build:
  - `etc/fdo/config.yaml` — Endpoint FSIM config (payload destinations, MIME handlers)
  - `scripts/casper-premount/20fdo-receive` — FDO onboarding hook (keygen, TO2, ISO streaming)
  - `scripts/casper-bottom/62fdo-autoinstall` — Copies autoinstall into live root
  - `scripts/generate-ssh-host-keys.sh` — SSH key generation wrapper
- `doc/fdo-uki-architecture.svg` — Architecture diagram (Ubuntu)
- `golden/` — Golden reference UKIs (preserved, not modified)
- `TEST-UBUNTU-UKI.md` — Verified test results and hashes
- `TODO-UBUNTU-UKI.md` — Phased work tracker
