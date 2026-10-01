# Testing the Fedora Installer UKI with FDO

## Pinned Media

Fedora 44 Server DVD, x86_64 (offline install — the full package repository is on the ISO, so nothing is pulled from untrusted network mirrors during installation):

- File: `Fedora-Server-dvd-x86_64-44-1.7.iso`
- Size: 3,913,023,488 bytes
- SHA-256: `85837793bfa36db6bc709b4cecd2ec116951b87d9c53c3d95eb2fac8dcf7cf1f` (from the signed `Fedora-Server-44-1.7-x86_64-CHECKSUM`)
- Volume label: `Fedora-S-dvd-x86_64-44`
- `/images/pxeboot/vmlinuz`: `4b37e4e5…1de2` (matches `.treeinfo`)
- `/images/pxeboot/initrd.img`: `dec8bd9b…b0fc` (matches `.treeinfo`), 263,821,364 bytes

## Phase 0 Findings (static inspection, 2026-10-01)

| Question | Finding | Consequence |
| --- | --- | --- |
| Initrd format | Single XZ-compressed newc cpio, **no** early-microcode prefix | Overlay is appended; original is never unpacked/repacked |
| Kernel | `6.19.10-300.fc44.x86_64`; initrd is dracut-108-6.fc44 | vmlinuz/initrd versions cross-checked by the build |
| usrmerge | `/bin`, `/sbin`, `/lib`, `/lib64` → `usr/…`; `usr/sbin` → `bin` | Overlay uses only canonical `usr/` paths; `parse-kickstart` lives at `usr/bin/` |
| pmem | `libnvdimm`, `nd_e820`, `nd_pmem` loadable (`platform:e820_pmem*` alias) | `memmap=NM!4G` works without adding modules |
| TPM | `tpm_tis`, `tpm_crb` built in | `/dev/tpmrm0` available early |
| ISO9660 | `isofs` loadable | — |
| Networking | NetworkManager in initrd: `nm-initrd.service`, `nm-wait-online-initrd.service` (`Before=dracut-initqueue.service`, `Before=network-online.target`) | `fdo-receive.service` orders `After=network-online.target nm-wait-online-initrd.service`, `Before=dracut-initqueue.service` |
| Kickstart | `inst.ks=file:` is resolved in the cmdline hook (`26-parse-anaconda-kickstart.sh`) — far too early | No `inst.ks=` on the cmdline; `fdo-receive.sh` performs `fetch-kickstart-disk`'s steps (`parse_kickstart` + `run_kickstart`). `parse_kickstart` writes `/run/install/ks.cfg`, which Anaconda stage2 loads automatically |
| Missing `inst.ks` | Anaconda adds a harmless OEMDRV rule + `wait_for_disks` (5 s) | — |
| `%include` of a `%pre`-generated file | initrd `parse-kickstart` uses `missingIncludeIsFatal=False` | Verified by running the initrd's own `parse-kickstart` in a chroot: rc=0, emits `inst.text`, `ip=dhcp` |
| Timeouts | `rd.timeout` default 0 (no systemd device job timeout); `rd.retry` counter lives inside the initqueue loop, which starts after us | 8+ minute transfer does not trip dracut timers |
| cloud-init | Not on the Server DVD | No key-regeneration guard needed; `sshd-keygen@` only creates missing keys |
| Tools in initrd | bash, blkid, udevadm, ip, awk, sed, stat, python3 present; **no** `head`, `wc`, `touch` | `fdo-receive.sh` avoids them |
| Comps | `@^server-product-environment` present on the DVD | Used in the kickstart |

## Build Verification (2026-10-01)

`GO_ROOT=/home/bradgoodman/go GOPATH=/home/bradgoodman/gomods ./build-fedora-installer-uki.sh`:

- Initrd self-check: `cmp` confirms the first 263,821,364 bytes of `initrd.fdo` are the original; the appended gzip cpio starts at that (4-byte aligned) offset and lists only `etc/fdo/…`, `usr/lib/systemd/system/…`, `usr/libexec/fdo/…`, `usr/local/bin/fdo-endpoint`.
- Merge check: original + overlay extracted into one tree keeps all usrmerge symlinks; `systemd-analyze verify --root=<tree> fdo-receive.service` passes (Fedora 44 systemd).
- `ksvalidator -v F44 config/kickstart-test.ks`: OK.
- `shellcheck -S warning` on the new scripts: clean.
- UKI sections:

| Section | Size | VMA |
| --- | --- | --- |
| `.osrel` | 0x2da (Fedora 44 initrd `os-release`) | 0x20000 |
| `.cmdline` | 0x7b | 0x30000 |
| `.linux` | 0x119f968 | 0x2000000 |
| `.initrd` | 0x10328e33 | 0x3200000 |

- UKI: `firmware/fedora-44-server-dvd-fdo.efi`, ~277 MiB (the Anaconda initrd alone is 252 MiB — about 2.6× the Ubuntu UKI; expect a proportionally longer BMO transfer).
- Command line: `inst.repo=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.text ip=dhcp rd.neednet=1 memmap=3732M!4G nokaslr console=tty0 console=ttyS0`

## End-to-End Test

Run on the QEMU test host (the operator runs the FDO server; see `test-fedora-installer.sh`):

```bash
DEPLOY=1 DEPLOY_HOST=<testhost> ./build-fedora-installer-uki.sh   # on the build host
./test-fedora-installer.sh                                         # on the test host
./boot-installed-vm.sh /tmp/fdo-fedora-test-<timestamp>/target.qcow2
```

QEMU defaults to 12 GiB RAM (`QEMU_MEM`), since 3.7 GiB above 4 GiB is reserved for `/dev/pmem0`.

### Expected checkpoints (serial log)

1. fdo-uefi-rs TO2 → BMO delivers the Fedora UKI → chainload.
2. `FDO-DIAG: fdo-receive starting`, NICs/IPs listed, `/dev/tpmrm0` and `/dev/pmem0` present.
3. SSH host keys generated; `FDO installer: starting TO2`.
4. `Kickstart received: <n> bytes`, then the ISO streamed to `/dev/pmem0`.
5. `pmem0 TYPE=iso9660 LABEL=Fedora-S-dvd-x86_64-44`, `handing off to Anaconda`.
6. `anaconda: found …/images/install.img`, stage2 starts in text mode with the kickstart.
7. `%pre` logs `FDO: installing to /dev/sdb` (the 24 GiB disk), packages install, `%post` runs, VM powers off.

### Results — Verified 2026-09-30 (pe2, QEMU TCG, 12 GiB)

Components: UKI `1a8f8305…6470`, current go-fdo `examples/cmd` server (includes BMO image-hash fix `7d8f755`), `efi-disk-release.img` `9512aaf0…` (md5), `quick-di-tpm`.

| Phase | Result | Time |
| --- | --- | --- |
| Stage 1 TO1 | to1d received and verified (TO0 blob registered by the harness) | seconds |
| Stage 1 BMO | 290,291,682-byte UKI inline, unsigned Model 1 (hash-checked), chainloaded | ~1.5 min |
| Fedora kernel + initrd | booted; `fdo-receive.service` started after NM online, before initqueue | ~45 s |
| Stage 2 TO1 → TO2 | `Attempting TO2 with server 1: http://10.0.2.2:8080`, credential reuse | — |
| Kickstart | 2,777 bytes → `/run/fdo/kickstart/ks.cfg` | ~2 s |
| ISO → `/dev/pmem0` | 3,913,023,488 bytes, 65,219 × 60,000-byte chunks, ~4.9 MB/s | ~13.5 min |
| Media check | `TYPE=iso9660 LABEL=Fedora-S-dvd-x86_64-44`, by-label link present | — |
| Anaconda 44.30 | `anaconda-import-initramfs-certs` (kickstart path), unattended text install, `%pre`/`%post`, poweroff | ~77 min (TCG) |
| Total | guest uptime at `reboot: Power down`: 5,506 s | ~92 min |

Installed system (booted from `target.qcow2`, 2.4 GiB used):

- [x] Server log shows `Received public key registration` with ed25519/ecdsa/rsa + `ip_address: 10.0.2.15`
- [x] Boots to `fdo-installed login:`; Fedora Linux 44 (Server Edition)
- [x] `/var/lib/fdo-autoinstall-complete` contains `FDO_AUTOINSTALL_COMPLETE`
- [x] `fdo` (wheel) has NOPASSWD sudo; password auth rejected (`Permission denied (publickey,…)`)
- [x] `/etc/ssh/ssh_host_*.pub` identical to the FDO-registered keys (`diff`: 3 keys identical); unchanged after a reboot
- [x] `ssh -i fdo-onboarding-key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<keys from server.log>` succeeds — no TOFU, before and after reboot
- [x] SELinux `Enforcing`; host keys `root:root 0600/0644`, `sshd_key_t`; `ausearch -m avc -c sshd`: no matches
- [x] Installed only onto the 24 GiB disk (`sda`: ESP, `/boot`, LVM root); FDO EFI client disk md5 unchanged
- [x] `cloud-init` not installed

### Lessons from the run

- **TO0 is required.** go-fdo-endpoint only reaches TO2 via a TO1 blob or an RV bypass directive; the quick-di RV has neither, so without TO0 the Stage 2 endpoint fails with `all TO2 attempts failed` (Stage 1's UEFI client happens to fall back). `test-fedora-installer.sh` now registers the blob (`-to0 … -to0-guid … -ext-http 10.0.2.2:8080`) after starting the server — both stages then do real TO1 → TO2 and the UKI still contains no server address.
- **Anaconda is quiet on serial.** With `inst.text` the tmux UI on `ttyS0` printed nothing after `anaconda … started` for the whole install; low guest CPU and an untouched qcow2 were *not* signs of a hang (packages are staged in RAM first). Watch VNC (`:3`) or wait for `reboot: Power down`.
- **TCG is slow.** The harness (like the Ubuntu one) runs QEMU without KVM; Anaconda took ~77 min. Adding `-accel kvm` would shorten this substantially.
- **Harness hygiene.** The harness kills only PIDs it recorded in `$WORKDIR/pids.txt`; the test host runs other VMs/swtpm/servers.
