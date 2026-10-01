# TODO: FDO Fedora Installer UKI

## Phase 0: Discovery

- [x] Pin Fedora 44 Server DVD (name, URL, size, SHA-256 from the signed CHECKSUM)
- [x] Confirm ISO layout (`images/pxeboot`, `images/install.img`, `Packages`, `repodata`, label)
- [x] Confirm initrd format (single XZ cpio) and usrmerge layout
- [x] Confirm pmem (`nd_e820`, `nd_pmem`), TPM (built-in), `isofs` availability
- [x] Confirm NetworkManager-in-initrd ordering relative to `dracut-initqueue`
- [x] Determine runtime kickstart hand-off (`parse_kickstart` + `run_kickstart` → `/run/install/ks.cfg`)
- [x] Confirm dracut timers don't fire during a long transfer
- [ ] Verify the CHECKSUM file's GPG signature in the build (opt-in, needs the Fedora 44 key)

## Phase 1: Build

- [x] `build-fedora-installer-uki.sh` without touching the Ubuntu builders
- [x] Append-only initrd overlay with byte-identical original prefix self-check
- [x] Guard against usrmerge symlink clobbering
- [x] Assert required modules and Anaconda/NM interfaces exist in the initrd
- [x] Use Fedora's own `os-release` for `.osrel`
- [x] Static endpoint build (`CGO_ENABLED=0`) so it runs regardless of initrd libc
- [x] `ksvalidator`, `shellcheck`, `systemd-analyze verify` clean

## Phase 2: Runtime (QEMU)

- [x] Stage 1 BMO delivery and chainload of the ~277 MiB UKI (~1.5 min)
- [x] `fdo-receive.service` runs after network-online, before initqueue
- [x] Kickstart + 3.6 GiB ISO streamed (~13.5 min); label check passes
- [x] Anaconda finds `install.img` on `/dev/pmem0` via `inst.repo=hd:LABEL=…`
- [x] Kickstart picked up from `/run/install/ks.cfg`; unattended install; poweroff
- [x] Installed system: hostname, user, sudo, key-only SSH, completion marker
- [x] SSH host keys identical to FDO-registered keys, survive reboot; SELinux clean
- [x] Record transfer/install time in TEST-FEDORA-UKI.md
- [x] Harness registers TO0 blob so the endpoint can run TO1 → TO2
- [ ] Record peak guest memory
- [ ] Optional `-accel kvm` in the harness for faster iteration
- [ ] Anaconda progress visibility on serial (e.g. `inst.cmdline` or log tail)

## Phase 3: Production Hardening

- [ ] Shrink the UKI: the Anaconda initrd carries broad firmware/driver sets (252 MiB); consider a trimmed initrd or delivering the initrd separately
- [ ] Secure Boot: signed UKI, and reconcile `memmap=` + appended initrd with kernel lockdown / measured boot
- [ ] OS vendor (Fedora) supplying the UKI + ISO directly
- [ ] Replace direct installer TO2 with TO0/RV re-registration and normal TO1 (same as Ubuntu)
- [ ] Block-device capacity check before streaming to `/dev/pmem0`
- [ ] Production kickstart secret/identity policy (replace test password hash)
- [ ] Physical UEFI hardware validation (RAM above 4 GiB must fit the reservation)
- [ ] Persist received SSH host keys server-side (shared with the Ubuntu TODO)
