# TODO: FDO ROS 2 (Lyrical Luth on Ubuntu 26.04.1) Installer UKI

## Phase 0: Discovery

- [x] Pick the distribution: ROS 2 **Lyrical Luth** (May 2026); its Tier 1 platform is Ubuntu 26.04 "resolute" amd64, the same Ubuntu release as the existing Ubuntu path
- [x] Confirm `ros-lyrical-ros-base` exists for resolute in packages.ros.org
- [x] Pin immutable package sources: `snapshots.ros.org/lyrical/2026-09-18` (own signing key, fingerprint `4B63 CF8F … CBF1 25EA`) and `snapshot.ubuntu.com/ubuntu/20261002T040000Z`
- [x] Confirm host `apt` (2.4, any Debian/Ubuntu build host) resolves and verifies resolute indexes from a private apt root, no container needed
- [x] Size the bundle: ros-base + demo nodes = 467 packages, ~132 MiB
- [x] Confirm `/run` in the casper initramfs is a tmpfs sized `${RUNSIZE:-10%}`, settable with `initramfs.runsize=`, and that `/run` is moved (not copied) into the live root
- [x] Confirm Subiquity 7403's `apt` autoinstall schema (`mirror-selection.primary`, pass-through `security`, `geoip`)

## Phase 1: Build

- [x] `build-ros2-installer-uki.sh` reusing the Ubuntu ISO pins (`config/ubuntu-installer.env`) and hooks (`rootfs-installer/`), without touching the Ubuntu builder
- [x] `rootfs-ros2/`: endpoint config with the `application/vnd.ros2.apt-bundle+tar` destination, `21fdo-ros2-check` premount hook
- [x] `.osrel` from the ISO's own initrd `os-release` (the Ubuntu builder uses the build host's)
- [x] Static endpoint build (`CGO_ENABLED=0`)
- [x] ROS snapshot key fetched and checked against the pinned fingerprint; `ros2-apt-source` SHA-256 pinned
- [x] Resolve against an empty system **and** the ISO's installed base (`ubuntu-server` layer dpkg status); merge
- [x] Self-check: offline install simulated from the bundle onto both
- [x] Real offline install (`unshare -n` chroot of the ISO's server layer) + talker/listener smoke test
- [x] Bundle byte-reproducible (sorted tar, fixed mtimes, fixed `Release` date)
- [ ] shellcheck (not installed on the build host or pe2)

## Phase 2: Runtime (QEMU)

- [x] Stage 1 BMO + chainload of the 106 MiB UKI
- [x] Stage 2: autoinstall, ROS 2 bundle, ISO streamed in that order; SSH keys + IP returned
- [x] `21fdo-ros2-check` passes; casper mounts `/dev/pmem0`; Subiquity runs unattended
- [x] Install-time apt mirror pinned to the Ubuntu snapshot; ROS 2 installed offline from the bundle in late-commands
- [x] Installed system: hostname, user, sudo, key-only SSH, marker, FDO host keys (strict SSH, no TOFU)
- [x] ROS 2 works on the installed system: `ros2` CLI, C++ talker → Python listener
- [x] Installed system's apt sources point back at archive.ubuntu.com; `ros2.sources` from ros2-apt-source present
- [x] Kernel command line of the installed system has no installer-only args
- [x] Survives a reboot (keys, strict SSH, ROS 2)
- [ ] Record peak guest memory / `/run` usage during the install
- [ ] Optional `QEMU_ACCEL=kvm` run (supported by the harness, not yet exercised)

### Resolved Issues

- **Dependency co-upgrades** (build): the empty-system closure couldn't be installed on the real base (`util-linux` pre-depends on the old `libuuid1` exactly). Fixed by also resolving against the ISO's installed-base dpkg status; guarded by an offline-install simulation onto both.
- **Install-time updates newer than the bundle** (design): Subiquity applies security updates before late-commands, so its mirror is pinned to the bundle's Ubuntu snapshot (builder-checked).
- **`ros2.sources` is an absolute symlink** (run 1): a `sed -i` glob over `sources.list.d/*.sources` from the live system failed on it (exit 2). Fixed by rewriting only `ubuntu.sources`, in-target, with separate archive and security URIs.

## Phase 3: Hardening / Production

- [ ] Signed bundle: today integrity is the FDO payload hash + the bundle's SHA256SUMS; provenance is checked only at build time. Options: sign `Release` with an owner key and drop `[trusted=yes]`, or use go-fdo's signed `payload-begin`
- [ ] Bundle content per device class (e.g. `ros-lyrical-desktop`, vendor packages, the robot's own workspace debs); `/run` sizing for bigger bundles (or stream to a scratch partition)
- [ ] Device-side ROS 2 config: `ROS_DOMAIN_ID`, RMW choice, SROS2 keystore (could be one more per-device payload)
- [ ] Management agent / robot fleet agent at first boot (see "Putting It All Together")
- [ ] Snapshot refresh policy: rebuild the bundle when a new ROS sync or Ubuntu SRU matters; snapshots get no security fixes
- [ ] arm64 (many robots): ROS 2 Lyrical is Tier 1 on arm64 too; needs an arm64 UKI stub, ISO and UEFI client
- [ ] Shared items with Ubuntu/Fedora/openSUSE: TO0/RV re-registration policy, capacity checks, server-side key persistence, Secure Boot, bare metal
