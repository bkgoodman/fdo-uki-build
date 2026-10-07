# Fedora 44 Server Installer (FDO UKI)

[← Overview](README.md) · Test results: [TEST-FEDORA-UKI.md](TEST-FEDORA-UKI.md) · Work tracker: [TODO-FEDORA-UKI.md](TODO-FEDORA-UKI.md)

![FDO UKI Fedora Architecture](doc/fdo-uki-fedora-architecture.svg)

## Building and Testing

The Fedora path builds a UKI from the Fedora 44 Server DVD ISO (offline install: the full package repository is on the ISO, so the installer never pulls packages from the network). For the full picture, see the [Fedora architecture diagram](doc/fdo-uki-fedora-architecture.svg) and [Theory of Operation](#theory-of-operation).

```bash
GO_ROOT=/path/to/go1.25 ./build-fedora-installer-uki.sh
```

It downloads and verifies the pinned ISO (config in `config/fedora-installer.env`), extracts `/images/pxeboot/vmlinuz` and `initrd.img`, appends the FDO overlay from `rootfs-fedora/` to the untouched Anaconda initramfs, reserves `/dev/pmem0`, and builds:

```text
firmware/fedora-44-server-dvd-fdo.efi
```

Set `ENDPOINT_BIN=assets/fdo-endpoint` to use a prebuilt (static) endpoint instead of building go-fdo-endpoint. Host tools: `curl`, `sudo mount`, `blkid`, `cpio`, `gzip`, `xz`, `objcopy`/`objdump`, the systemd-boot EFI stub. Any build-host distro works.

To deploy the UKI, ISO, and test kickstart to a test host, then run the end-to-end test there:

```bash
DEPLOY=1 DEPLOY_HOST=<hostname> ./build-fedora-installer-uki.sh
./test-fedora-installer.sh   # on the test host
```

The server delivers the kickstart as `application/vnd.fedora.kickstart` (before the ISO) and the DVD as `application/x-iso9660-image`. The harness also registers a TO0 blob, with the TO2 address as seen from the guest (`10.0.2.2:8080`). go-fdo-endpoint only reaches TO2 through TO1 (or an RV bypass directive), so without that blob Stage 2 cannot onboard.

**Verified end to end on 2026-09-30:** TO1/TO2 in both stages, BMO of the 277 MiB UKI, 3.6 GiB ISO streamed to `/dev/pmem0`, and an unattended Anaconda install. The installed `fdo-installed` system's SSH host keys are byte-identical to the FDO-registered keys, so strict host-key checking passes with no TOFU, before and after a reboot, with SELinux enforcing. See `TEST-FEDORA-UKI.md` for findings, hashes and timings, and `TODO-FEDORA-UKI.md` for remaining work.

## Theory of Operation

This section is the reference for how the Fedora path works: what `build-fedora-installer-uki.sh` does to the vendor ISO, what the FDO server holds, and what happens on the device. The diagram reads top to bottom in the same order. Colours mark where each piece comes from (see the legend). The coloured trace lines show each server-side asset reaching the device stage that consumes it.

The FDO side (TO1/TO2, BMO, Payload FSIM, Credentials FSIM, credential reuse) is the same as for Ubuntu. What differs is the installer plumbing: Fedora uses dracut with systemd in the initrd, Anaconda instead of Subiquity, and a kickstart instead of autoinstall YAML.

### At a Glance

**Build time:** The script takes the stock Fedora 44 Server DVD and extracts its kernel and Anaconda initramfs. It leaves the initramfs **byte-for-byte untouched** and **appends** a small cpio archive with the FDO pieces: go-fdo-endpoint, its config, and the `fdo-receive.service` hook. Kernel, initramfs, command line and Fedora's own `os-release` are packed into one UKI. The ISO itself is not modified and is delivered separately.

**Server setup:** The FDO server holds these assets, plus the SSH keys it receives during onboarding:

| Asset | Scope | Source | FSIM / mechanism |
| ------- | ------- | -------- | ------------------ |
| **UKI** (`fedora-44-server-dvd-fdo.efi`, 277 MiB) | Static, same for all devices | OS vendor (or this build) | BMO, `application/x-uefi-image` |
| **Full DVD ISO** (3.6 GiB) | Static | OS vendor | Payload, `application/x-iso9660-image` |
| **Kickstart** | Per-device | Operator | Payload, `application/vnd.fedora.kickstart`, sent **before** the ISO |
| **Ownership Voucher** | Per-device | Device manufacturing (DI) | FDO protocol |
| **RV blob** (TO0) | Per-device | Owner registers it | Rendezvous; tells both stages where TO2 is |

**Device onboarding:**

1. **Stage 1 (UEFI):** fdo-uefi-rs runs TO1 → TO2 with its TPM credential and verifies the voucher chain. It receives the UKI over BMO, checks its SHA-256, and chainloads it.
2. **Stage 2 (Fedora initrd):** Before Anaconda looks for media, `fdo-receive.service` generates SSH host keys and runs TO1 → TO2 again (credential reuse). It receives the kickstart and streams the whole ISO into RAM-backed `/dev/pmem0`, and the server gets the SSH public keys back. The service then validates the media and hands the kickstart to Anaconda the way Anaconda itself would.
3. **Stage 3 (Anaconda):** stock dracut/Anaconda logic finds the ISO on `/dev/pmem0` by its label and runs the kickstart unattended. It installs from the DVD's own package repo (offline), copies the FDO-generated host keys into the target, fixes their SELinux labels, and powers off.

**Result:** An installed Fedora 44 Server whose SSH host keys were generated during onboarding and registered with the owner, so the first SSH connection can be verified without trust-on-first-use.

### Ubuntu → Fedora mapping

| Concern | Ubuntu | Fedora |
| --- | --- | --- |
| Kernel / initrd on ISO | `/casper/vmlinuz`, `/casper/initrd` | `/images/pxeboot/vmlinuz`, `/images/pxeboot/initrd.img` |
| Installer runtime | casper + squashfs, Subiquity | Anaconda stage2 `/images/install.img`, repo in `/Packages` |
| Initramfs framework | initramfs-tools (busybox, `ORDER` files) | dracut with systemd in the initrd |
| Initrd modification | unpack early/early2/main, edit, repack | **append** one gzip cpio to the original bytes |
| FDO hook | `casper-premount/20fdo-receive` before `20iso_scan` | `fdo-receive.service`: after `network-online.target`, before `dracut-initqueue.service` |
| Media argument | `live-media=/dev/pmem0` | `inst.repo=hd:LABEL=Fedora-S-dvd-x86_64-44` |
| Unattended config | autoinstall YAML → `/autoinstall.yaml` | kickstart → `/run/install/ks.cfg` |
| MIME type | `application/vnd.canonical.autoinstall+yaml` | `application/vnd.fedora.kickstart` |
| SSH key copy | late-commands → `/target/etc/ssh` | `%post --nochroot` → `$ANA_INSTALL_PATH/etc/ssh`, then `restorecon` |
| Key regeneration guard | cloud-init drop-in | none needed (no cloud-init; `sshd-keygen@` only creates missing keys) |
| `.osrel` | build host `/etc/os-release` | Fedora's `os-release` from the ISO initrd |

### Build Steps (`build-fedora-installer-uki.sh`)

These match the **Build-Time Preparation** panel of the diagram.

1. **Fetch and verify the ISO.** Download `Fedora-Server-dvd-x86_64-44-1.7.iso` if it's missing. Check its SHA-256 and size (pinned in `config/fedora-installer.env` from Fedora's signed CHECKSUM file) and its volume label `Fedora-S-dvd-x86_64-44`.
2. **Extract.** Loop-mount the ISO read-only and copy `images/pxeboot/vmlinuz`, `images/pxeboot/initrd.img`, `EFI/BOOT/grub.cfg` and `.treeinfo`. Confirm that grub.cfg boots `inst.stage2=hd:LABEL=<same label>`.
3. **Inspect the initrd (read-only).** The initrd is a single XZ-compressed cpio. The script extracts only a few files to validate against:
   - the kernel version matches `vmlinuz`
   - the required modules are present: `libnvdimm`, `nd_e820`, `nd_pmem`, `isofs`, `tpm_tis`/`tpm_crb`, `virtio_net`
   - `nm-wait-online-initrd.service` is still `Before=dracut-initqueue.service`
   - `anaconda-lib.sh` still provides `parse_kickstart` and `run_kickstart`

   Fedora's `usr/lib/os-release` is kept for the UKI's `.osrel` section.
4. **Stage the overlay.** Copy `rootfs-fedora/` and the shared `generate-ssh-host-keys.sh`, and build a static `fdo-endpoint` (`CGO_ENABLED=0 -tags=tpm`). Substitute the ISO label into `fdo-receive.sh` and create the `initrd.target.wants/fdo-receive.service` symlink. The overlay is rejected if it contains top-level `bin`, `sbin`, `lib` or `lib64` entries (see below).
5. **Append.** Pack the overlay as a gzip newc cpio (owned by root) and append it to a copy of the original initrd, padded to a 4-byte boundary. Self-checks: `cmp` proves the original bytes are an unchanged prefix, and the appended archive is listed back from its offset.
6. **Command line.** Compute `memmap=` from the ISO size (rounded up to MiB, 4 MiB aligned) and write `inst.repo=hd:LABEL=… inst.text ip=dhcp rd.neednet=1 memmap=3732M!4G nokaslr console=tty0 console=ttyS0`.
7. **UKI.** objcopy adds `.osrel`, `.cmdline`, `.linux` and `.initrd` to the systemd EFI stub, using the same VMA layout as the Ubuntu builder. The result is `firmware/fedora-44-server-dvd-fdo.efi` plus `build-fedora/SHA256SUMS`.

### Why append instead of repack?

The UKI holds exactly three things that matter at boot (the red | red | teal chips in the diagram): the vendor kernel, the vendor initrd, and our overlay. The overlay and initrd together fill the UKI's single `.initrd` section. The EFI stub passes that section to the kernel as one buffer and knows nothing about what's inside.

The kernel's initramfs unpacker (`unpack_to_rootfs()` in `init/initramfs.c`) does the rest. It treats the buffer as a sequence of cpio archives. For each one it recognizes the compression from the magic bytes (XZ, gzip, zstd, …), decompresses it, skips zero padding to the next 4-byte boundary, and continues, with later files overlaying earlier ones. This is the same long-standing mechanism that loads early-microcode archives in front of the main initramfs (Ubuntu's `early`/`early2`/`main` split relies on it too).

Appending a small gzip cpio after Fedora's XZ archive therefore adds our files without decompressing, editing, or recompressing the 252 MiB initrd. The original stays a byte-identical prefix, which the build checks with `cmp`. The verified run is proof in practice: `fdo-receive.service` exists only in the appended archive, and it ran.

**usrmerge gotcha:** in the Fedora initrd, `/bin`, `/sbin`, `/lib`, `/lib64` are symlinks into `/usr` (and `usr/sbin` → `bin`). An appended cpio entry for one of those paths could replace the symlink and break the initrd. The overlay therefore uses only canonical `usr/…` paths, and the build rejects top-level `bin|sbin|lib|lib64` entries.

### Rendezvous (TO0/TO1)

See [Rendezvous (TO0/TO1)](README.md#rendezvous-to0to1) in the overview; it applies to every OS here, and was first found on the Fedora path.

### Hook ordering

These are the white "dracut / systemd step" rows and the teal `fdo-receive.service` box in Stage 2 of the diagram.

Fedora's initrd runs NetworkManager as `nm-initrd.service`. `nm-wait-online-initrd.service` is ordered `Before=dracut-initqueue.service`, and `ip=dhcp rd.neednet=1` on the cmdline turns it on. `fdo-receive.service` sits between the two: the network is up, but dracut's initqueue loop hasn't started. That loop is where Anaconda's `anaconda-diskroot` mounts the media and where the `rd.retry` timer runs. So nothing touches `/dev/pmem0` until the ISO has been fully streamed and validated, and a long transfer doesn't trip dracut timeouts (`rd.timeout` defaults to 0). The unit is enabled by an `initrd.target.wants` symlink that the build creates. On failure, `OnFailure=emergency.target` drops to the dracut emergency shell (the development recovery shell, as on Ubuntu).

### Kickstart hand-off

`inst.ks=file:…` doesn't work for a kickstart that arrives at runtime: Anaconda resolves it in the cmdline hook, long before networking. So the cmdline has no `inst.ks=`. After TO2, `fdo-receive.sh` does what Anaconda's own `fetch-kickstart-disk` does:

1. Copy the received file to `/tmp/ks.cfg`.
2. Source `/dracut-state.sh`, `dracut-lib.sh`, and `anaconda-lib.sh`.
3. Call `parse_kickstart`, which translates initrd-relevant directives into `/etc/cmdline.d/80-kickstart.conf` and writes `/run/install/ks.cfg`.
4. Call `run_kickstart`, which regenerates the repo udev rules, replays block events, and marks `/tmp/ks.cfg.done`.

Anaconda stage2 automatically loads `/run/install/ks.cfg`. `/run` survives switch-root, which also keeps `/run/fdo/ssh-host-keys` available to `%post --nochroot`.

### Kickstart details (`config/kickstart-test.ks`)

- **Disk selection is computed in `%pre`.** It picks the largest non-removable disk, excluding `pmem*`, `zram*`, `loop*`, and `sr*`, and writes `/tmp/fdo-disk.ks` (`ignoredisk --only-use`, `clearpart`, `autopart`, `bootloader`), which is then `%include`d. This keeps the installer off `/dev/pmem0` (the RAM-backed ISO) and off the small disk carrying the FDO UEFI client.
- **SELinux.** Keys copied from outside the chroot carry the wrong label, so the chroot `%post` runs `restorecon -Rv /etc/ssh` after setting `root:root` and mode `0600`/`0644`.
- `sshd_config.d/10-fdo.conf` disables password and keyboard-interactive auth. The `fdo` user gets the onboarding key and NOPASSWD sudo. The completion marker goes to `/var/lib/fdo-autoinstall-complete`, then `poweroff`.

### Command line and memory

```text
inst.repo=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.text ip=dhcp rd.neednet=1
memmap=3732M!4G nokaslr console=tty0 console=ttyS0
```

The reservation is computed from the 3.64 GiB ISO, the same way as on Ubuntu. The QEMU test defaults to 12 GiB of RAM to leave room for Anaconda. The UKI is ~277 MiB, mostly the stock Anaconda initrd, so the BMO transfer takes about 2.6× as long as Ubuntu's.

### Runtime Flow (Fedora)

The timings come from the verified QEMU run (TCG, no KVM). See `TEST-FEDORA-UKI.md` for details.

1. **Stage 1.** fdo-uefi-rs runs TO1 (to1d verified), then TO2. The UKI arrives over BMO (~4,500 rounds, ~1.5 min), its SHA-256 is checked, and it is chainloaded.
2. **Boot.** The UEFI stub loads the kernel and the initramfs (original + appended FDO overlay). The kernel creates `/dev/pmem0` from `memmap=`, and the dracut cmdline hooks arm Anaconda's udev rule for `LABEL=Fedora-S-dvd-x86_64-44`.
3. **Network.** NetworkManager brings up DHCP and `nm-wait-online-initrd` completes (~45 s after boot).
4. **Onboarding.** `fdo-receive.service` loads the pmem modules and waits for `/dev/tpmrm0` and `/dev/pmem0`. It generates SSH host keys and runs TO1 → TO2 with credential reuse:
   - the kickstart is written to `/run/fdo/kickstart/ks.cfg`
   - the ISO is streamed to `/dev/pmem0` (65,219 chunks, ~13.5 min)
   - the server receives the SSH public keys and IP
5. **Hand-off.** The service checks the ISO9660 type and label, hands the kickstart to Anaconda (`/run/install/ks.cfg`), and waits for `/dev/disk/by-label/…` to appear.
6. **Media.** `dracut-initqueue` runs `anaconda-diskroot`, which mounts the ISO and `install.img`. switch-root into stage2 follows, with `/run` preserved.
7. **Install.** Anaconda runs the kickstart: `%pre` disk selection, package install from the DVD repo, and `%post` key copy and hardening. With `inst.text` the serial console stays quiet for the whole install, so watch VNC or wait for `reboot: Power down` (~77 min under TCG).
8. **Result.** The VM powers off. The installed system boots to `fdo-installed login:` with the FDO-registered SSH host keys and SELinux enforcing.

## Files

- `build-fedora-installer-uki.sh` — Fedora Server DVD installer UKI build (appends FDO overlay to Anaconda initramfs)
- `test-fedora-installer.sh` — End-to-end Fedora test: TPM init, FDO server, QEMU, kickstart, verification
- `config/fedora-installer.env` — Pinned Fedora ISO URL, hash, size, label, kickstart MIME, UKI filename
- `config/kickstart-test.ks` — Test kickstart (hostname, user, SSH, disk selection, key copy)
- `rootfs-fedora/` — Overlay files appended to the Fedora initramfs:
  - `etc/fdo/config.yaml` — Endpoint FSIM config (kickstart + ISO destinations)
  - `usr/lib/systemd/system/fdo-receive.service` — Runs FDO onboarding between network-online and dracut-initqueue
  - `usr/libexec/fdo/fdo-receive.sh` — Keygen, TO2, media validation, Anaconda kickstart hand-off
- `doc/fdo-uki-fedora-architecture.svg` — Architecture diagram (Fedora)
- `TEST-FEDORA-UKI.md` — Fedora discovery findings, build verification, E2E checklist
- `TODO-FEDORA-UKI.md` — Fedora phased work tracker
