#!/bin/bash
#
# Build a ROS 2 (Lyrical Luth) installer for FDO onboarding: an Ubuntu 26.04.1
# live-server installer UKI plus an offline, pinned ROS 2 apt bundle.
#
# ROS 2 is not an OS: its Tier 1 platform is Ubuntu 26.04. The device therefore
# installs the pinned Ubuntu live-server ISO exactly as the Ubuntu path does,
# and the owner sends one more fdo.payload: a tar holding a local apt repo with
# the full dependency closure of $ROS2_PACKAGES, resolved and downloaded at
# build time from immutable snapshots (snapshots.ros.org + snapshot.ubuntu.com),
# against both an empty system and the ISO's own installed-base package set.
# Autoinstall late-commands install ROS 2 from that repo, with no network.
#
# Outputs:
#   firmware/$INSTALLER_UKI_NAME   installer UKI (BMO)
#   firmware/$ROS2_BUNDLE_NAME     ROS 2 apt bundle (fdo.payload)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
source "$REPO_DIR/config/ubuntu-installer.env"
source "$REPO_DIR/config/ros2-installer.env"

ASSET_DIR="$REPO_DIR/assets"
BUILD_DIR="$REPO_DIR/build-ros2"
ISO_PATH="$ASSET_DIR/$UBUNTU_ISO_NAME"
UKI_OUTPUT="$REPO_DIR/firmware/$INSTALLER_UKI_NAME"
BUNDLE_OUTPUT="$REPO_DIR/firmware/$ROS2_BUNDLE_NAME"
AUTOINSTALL="$REPO_DIR/$ROS2_AUTOINSTALL"
ENDPOINT_REPO="${ENDPOINT_REPO:-$REPO_DIR/../go-fdo-endpoint}"
ENDPOINT_BIN="${ENDPOINT_BIN:-}"
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"

MOUNT_DIR="$BUILD_DIR/iso"
ROOTFS_DIR="$BUILD_DIR/rootfs"
APT_DIR="$BUILD_DIR/apt"
BUNDLE_DIR="$BUILD_DIR/bundle"
ORIGINAL_INITRD="$BUILD_DIR/initrd.original"
MODIFIED_INITRD="$BUILD_DIR/initrd.fdo"
KERNEL="$BUILD_DIR/vmlinuz"
CMDLINE_FILE="$BUILD_DIR/cmdline"
OSREL_FILE="$BUILD_DIR/os-release"

cleanup()
{
    for m in "$BUILD_DIR/base-layer" "$MOUNT_DIR"; do
        if mountpoint -q "$m" 2>/dev/null; then
            sudo umount "$m"
        fi
    done
}
trap cleanup EXIT

echo "=== FDO ROS 2 ($ROS_DISTRO) Installer Build ==="

if [ -z "$ENDPOINT_BIN" ] && [ -z "${GO_ROOT:-}" ]; then
    GO_BIN=$(command -v go 2>/dev/null || true)
    if [ -n "$GO_BIN" ]; then
        GO_ROOT=$("$GO_BIN" env GOROOT)
    else
        echo "ERROR: Go not found. Set GO_ROOT, add go to PATH, or set ENDPOINT_BIN." >&2
        exit 1
    fi
fi
for tool in curl blkid cpio gzip unmkinitramfs objcopy objdump sha256sum gpg apt-get dpkg-deb dpkg-scanpackages apt-ftparchive tar python3; do
    command -v "$tool" >/dev/null || { echo "ERROR: missing required tool: $tool" >&2; exit 1; }
done
[ -f "$EFI_STUB" ] || { echo "ERROR: EFI stub not found: $EFI_STUB" >&2; exit 1; }
[ -f "$UBUNTU_ARCHIVE_KEYRING" ] || { echo "ERROR: Ubuntu archive keyring not found: $UBUNTU_ARCHIVE_KEYRING" >&2; exit 1; }
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))["autoinstall"]' "$AUTOINSTALL" || \
    { echo "ERROR: $AUTOINSTALL is not a valid autoinstall YAML" >&2; exit 1; }

grep -q "uri: $UBUNTU_SNAPSHOT_URL\$" "$AUTOINSTALL" || \
    { echo "ERROR: $AUTOINSTALL must pin the installer apt mirror to $UBUNTU_SNAPSHOT_URL" >&2; exit 1; }

mkdir -p "$ASSET_DIR" "$REPO_DIR/firmware"
rm -rf "$BUILD_DIR"
mkdir -p "$MOUNT_DIR" "$ROOTFS_DIR" "$BUNDLE_DIR/repo" "$BUNDLE_DIR/extra"

echo "=== Step 1: Fetch and verify Ubuntu ISO ==="
if [ ! -f "$ISO_PATH" ]; then
    curl -fL --retry 3 -o "$ISO_PATH.partial" "$UBUNTU_ISO_URL"
    mv "$ISO_PATH.partial" "$ISO_PATH"
fi
echo "$UBUNTU_ISO_SHA256  $ISO_PATH" | sha256sum -c -
actual_size=$(stat -c %s "$ISO_PATH")
if [ "$actual_size" -ne "$UBUNTU_ISO_SIZE" ]; then
    echo "ISO size mismatch: expected $UBUNTU_ISO_SIZE, got $actual_size" >&2
    exit 1
fi

echo "=== Step 2: Extract kernel, initramfs and installed-base package set ==="
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"
cp "$MOUNT_DIR/casper/vmlinuz" "$KERNEL"
cp "$MOUNT_DIR/casper/initrd" "$ORIGINAL_INITRD"
cp "$MOUNT_DIR/boot/grub/grub.cfg" "$BUILD_DIR/grub.cfg"
cp "$MOUNT_DIR/casper/install-sources.yaml" "$BUILD_DIR/install-sources.yaml"
iso_codename=$(sed -n 's/^Codename: //p' "$MOUNT_DIR/dists/$UBUNTU_SUITE/Release" 2>/dev/null || true)
[ "$iso_codename" = "$UBUNTU_SUITE" ] || { echo "ERROR: ISO is not $UBUNTU_SUITE (got '$iso_codename')" >&2; exit 1; }
# The dpkg status of the default install source (the ubuntu-server layer) is
# the package set the device has when the autoinstall late-commands run.
base_squashfs=$(python3 -c 'import sys, yaml
print(next(s["path"] for s in yaml.safe_load(open(sys.argv[1]))["sources"] if s.get("default")))' "$BUILD_DIR/install-sources.yaml")
mkdir -p "$BUILD_DIR/base-layer"
sudo mount -o loop,ro "$MOUNT_DIR/casper/$base_squashfs" "$BUILD_DIR/base-layer"
cp "$BUILD_DIR/base-layer/var/lib/dpkg/status" "$BUILD_DIR/base-status"
sudo umount "$BUILD_DIR/base-layer"
sudo umount "$MOUNT_DIR"
chmod u+w "$KERNEL" "$ORIGINAL_INITRD" "$BUILD_DIR/grub.cfg" "$BUILD_DIR/base-status"
echo "  Installed base: $base_squashfs ($(grep -c '^Package: ' "$BUILD_DIR/base-status") packages)"

echo "=== Step 3: Resolve and download the ROS 2 apt bundle ==="
# A private apt root: host apt resolves against resolute indexes without
# touching the host's own apt state. Two resolutions are merged:
#   - against an EMPTY dpkg status: the full dependency closure, so every
#     dependency is in the bundle whatever the device already has;
#   - against the ISO's installed-base dpkg status: adds the co-upgrades a
#     newer library forces on installed packages (e.g. uuid-dev pins
#     libuuid1 (=), whose newer version util-linux pre-depends on exactly).
mkdir -p "$APT_DIR/etc/apt/sources.list.d" "$APT_DIR/etc/apt/preferences.d" "$APT_DIR/etc/apt/apt.conf.d" \
    "$APT_DIR/var/lib/apt/lists/partial" "$APT_DIR/var/cache/apt/archives/partial" "$APT_DIR/var/lib/dpkg" "$APT_DIR/gnupg"
: > "$APT_DIR/var/lib/dpkg/status"
chmod 0700 "$APT_DIR/gnupg"
ros_key_asc="$APT_DIR/ros-snapshots.asc"
ros_keyring="$APT_DIR/ros-snapshots-archive-keyring.gpg"
curl -fsSL --retry 3 -o "$ros_key_asc" "$ROS_SNAPSHOT_KEY_URL"
key_fprs=$(GNUPGHOME="$APT_DIR/gnupg" gpg --batch --show-keys --with-colons "$ros_key_asc" | awk -F: '$1 == "fpr" {print $10}')
echo "$key_fprs" | grep -qx "$ROS_SNAPSHOT_KEY_FPR" || \
    { echo "ERROR: ROS snapshot key fingerprint mismatch (got: $key_fprs)" >&2; exit 1; }
GNUPGHOME="$APT_DIR/gnupg" gpg --batch --dearmor < "$ros_key_asc" > "$ros_keyring"

cat > "$APT_DIR/etc/apt/sources.list" <<EOF
deb [arch=amd64 signed-by=$UBUNTU_ARCHIVE_KEYRING] $UBUNTU_SNAPSHOT_URL $UBUNTU_SUITE main restricted universe
deb [arch=amd64 signed-by=$UBUNTU_ARCHIVE_KEYRING] $UBUNTU_SNAPSHOT_URL $UBUNTU_SUITE-updates main restricted universe
deb [arch=amd64 signed-by=$UBUNTU_ARCHIVE_KEYRING] $UBUNTU_SNAPSHOT_URL $UBUNTU_SUITE-security main restricted universe
deb [arch=amd64 signed-by=$ros_keyring] $ROS_SNAPSHOT_URL $UBUNTU_SUITE main
EOF
cat > "$APT_DIR/apt.conf" <<EOF
Dir "$APT_DIR/";
Dir::State::status "$APT_DIR/var/lib/dpkg/status";
Dir::Cache::archives "$BUNDLE_DIR/repo/";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Acquire::Check-Valid-Until "false";
EOF
export APT_CONFIG="$APT_DIR/apt.conf"
apt-get -q update
: > "$BUILD_DIR/apt-simulate.txt"
for status in "$APT_DIR/var/lib/dpkg/status" "$BUILD_DIR/base-status"; do
    # shellcheck disable=SC2086
    apt-get -o Dir::State::status="$status" -s install $ROS2_PACKAGES | grep '^Inst ' >> "$BUILD_DIR/apt-simulate.txt"
    # shellcheck disable=SC2086
    apt-get -o Dir::State::status="$status" -q -y --download-only install $ROS2_PACKAGES
done
unset APT_CONFIG
expected=$(awk '{print $2}' "$BUILD_DIR/apt-simulate.txt" | sort -u | grep -c .)
rm -rf "$BUNDLE_DIR/repo/partial" "$BUNDLE_DIR/repo/lock"
got=$(find "$BUNDLE_DIR/repo" -name '*.deb' | grep -c .)
[ "$got" -eq "$expected" ] || { echo "ERROR: downloaded $got packages, expected $expected" >&2; exit 1; }
for p in $ROS2_PACKAGES; do
    ls "$BUNDLE_DIR/repo/${p}_"*.deb >/dev/null 2>&1 || { echo "ERROR: $p missing from bundle" >&2; exit 1; }
done
upgrades=$(grep -c '^Inst [^ ]* \[' "$BUILD_DIR/apt-simulate.txt" || true)
echo "  $got packages ($(du -sh "$BUNDLE_DIR/repo" | cut -f1)) for: $ROS2_PACKAGES"
echo "  ($upgrades of them upgrade packages of the installed base)"

ras_deb="$BUNDLE_DIR/extra/$(basename "$ROS_APT_SOURCE_URL")"
curl -fsSL --retry 3 -o "$ras_deb" "$ROS_APT_SOURCE_URL"
echo "$ROS_APT_SOURCE_SHA256  $ras_deb" | sha256sum -c -

echo "=== Step 4: Assemble the bundle (local apt repo) ==="
(
    cd "$BUNDLE_DIR/repo"
    dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
    # Fixed Date (the Ubuntu snapshot time) keeps the bundle byte-reproducible.
    apt-ftparchive -o APT::FTPArchive::Release::Origin=fdo-ros2-bundle \
        -o APT::FTPArchive::Release::Suite="$UBUNTU_SUITE" release . \
        | sed "s/^Date: .*/Date: $(date -u -R -d "$(echo "$UBUNTU_SNAPSHOT" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3 \4:\5:\6 UTC/')")/" > ../Release.tmp
    mv ../Release.tmp Release
)
install -m 0755 "$REPO_DIR/ros2/install-ros2-bundle.sh" "$BUNDLE_DIR/install-ros2-bundle.sh"
echo "$ROS2_PACKAGES" | tr ' ' '\n' > "$BUNDLE_DIR/packages.txt"
for deb in "$BUNDLE_DIR"/repo/*.deb "$BUNDLE_DIR"/extra/*.deb; do
    printf '%s %s %s %s\n' "$(dpkg-deb -f "$deb" Package)" "$(dpkg-deb -f "$deb" Version)" \
        "$(dpkg-deb -f "$deb" Architecture)" "$(sha256sum "$deb" | cut -d' ' -f1)"
done | LC_ALL=C sort > "$BUNDLE_DIR/MANIFEST"
cat > "$BUNDLE_DIR/BUNDLE-INFO" <<EOF
ROS_DISTRO=$ROS_DISTRO
UBUNTU_SUITE=$UBUNTU_SUITE
ROS_SNAPSHOT_URL=$ROS_SNAPSHOT_URL
UBUNTU_SNAPSHOT_URL=$UBUNTU_SNAPSHOT_URL
ROS2_PACKAGES=$ROS2_PACKAGES
PACKAGE_COUNT=$got
ROS_APT_SOURCE_VERSION=$ROS_APT_SOURCE_VERSION
EOF
(
    cd "$BUNDLE_DIR"
    find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    find . -type d -exec chmod 0755 {} +
    find . -type f ! -name install-ros2-bundle.sh -exec chmod 0644 {} +
)
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu \
    -C "$BUNDLE_DIR" -cf "$BUNDLE_OUTPUT" .
[ "$(dd if="$BUNDLE_OUTPUT" bs=1 skip=257 count=5 2>/dev/null)" = "ustar" ] || \
    { echo "ERROR: bundle is not a ustar archive" >&2; exit 1; }
# Self-check: the bundle installs offline, with the same apt isolation as its
# install script, both on an empty system and on the ISO's installed base.
sim_root="$BUILD_DIR/sim"
mkdir -p "$sim_root/lists/partial" "$sim_root/empty" "$sim_root/cache/archives/partial"
printf 'deb [trusted=yes] file:%s/repo ./\n' "$BUNDLE_DIR" > "$sim_root/bundle.list"
: > "$sim_root/status"
sim_opts=(-o Dir::Etc::SourceList="$sim_root/bundle.list" -o Dir::Etc::SourceParts="$sim_root/empty"
          -o Dir::State::Lists="$sim_root/lists" -o Dir::Cache="$sim_root/cache"
          -o Dir::Etc::Preferences=/nonexistent -o Dir::Etc::PreferencesParts="$sim_root/empty"
          -o APT::Architecture=amd64 -o APT::Architectures::=amd64 -o Acquire::Languages=none)
apt-get -q "${sim_opts[@]}" -o Dir::State::status="$sim_root/status" update > "$sim_root/update.log"
for status in "$sim_root/status" "$BUILD_DIR/base-status"; do
    # shellcheck disable=SC2086
    apt-get "${sim_opts[@]}" -o Dir::State::status="$status" -s install --no-install-recommends $ROS2_PACKAGES \
        > "$sim_root/install.log" 2>&1 || { cat "$sim_root/install.log" >&2; echo "ERROR: bundle does not install offline onto $(basename "$status")" >&2; exit 1; }
    echo "  Offline install simulation onto $(basename "$status"): OK ($(grep -c '^Inst ' "$sim_root/install.log") packages)"
done
ls -l "$BUNDLE_OUTPUT"

echo "=== Step 5: Unpack and check the initramfs ==="
unmkinitramfs "$ORIGINAL_INITRD" "$ROOTFS_DIR"
MAIN_ROOT="$ROOTFS_DIR/main"
[ -x "$MAIN_ROOT/init" ] || { echo "Unpacked initramfs main archive does not contain /init" >&2; exit 1; }
grep -q 'initramfs.runsize=' "$MAIN_ROOT/init" || \
    { echo "ERROR: initramfs /init no longer honours initramfs.runsize=" >&2; exit 1; }
grep -q '^/scripts/casper-premount/20iso_scan ' "$MAIN_ROOT/scripts/casper-premount/ORDER" || \
    { echo "ERROR: casper-premount ORDER lacks 20iso_scan" >&2; exit 1; }
grep -q '^/scripts/casper-bottom/99casperboot ' "$MAIN_ROOT/scripts/casper-bottom/ORDER" || \
    { echo "ERROR: casper-bottom ORDER lacks 99casperboot" >&2; exit 1; }
cp "$MAIN_ROOT/etc/os-release" "$OSREL_FILE"
echo "  OS: $(sed -n 's/^PRETTY_NAME=//p' "$OSREL_FILE")"

echo "=== Step 6: Inject FDO components ==="
mkdir -p "$MAIN_ROOT/usr/local/bin"
if [ -n "$ENDPOINT_BIN" ]; then
    install -m 0755 "$ENDPOINT_BIN" "$MAIN_ROOT/usr/local/bin/fdo-endpoint"
else
    (
        cd "$ENDPOINT_REPO"
        CGO_ENABLED=0 GOROOT="$GO_ROOT" GOPATH="${GOPATH:-/tmp/gopath}" "$GO_ROOT/bin/go" build -tags=tpm \
            -o "$MAIN_ROOT/usr/local/bin/fdo-endpoint" .
    )
fi
# Ubuntu installer overlay (hooks, keygen), then the ROS 2 overlay on top
# (endpoint config with the bundle MIME type, bundle check hook).
cp -a "$REPO_DIR/rootfs-installer/." "$MAIN_ROOT/"
cp -a "$REPO_DIR/rootfs-ros2/." "$MAIN_ROOT/"
cp "$REPO_DIR/rootfs-installer/scripts/generate-ssh-host-keys.sh" "$MAIN_ROOT/scripts/"
sed -i '/20iso_scan/i /scripts/casper-premount/20fdo-receive "$@"\n/scripts/casper-premount/21fdo-ros2-check "$@"' \
    "$MAIN_ROOT/scripts/casper-premount/ORDER"
sed -i '/99casperboot/i /scripts/casper-bottom/62fdo-autoinstall "$@"' "$MAIN_ROOT/scripts/casper-bottom/ORDER"
chmod 0755 "$MAIN_ROOT/scripts/casper-premount/20fdo-receive" "$MAIN_ROOT/scripts/casper-premount/21fdo-ros2-check" \
    "$MAIN_ROOT/scripts/casper-bottom/62fdo-autoinstall" "$MAIN_ROOT/scripts/generate-ssh-host-keys.sh" \
    "$MAIN_ROOT/usr/local/bin/fdo-endpoint"
grep -q "^      $ROS2_BUNDLE_MIME:" "$MAIN_ROOT/etc/fdo/config.yaml" || \
    { echo "ERROR: endpoint config lacks $ROS2_BUNDLE_MIME" >&2; exit 1; }
grep -A3 'fdo-receive\|fdo-ros2-check' "$MAIN_ROOT/scripts/casper-premount/ORDER" | grep -q 20iso_scan || \
    { echo "ERROR: FDO hooks not inserted before 20iso_scan" >&2; exit 1; }
sed -n '/fdo/,/20iso_scan/p' "$MAIN_ROOT/scripts/casper-premount/ORDER" | grep -v param.conf | sed 's/^/  premount: /'

echo "=== Step 7: Reconstruct the initramfs ==="
: > "$MODIFIED_INITRD"
for archive in early early2; do
    if [ -d "$ROOTFS_DIR/$archive" ]; then
        (
            cd "$ROOTFS_DIR/$archive"
            find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --quiet
        ) >> "$MODIFIED_INITRD"
    fi
done
(
    cd "$MAIN_ROOT"
    find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --quiet | gzip -1
) >> "$MODIFIED_INITRD"

echo "=== Step 8: Kernel command line ==="
requested_mib=$(((UBUNTU_ISO_SIZE + 1024 * 1024 - 1) / 1024 / 1024))
requested_mib=$(((requested_mib + 3) & ~3))
# initramfs.runsize: /run (tmpfs, default 10% of RAM) also holds the ROS 2 bundle until late-commands.
printf 'boot=casper ip=dhcp live-media=/dev/pmem0 memmap=%sM!4G nokaslr initramfs.runsize=50%% autoinstall subiquity.autoinstallpath=/autoinstall.yaml console=ttyS0 console=tty0' \
    "$requested_mib" > "$CMDLINE_FILE"

echo "=== Step 9: Build UKI ==="
linux_vma=$((0x2000000))
linux_size=$(stat -c %s "$KERNEL")
initrd_vma=$((((linux_vma + linux_size + 0xfffff) / 0x100000) * 0x100000))
printf -v linux_vma_hex '0x%x' "$linux_vma"
printf -v initrd_vma_hex '0x%x' "$initrd_vma"

cp "$EFI_STUB" "$UKI_OUTPUT"
objcopy \
    --add-section .osrel="$OSREL_FILE" --change-section-vma .osrel=0x20000 --set-section-flags .osrel=contents,alloc,load,readonly,data \
    --add-section .cmdline="$CMDLINE_FILE" --change-section-vma .cmdline=0x30000 --set-section-flags .cmdline=contents,alloc,load,readonly,data \
    --add-section .linux="$KERNEL" --change-section-vma .linux="$linux_vma_hex" --set-section-flags .linux=contents,alloc,load,readonly,code \
    --add-section .initrd="$MODIFIED_INITRD" --change-section-vma .initrd="$initrd_vma_hex" --set-section-flags .initrd=contents,alloc,load,readonly,data \
    "$UKI_OUTPUT"

objdump -h "$UKI_OUTPUT" | grep -E 'osrel|cmdline|linux|initrd'
sha256sum "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT" "$BUNDLE_OUTPUT" "$AUTOINSTALL" \
    | tee "$BUILD_DIR/SHA256SUMS"
echo "Command line: $(cat "$CMDLINE_FILE")"
ls -lh "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT" "$BUNDLE_OUTPUT"

if [ "${DEPLOY:-0}" = "1" ] && [ -n "${DEPLOY_HOST:-}" ]; then
    echo "=== Deploying to $DEPLOY_HOST ==="
    ssh "$DEPLOY_HOST" "mkdir -p '$DEPLOY_FIRMWARE_DIR'"
    scp "$UKI_OUTPUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$INSTALLER_UKI_NAME"
    scp "$BUNDLE_OUTPUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$ROS2_BUNDLE_NAME"
    scp "$AUTOINSTALL" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$(basename "$AUTOINSTALL")"
    if ssh "$DEPLOY_HOST" "echo '$UBUNTU_ISO_SHA256  $DEPLOY_FIRMWARE_DIR/$UBUNTU_ISO_NAME' | sha256sum -c --status - 2>/dev/null"; then
        echo "  $UBUNTU_ISO_NAME already present on $DEPLOY_HOST (hash matches)"
    else
        scp "$ISO_PATH" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$UBUNTU_ISO_NAME"
    fi
fi
