# Testing the ROS 2 (Lyrical) Installer UKI with FDO

## Pinned Media and Sources

ROS 2 is installed on top of Ubuntu, so there are two inputs.

**Ubuntu 26.04.1 LTS live-server ISO**, identical to the Ubuntu path (`config/ubuntu-installer.env`):

- `ubuntu-26.04.1-live-server-amd64.iso`, 2,927,861,760 bytes, SHA-256 `cc8a95cd…a117f1d927`
- kernel `7.0.0-30-generic`; Subiquity snap revision 7403
- default install source `ubuntu-server` = `ubuntu-server-minimal.ubuntu-server.squashfs` layered on `ubuntu-server-minimal.squashfs` (709 packages in its dpkg status)

**ROS 2 Lyrical Luth** (May 2026; Tier 1: Ubuntu 26.04 "resolute" amd64/arm64), `config/ros2-installer.env`:

- ROS snapshot `http://snapshots.ros.org/lyrical/2026-09-18/ubuntu` (Release dated 2026-10-02 03:48 UTC), signed by the ROS snapshot key `4B63 CF8F DE49 746E 98FA 01DD AD19 BAB3 CBF1 25EA`. That is a different key from the main repo's `C1CF 6E31 … AB17 C654`.
- Ubuntu snapshot `http://snapshot.ubuntu.com/ubuntu/20261002T040000Z` (`resolute`, `-updates`, `-security`), signed by the normal Ubuntu archive key
- packages: `ros-lyrical-ros-base`, `ros-lyrical-demo-nodes-cpp`, `ros-lyrical-demo-nodes-py`
- `ros2-apt-source_1.3.0.resolute_all.deb` (GitHub release, SHA-256 `e70bc980…02ef69`)

## Phase 0 Findings (2026-10-07)

| Question | Finding | Consequence |
| --- | --- | --- |
| Which ROS 2? | Lyrical Luth (2026 LTS); packages.ros.org has `resolute`, with 2,684 `ros-lyrical-*` packages | same Ubuntu 26.04.1 ISO as the Ubuntu path |
| Is ROS on the ISO? | no; the pool (1.2 GiB) has no ROS packages | ROS needs its own source → **one more FDO payload** |
| Reproducibility | packages.ros.org changes daily (the Release was dated two days before the test); snapshots.ros.org keeps immutable syncs ("useful if you bundle ROS packages into an artifact") | pin a ROS snapshot + a matching Ubuntu snapshot |
| Resolver | host apt 2.4 (Ubuntu 22.04 build host) verifies and resolves resolute indexes in a private apt root; `docker` not usable on the build host | no container; any Debian/Ubuntu build host |
| Bundle size | ros-base + demo nodes: 457 packages (empty system), 134 MB download, 588 MB installed | fits in `/run` with a raised cap |
| `/run` in the casper initramfs | `mount -t tmpfs -o size=${RUNSIZE:-10%}`; `initramfs.runsize=` on the cmdline overrides it; `mount -n -o move /run ${rootmnt}/run` at switch-root | `initramfs.runsize=50%`; the bundle survives into the live system |
| Subiquity apt config | `mirror-selection.primary`, `geoip`, and pass-through curtin keys (`security`) | install-time mirror pinned to the Ubuntu snapshot |
| casper `ORDER` | still has `20iso_scan` and `99casperboot` anchors | Ubuntu hooks reused unchanged; `21fdo-ros2-check` added after `20fdo-receive` |

## Build Verification (2026-10-07)

`GO_ROOT=/home/bradgoodman/go GOPATH=/home/bradgoodman/gomods ./build-ros2-installer-uki.sh`

### Finding: the empty-system closure is not enough

The first bundle was the closure against an empty dpkg status (457 packages). `apt-get -s` against that repo passed. The **real** test was a chroot of the ISO's `ubuntu-server` layer (overlayfs over the two squashfs layers, `unshare -n`, so no network) running `install-ros2-bundle.sh`, and it failed:

```text
E: Unable to satisfy dependencies. Reached two conflicting assignments:
   1. util-linux:amd64 is selected for install
   2. util-linux:amd64 PreDepends libuuid1 (= 2.41.3-3ubuntu2)
   3. libuuid1:amd64=2.41.3-3ubuntu2 conflicts with other versions of itself
```

`uuid-dev 2.41.3-3ubuntu2.2` from the snapshot pins `libuuid1 (= 2.41.3-3ubuntu2.2)`. The base has `util-linux 2.41.3-3ubuntu2`, which pre-depends on the old `libuuid1` exactly, and the bundle had no newer `util-linux`.

**Fix:** also resolve against the ISO's installed-base dpkg status and merge. That gives 22 co-upgrades (`bsdextrautils eject fdisk libblkid1 libexpat1 libfdisk1 liblastlog2-2 libmount1 libpython3.14{,-minimal,-stdlib} libsmartcols1 libsqlite3-0 libssl3t64 libuuid1 mount python3.14{,-minimal} util-linux util-linux-extra uuid-runtime zlib1g`), 10 of them new to the bundle, for **467 packages, 132 MiB**. The build now simulates the offline install onto the empty status (457 packages) **and** the base status (357 packages: 335 new + 22 upgrades) and fails if either is unsatisfiable. Re-running the chroot test with the merged bundle passed: `25 upgraded, 335 newly installed`, then `ros2-apt-source`.

**Chroot smoke test:** `ros2 run demo_nodes_cpp talker` → `ros2 run demo_nodes_py listener`: `I heard: [Hello World: 2]`, `[Hello World: 3]`.

**Consequence for the install:** Subiquity applies security updates before the late-commands run, so the target must never be *newer* than the bundle's snapshot. The autoinstall therefore pins Subiquity's primary and security mirrors to `UBUNTU_SNAPSHOT_URL`, and the builder checks that it does.

### Reproducibility

Two bundle builds from the same snapshots: all 467 `.deb`s, `Packages`, `MANIFEST` and `BUNDLE-INFO` were identical. `Release` differed once because `apt-ftparchive` saw its own half-written output file in the directory (`0 Release` entries). Fixed by writing to `../Release.tmp`, then `mv`. `tar` uses `--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner`.

### Artifacts

| Artifact | Size | SHA-256 |
| --- | --- | --- |
| `firmware/ubuntu-26.04.1-ros2-lyrical-fdo.efi` | 111,079,906 (106 MiB) | `748ec07d…3ff03825e0f` |
| `firmware/ros2-lyrical-2026-09-18-bundle.tar` | 137,451,520 (132 MiB) | `25235855…c091cd72` |
| `build-ros2/initrd.fdo` (repacked) | 90 MiB | `fd7701d7…4293b6ee` |
| `build-ros2/initrd.original` | 96 MiB | `7aeb757e…1a1b8335` |

UKI sections: `.osrel` 0x19a (the ISO initrd's `etc/os-release`, "Ubuntu 26.04.1 LTS") @0x20000, `.cmdline` 0xaa @0x30000, `.linux` 0x107e988 @0x2000000, `.initrd` 0x59612dd @0x3100000.

Command line: `boot=casper ip=dhcp live-media=/dev/pmem0 memmap=2796M!4G nokaslr initramfs.runsize=50% autoinstall subiquity.autoinstallpath=/autoinstall.yaml console=ttyS0 console=tty0`

Initrd checks: the premount `ORDER` reads `… 20fdo-receive`, `21fdo-ros2-check`, `20iso_scan …`; `etc/fdo/config.yaml` has the `application/vnd.ros2.apt-bundle+tar` destination `/run/fdo/ros2/ros2-bundle.tar`.

Selected bundle contents (`MANIFEST`): `ros-lyrical-ros-base 0.13.0-3resolute.20260915.154859`, `ros-lyrical-rclcpp 32.0.3-1resolute.20260915.061505`, `ros-lyrical-rmw-fastrtps-cpp 9.4.10-…`, `ros-lyrical-fastdds 3.6.2-…`, 202 `ros-lyrical-*` packages in total.

## End-to-End Runs (pe2, QEMU TCG, 8 GiB, `-cpu max`)

Components:

- UKI `748ec07d…`, bundle `25235855…`
- `~/bkgvm/server` and `~/bkgvm/efi-disk-release.img`: the matching pair, both updated 2026-10-06 17:10 ("capflags"; md5 `bcff3386…` / `b4525ac8…`)
- `quick-di-tpm`

```bash
DEPLOY=1 DEPLOY_HOST=pe2 ./build-ros2-installer-uki.sh                      # build host
FDO_SERVER=$HOME/bkgvm/server FDO_QUICK_DI=$HOME/quick-di-tpm \
  FDO_EFI_DISK=$HOME/bkgvm/efi-disk-release.img ./test-ros2-installer.sh   # pe2
```

### Run 1: ROS 2 installed; one late-command bug

| Phase | Result | Time (server clock) |
| --- | --- | --- |
| Stage 1 | TO0 blob → TO1 (to1d verified) → TO2 → BMO of the 111,079,906-byte UKI, chainloaded | 11:57:14 → 11:58:02 (48 s) |
| Boot → Stage 2 TO2 | kernel + `20fdo-receive` (DHCP, TPM, pmem, keygen) → TO1 → TO2 with credential reuse | 11:58:40 |
| Payload 1 | autoinstall → `/run/fdo/autoinstall/user-data` | 11:58:41 |
| Payload 2 | ROS 2 bundle, 137,451,520 bytes → `/run/fdo/ros2/ros2-bundle.tar` (`Payload streamed to …`) | 11:58:41 → 11:58:59 (**18 s**) |
| Payload 3 | ISO, 2,927,861,760 bytes → `/dev/pmem0` | → 12:05:22 (6 min 23 s) |
| Credentials | ed25519 / ecdsa / rsa host keys + `10.0.2.15` registered | 12:05:22 |
| Subiquity | autoinstall accepted (`Mirror/apply_autoinstall_config` with the snapshot mirror); partitioning, extract, curthooks, security updates from the snapshot | ~12:14 → 13:11 |
| Late-commands 0–6 | keys copied, cloud-init guard, **bundle unpacked from `/run` and ROS 2 installed offline** | 13:11 → ~13:15 |
| Late-command 7 | **failed**, exit status 2 → "An error occurred" | 13:15 |

The installed target (inspected from the installer's error shell) already had `ros-lyrical-ros-base 0.13.0-3resolute.20260915.154859` and `ros-lyrical-demo-nodes-cpp`, plus the co-upgraded `util-linux`/`libuuid1 2.41.3-3ubuntu2.2`, and `/var/lib/fdo-ros2` contained only `BUNDLE-INFO MANIFEST SHA256SUMS install-ros2-bundle.sh packages.txt`.

**Bug:** the late-command that restores archive.ubuntu.com ran `sed -i … /target/etc/apt/sources.list.d/*.sources` from the live system. `ros2-apt-source` installs `ros2.sources` as an **absolute symlink** to `/usr/share/ros-apt-source/ros2.sources`. Seen from the live system, that symlink points into the live root, where the file doesn't exist, so `sed` fails (and `sed -i` would have replaced the symlink with a file anyway). The single `sed` also pointed the security stanza at archive.ubuntu.com. **Fix (autoinstall only, no rebuild):** `curtin in-target` rewrites just `/etc/apt/sources.list.d/ubuntu.sources`, with archive.ubuntu.com for `resolute resolute-updates resolute-backports` and security.ubuntu.com for `resolute-security`.

### Run 2: with the late-command fix

Same UKI and bundle as run 1; only the autoinstall changed (SHA-256 `30913729…1f25108b`).

| Phase | Result | Time (server clock) |
| --- | --- | --- |
| Stage 1 | TO0 → TO1 → TO2 → BMO (111,079,906 bytes) → chainload | → 13:20:59 |
| Stage 2 | TO1 → TO2 with credential reuse: autoinstall (13:21:38), ROS 2 bundle (13:21:58, ~20 s), ISO (13:28:41, ~6.7 min); SSH keys + IP registered (13:28:41) | ~8 min |
| Subiquity | snapshot mirror; partitioning, extract, curthooks (kernel step slower than run 1 while pe2 was busy), security updates from the snapshot | ~13:37 → 14:44 |
| Late-commands 0–9 | all succeeded. `install-ros2-bundle.sh` (command 6) took **5 min 21 s** (installer log, 18:42:42 → 18:48:03 UTC), and the in-target `ubuntu.sources` rewrite (command 7) 11 s | ~14:42 → 14:49 |
| Total | `reboot: Power down` at 5,286 s of guest uptime | ~89 min (TCG, shared host) |

Installed system: the qcow2 was booted with SSH forwarded. Every check below ran over strict SSH (`StrictHostKeyChecking=yes`) with a `known_hosts` built **only** from the three keys in `server.log`:

- [x] Boots; hostname `fdo-ros2`; Ubuntu 26.04.1 LTS; kernel `7.0.0-38-generic` (the ISO has `-30`: security updates came from the pinned snapshot)
- [x] `/var/lib/fdo-autoinstall-complete` = `FDO_AUTOINSTALL_COMPLETE`; `fdo` has NOPASSWD sudo
- [x] Password auth rejected: `fdo@localhost: Permission denied (publickey).`
- [x] `/etc/ssh/ssh_host_*_key.pub` **identical** to the FDO-registered keys (3 keys, `diff`); no TOFU prompt
- [x] Kernel command line clean: `… ro console=ttyS0 console=tty0 crashkernel=…`, with no `memmap=`, `nokaslr`, `initramfs.runsize=` or `autoinstall`; no `/dev/pmem*`; 3.3 GiB of the VM's 4 GiB visible
- [x] Installed only onto `sda` (24 GiB: ESP + ext4 root); `efi-disk-release.img` unchanged (md5 `b4525ac8…`, same as before the runs)
- [x] **ROS 2:** `ros-lyrical-ros-base 0.13.0-3resolute.20260915.154859`, `demo-nodes-cpp/-py 0.37.9-…`, `ros2-apt-source 1.3.0~resolute`; **202** `ros-lyrical-*` packages installed (`ii`), exactly the bundle's set. dpkg also has 3 `un` entries for unchosen alternatives (`ros-lyrical-rmw-connextdds`, `ros-lyrical-rmw-cyclonedds-cpp`, `ros-lyrical-fastrtps`). Co-upgraded `util-linux`/`libuuid1 2.41.3-3ubuntu2.2`; `/opt/ros/lyrical` 156 MiB
- [x] `~fdo/.bashrc` sources `/opt/ros/lyrical/setup.bash`; `ROS_DISTRO=lyrical`; `ros2 pkg list` → 197 packages
- [x] **C++ talker → Python listener** over the default RMW (Fast DDS): `Publishing: 'Hello World: 1'…`, `I heard: [Hello World: 5]`, `[6]`, `[7]`
- [x] `/var/lib/fdo-ros2` keeps only `BUNDLE-INFO MANIFEST SHA256SUMS install-ros2-bundle.sh packages.txt` (the `.deb`s were removed)
- [x] apt sources: `ubuntu.sources` = archive.ubuntu.com (`resolute resolute-updates resolute-backports`) + security.ubuntu.com (`resolute-security`); `ros2.sources` is still the symlink → `packages.ros.org/ros2/ubuntu resolute`
- [x] Online `apt-get update` works with these sources: `ros-lyrical-ros-base` installed `…20260915.154859` (snapshot), candidate `…20260919.194435` from packages.ros.org; 16 ROS and 30 other packages upgradable. The device moves forward from the pinned baseline when the operator chooses.
- [x] cloud-init drop-in `99-fdo-preserve-ssh-keys.cfg` present; `cloud-init status`: disabled
- [x] **After a reboot:** strict SSH still succeeds, host keys unchanged, command line still clean, `ros2 pkg list` → 197
