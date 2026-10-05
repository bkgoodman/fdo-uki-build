# Testing the openSUSE Leap Installer UKI with FDO

## Pinned Media

openSUSE Leap 16.0 **offline** installer, x86_64. This is a kiwi-built Agama live ISO that also carries the full package repository in `/install`, so nothing is pulled from network mirrors during installation:

- File: `Leap-16.0-offline-installer-x86_64-Build178.27.install.iso`
- Size: 4,538,236,928 bytes
- SHA-512: `94411793a1878b35…4a8469971`, from the signed `.sha512` next to the ISO; openSUSE publishes no SHA-256
- SHA-256: `3c0ace90…20ac20a2ac2`, recorded by the build
- Volume label: `Install-Leap-16.0-x86_64`, on a hybrid GPT with an EFI partition plus an ISO9660 partition
- Live image: Leap_16.0 17.0.0 Build12.16; Agama `agama-yast-17.devel627`
- Leap 15.6 (YaST, AutoYaST, linuxrc) reached end of life on 2026-04-30 and is not targeted.

## Phase 0 Findings (static inspection, 2026-10-05)

| Question | Finding | Consequence |
| --- | --- | --- |
| ISO layout | `boot/x86_64/loader/{linux,initrd}`, `LiveOS/squashfs.img` (containing `LiveOS/rootfs.img`), offline repo in `/install` | Agama's `add_repos_by_dir` uses `/run/initramfs/live/install` automatically, with no extra config |
| Live root argument | baked into the initrd as `etc/cmdline.d/10-liveroot.conf`: `root=live:LABEL=Install-Leap-16.0-x86_64` | no `inst.repo` equivalent needed; the UKI cmdline repeats it explicitly |
| Initrd format | single XZ-compressed newc cpio, dracut 059 + systemd + NetworkManager, usrmerge; `usr/lib/dracut/hooks` → `../../../var/lib/dracut/hooks` | overlay appended; the build inspects hook files under `var/lib/dracut/hooks` |
| Kernel | `6.12.0-160000.35-default` | kernel and initrd versions cross-checked |
| **pmem** | `libnvdimm`, `nd_e820` present; **`nd_pmem` and its dependency `nd_btt` missing** | the build extracts both from the ISO's own `kernel-default-6.12.0-160000.35.1` RPM (signed by SUSE, vermagic checked) into `usr/lib/fdo/modules/`; `fdo-receive.sh` `insmod`s them |
| TPM, net, fs | `tpm_tis`/`tpm_crb` built in; `virtio_net`, `isofs`, `squashfs`, `overlay`, `loop` present | — |
| Networking | `nm-initrd` + `nm-wait-online-initrd` (`Before=dracut-initqueue.service`) | same unit ordering as Fedora |
| Profile pickup | `99-agama-cmdline-conf.sh` copies every `inst*`/`agama*`/`live*` arg to `/run/agama/cmdline.d/agama.conf`; `agama-autoinstall` reads `inst.auto` from there and supports `file://` | **no hand-off code**: `inst.auto=file:///run/fdo/agama/profile.json` |
| Self-update | `live-self-update` is skipped with `inst.self_update=0` (it isn't configured for openSUSE anyway) | offline-safe |
| Product id | `openSUSE_Leap` (`products.d/leap_160.yaml`); default LSM is **SELinux (enforcing)**; mandatory pattern `enhanced_base` | `restorecon` after copying keys |
| Agama 16.0 schema | no `user.sshPublicKey` (that's a 16.1 docs feature); drive `search` supports `size`, `sort`, `max` but not `and`/`or`/`not` (16.1) | user key installed by a post script; disk = biggest drive with `size > 16 GiB` |
| sshd | `sshd-gen-keys-start` → `ssh-keygen -A` (creates only missing keys); no cloud-init on the medium | FDO keys survive first boot |
| Initrd tools | bash, blkid, udevadm, ip, awk, sed, stat present; **no** `head`, `wc`, `touch` | `fdo-receive.sh` avoids them |
| CPU baseline | Leap 16 is built for **x86-64-v2** | QEMU needs `-cpu max` (see run 0) |

## Build Verification (2026-10-05)

`GO_ROOT=/home/bradgoodman/go GOPATH=/home/bradgoodman/gomods ./build-opensuse-installer-uki.sh`:

- The initrd self-check passes: the first 107,372,544 bytes of `initrd.fdo` are the original (`cmp`). The appended gzip cpio lists only:
  - `etc/fdo/config.yaml`
  - `usr/lib/fdo/modules/{nd_btt,nd_pmem}.ko`
  - `usr/lib/systemd/system/…`
  - `usr/libexec/fdo/…`
  - `usr/local/bin/fdo-endpoint`
- Merge check: the original and overlay unpacked together keep every usrmerge symlink, and `systemd-analyze verify --root=<tree> fdo-receive.service` passes.
- The profile validates against the **Agama 16.0 JSON schemas taken from the live root** (`profile.schema.json` + `storage.schema.json`, via `jsonschema`). A deliberately broken profile is rejected, which shows the check is real.
- UKI: `firmware/opensuse-leap-16.0-fdo.efi`, ~125 MiB. Sections:

| Section | Size | VMA |
| --- | --- | --- |
| `.osrel` | 0x1ef (Leap 16.0 initrd `os-release`) | 0x20000 |
| `.cmdline` | 0xf2 | 0x30000 |
| `.linux` | 0xe839f0 | 0x2000000 |
| `.initrd` | 0x6e0a6e8 | 0x2f00000 |

- Command line: `root=live:LABEL=Install-Leap-16.0-x86_64 rd.live.image inst.auto=file:///run/fdo/agama/profile.json inst.finish=poweroff inst.self_update=0 systemd.unit=multi-user.target ip=dhcp rd.neednet=1 memmap=4328M!4G nokaslr console=tty0 console=ttyS0`

## End-to-End Runs (pe2, QEMU TCG, 16 GiB, `-cpu max`)

Components:

- UKI `e46f19ce…0e943710`
- the current go-fdo `examples/cmd` server (`~/bkgvm/server-fedora`)
- `efi-disk-release.img` (md5 `3d3eaf5f…`, mtime 2026-10-02; untouched by these runs)
- `quick-di-tpm`

```bash
DEPLOY=1 DEPLOY_HOST=pe2 ./build-opensuse-installer-uki.sh            # build host
FDO_SERVER=$HOME/bkgvm/server-fedora FDO_QUICK_DI=$HOME/quick-di-tpm \
  FDO_EFI_DISK=$HOME/bkgvm/efi-disk-release.img ./test-opensuse-installer.sh   # pe2
```

### Run 0: kernel panic, CPU model

Stage 1 and the BMO transfer succeeded, then the openSUSE kernel panicked at `Run /init` with `Attempted to kill init! exitcode=0x00000004`. The faulting opcode bytes `66 48 0f 3a 22 c8 01` are `pinsrq`, an SSE4.1 instruction: Leap 16 userspace targets **x86-64-v2**, and QEMU's default TCG CPU model is v1. The fix is `-cpu max` (harness `QEMU_CPU`, default `max`). Real hardware is v2+, and Ubuntu and Fedora still build for v1.

### Run 1: installed, one issue found

| Phase | Result | Time |
| --- | --- | --- |
| Stage 1 | TO0 blob → TO1 (to1d verified) → TO2 → BMO of the 130,668,002-byte UKI, chainloaded | ~1 min |
| Initrd | `fdo-receive.service` started ~40 s after boot; `nd_btt`/`nd_pmem` loaded; `/dev/pmem0` = 4,538,236,928 bytes | — |
| Stage 2 | TO1 → TO2 at `http://10.0.2.2:8080` with credential reuse; profile 3,117 bytes → `/run/fdo/agama/profile.json` | — |
| ISO | 4,538,236,928 bytes → `/dev/pmem0` (75,638 chunks) | ~8.4 min |
| Media | `TYPE=iso9660 LABEL=Install-Leap-16.0-x86_64`; by-label link → **`/dev/pmem0p2`**, the hybrid GPT's ISO partition, which dmsquash-live mounted fine | — |
| Agama | live system up, `agama-autoinstall` ran the profile, offline repo, unattended, `inst.finish=poweroff` | ~19 min |
| Total | `reboot: Power down` at 1,686 s of guest uptime | ~28 min |

Installed system (every item verified over strict SSH):

- hostname `fdo-installed`, user `fdo` (wheel) with NOPASSWD sudo, completion marker present
- password auth rejected (`Permission denied (publickey)`)
- the 3 host keys identical to the FDO-registered keys (`diff`)
- strict host-key check with `known_hosts` built only from `server.log`: no TOFU prompt
- SELinux `Enforcing`; keys `sshd_key_t`, `authorized_keys` `ssh_home_t`; no sshd AVCs
- `sda` only: ESP + btrfs (snapshots) + swap; no cloud-init

**Issue found:** Agama copies the installer's kernel parameters into the installed system's GRUB config. The installed system booted with `memmap=4328M!4G nokaslr systemd.unit=multi-user.target`. That reserves 4.2 GiB of RAM as a fake pmem disk on every boot (it showed up as `pmem0`/`pmem1`). Anaconda doesn't do this. **Fix:** the profile's chroot post script strips those three from `GRUB_CMDLINE_LINUX_DEFAULT` and runs `update-bootloader --refresh`. Only the profile changed; the UKI didn't need rebuilding.

### Run 2: verified (with the bootloader fix)

Same UKI as run 1; only the profile changed (profile SHA-256 differs; it still validates against the 16.0 schema).

| Phase | Result |
| --- | --- |
| Stage 1 + 2 | identical to run 1: TO0 → TO1 → TO2 + BMO, then TO1 → TO2 with credential reuse, profile + ISO (~8.7 min) |
| Install | `reboot: Power down` at 1,711 s of guest uptime (~28.5 min) |

Installed system, verified over strict SSH with a `known_hosts` built only from `server.log`:

- [x] Boots to `fdo-installed login:`; openSUSE Leap 16.0
- [x] `/var/lib/fdo-autoinstall-complete` contains `FDO_AUTOINSTALL_COMPLETE`
- [x] `fdo` (wheel) has NOPASSWD sudo; password auth rejected (`Permission denied (publickey)`)
- [x] `/etc/ssh/ssh_host_*.pub` identical to the FDO-registered keys (3 keys, `diff`); strict SSH succeeds, with no TOFU
- [x] SELinux `Enforcing`; no sshd AVC denials
- [x] **Kernel command line clean:** `… console=tty0 console=ttyS0 mitigations=auto quiet security=selinux selinux=1`, with no `memmap=`, `nokaslr` or `systemd.unit=`; no pmem devices; the VM's full 4 GiB of RAM is available
- [x] **After a reboot:** strict SSH still succeeds, the host keys are unchanged, and the command line is still clean
- [x] Installed only onto the 24 GiB disk; `efi-disk-release.img` unchanged (mtime predates the runs)
- [x] No cloud-init
