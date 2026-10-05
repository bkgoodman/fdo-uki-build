# TODO: FDO openSUSE Leap (Agama) Installer UKI

## Phase 0: Discovery

- [x] Pin the Leap 16.0 offline installer ISO (name, URL, size, SHA-512); Leap 15.6 is EOL
- [x] Confirm the kiwi live ISO layout (`boot/x86_64/loader`, `LiveOS/squashfs.img`, `/install` repo, hybrid GPT)
- [x] Confirm the live-root argument (`root=live:LABEL=…`, baked into the initrd)
- [x] Confirm the initrd format (single XZ cpio), usrmerge, and the `var/lib/dracut/hooks` symlink
- [x] Module check: `nd_pmem` and `nd_btt` missing → added from the ISO's own `kernel-default` RPM
- [x] Confirm NM-in-initrd ordering relative to `dracut-initqueue`
- [x] Confirm the Agama profile pickup (`inst.auto=file://…` via `/run/agama/cmdline.d`): no hand-off needed
- [x] Confirm the offline repo pickup (`/run/initramfs/live/install`)
- [x] Agama 16.0 schema limits (no `user.sshPublicKey`, no `and`/`or`/`not` in searches)
- [ ] Verify the `.sha512.asc` signature in the build (opt-in, needs the openSUSE key)

## Phase 1: Build

- [x] `build-opensuse-installer-uki.sh` without touching the Ubuntu/Fedora builders
- [x] Append-only initrd overlay with a byte-identical original-prefix self-check
- [x] Extract missing kernel modules from the ISO's RPM without `rpm2cpio` (Python payload reader); vermagic check
- [x] Assert the live-root label, NM ordering and Agama `inst.*` forwarding in the initrd
- [x] Use openSUSE's own `os-release` for `.osrel`
- [x] Validate the profile against the Agama 16.0 schemas (with a negative control)
- [x] `systemd-analyze verify` on the merged initrd tree

## Phase 2: Runtime (QEMU)

- [x] `-cpu max` in the harness (Leap 16 needs x86-64-v2)
- [x] Stage 1 BMO + chainload of the ~125 MiB UKI (~1 min)
- [x] `fdo-receive.service` after network-online, before initqueue; `/dev/pmem0` via the appended `nd_pmem`
- [x] Profile + 4.2 GiB ISO streamed (~8.4 min); label check passes
- [x] dmsquash-live mounts the live root from `/dev/pmem0` (by-label → `pmem0p2`)
- [x] Agama runs the profile unattended, from the offline repo; powers off (~28 min total)
- [x] Installed system: hostname, user, sudo, key-only SSH, marker, SELinux enforcing
- [x] Host keys identical to the FDO-registered keys; strict SSH, no TOFU
- [x] Strip installer-only kernel args (`memmap=`, `nokaslr`, `systemd.unit=`) from the installed GRUB config
- [x] Re-verify with the bootloader fix (run 2), including after a reboot

## Phase 3: Hardening / Production

- [ ] **Live installer exposure:** during the install the Agama live system prints a random root password on the console and runs its web UI and sshd. Consider `systemd.mask=sshd.service` and `inst.remote=0` (16.1+), or `live.password_hash`.
- [ ] Bare-metal validation (the user's next step once the VM path is solid)
- [ ] Leap 16.1 (newer Agama: `user.sshPublicKey`, search operators, `inst.remote=0`)
- [ ] Secure Boot: signed UKI; the appended, unsigned overlay and `insmod` of extra modules vs kernel lockdown
- [ ] Shared items with Ubuntu/Fedora: TO0/RV re-registration policy, capacity checks, server-side key persistence, vendor-supplied UKI
