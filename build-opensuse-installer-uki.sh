#!/bin/bash
#
# Build an openSUSE Leap 16 (Agama) offline installer UKI with FDO onboarding.
#
# Takes the pinned Leap offline installer ISO (a kiwi-built Agama live ISO with
# the full package repository in /install), extracts its kernel and initramfs,
# APPENDS a small cpio overlay (fdo-endpoint, endpoint config, fdo-receive.service,
# plus nd_pmem/nd_btt from the ISO's own kernel package) to the untouched original
# initramfs, and packs kernel + initramfs + cmdline + openSUSE os-release into a
# single EFI binary.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
source "$REPO_DIR/config/opensuse-installer.env"

ASSET_DIR="$REPO_DIR/assets"
BUILD_DIR="$REPO_DIR/build-opensuse"
ISO_PATH="$ASSET_DIR/$OPENSUSE_ISO_NAME"
UKI_OUTPUT="$REPO_DIR/firmware/$INSTALLER_UKI_NAME"
PROFILE="$REPO_DIR/$OPENSUSE_PROFILE"
ENDPOINT_REPO="${ENDPOINT_REPO:-$REPO_DIR/../go-fdo-endpoint}"
ENDPOINT_BIN="${ENDPOINT_BIN:-}"
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"

MOUNT_DIR="$BUILD_DIR/iso"
INSPECT_DIR="$BUILD_DIR/inspect"
OVERLAY_DIR="$BUILD_DIR/overlay"
KMOD_DIR="$BUILD_DIR/kernel-modules"
ORIGINAL_INITRD="$BUILD_DIR/initrd.original"
OVERLAY_CPIO="$BUILD_DIR/overlay.cpio.gz"
MODIFIED_INITRD="$BUILD_DIR/initrd.fdo"
KERNEL="$BUILD_DIR/vmlinuz"
CMDLINE_FILE="$BUILD_DIR/cmdline"
OSREL_FILE="$BUILD_DIR/os-release"

# Must be in the initrd already (loadable or built in).
REQUIRED_MODULES="libnvdimm nd_e820 isofs squashfs overlay loop tpm_tis tpm_crb virtio_net"
# Added from the ISO's kernel-default package if the initrd lacks them (load order).
EXTRA_MODULES="nd_btt nd_pmem"

cleanup()
{
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        sudo umount "$MOUNT_DIR"
    fi
}
trap cleanup EXIT

# Write an RPM's (still compressed) cpio payload to stdout. Avoids needing rpm2cpio.
rpm_payload_raw()
{
    python3 - "$1" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
if data[:4] != b"\xed\xab\xee\xdb":
    sys.exit("not an RPM: " + sys.argv[1])
off = 96
for i in range(2):  # signature header (8-byte padded), then main header
    if data[off:off + 3] != b"\x8e\xad\xe8":
        sys.exit("bad RPM header magic")
    nindex, hsize = struct.unpack(">II", data[off + 8:off + 16])
    off += 16 + nindex * 16 + hsize
    if i == 0:
        off = (off + 7) & ~7
sys.stdout.buffer.write(data[off:])
PY
}

echo "=== FDO openSUSE Installer UKI Build ==="

if [ -z "$ENDPOINT_BIN" ] && [ -z "${GO_ROOT:-}" ]; then
    GO_BIN=$(command -v go 2>/dev/null || true)
    if [ -n "$GO_BIN" ]; then
        GO_ROOT=$("$GO_BIN" env GOROOT)
    else
        echo "ERROR: Go not found. Set GO_ROOT, add go to PATH, or set ENDPOINT_BIN." >&2
        exit 1
    fi
fi
for tool in cpio gzip xz bzip2 zstd python3 objcopy objdump blkid sha512sum; do
    command -v "$tool" >/dev/null || { echo "ERROR: missing required tool: $tool" >&2; exit 1; }
done
[ -f "$EFI_STUB" ] || { echo "ERROR: EFI stub not found: $EFI_STUB" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "ERROR: Agama profile not found: $PROFILE" >&2; exit 1; }
python3 -m json.tool "$PROFILE" >/dev/null || { echo "ERROR: Agama profile is not valid JSON: $PROFILE" >&2; exit 1; }

mkdir -p "$ASSET_DIR" "$REPO_DIR/firmware"
rm -rf "$BUILD_DIR"
mkdir -p "$MOUNT_DIR" "$INSPECT_DIR" "$OVERLAY_DIR" "$KMOD_DIR"

echo "=== Step 1: Fetch and verify ISO ==="
if [ ! -f "$ISO_PATH" ]; then
    curl -fL --retry 3 -o "$ISO_PATH.partial" "$OPENSUSE_ISO_URL"
    mv "$ISO_PATH.partial" "$ISO_PATH"
fi
echo "$OPENSUSE_ISO_SHA512  $ISO_PATH" | sha512sum -c -
actual_size=$(stat -c %s "$ISO_PATH")
if [ "$actual_size" -ne "$OPENSUSE_ISO_SIZE" ]; then
    echo "ISO size mismatch: expected $OPENSUSE_ISO_SIZE, got $actual_size" >&2
    exit 1
fi
iso_label=$(blkid -p -s LABEL -o value "$ISO_PATH")
if [ "$iso_label" != "$OPENSUSE_ISO_LABEL" ]; then
    echo "ISO label mismatch: expected $OPENSUSE_ISO_LABEL, got $iso_label" >&2
    exit 1
fi

echo "=== Step 2: Extract kernel and initramfs ==="
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"
cp "$MOUNT_DIR/boot/x86_64/loader/linux" "$KERNEL"
cp "$MOUNT_DIR/boot/x86_64/loader/initrd" "$ORIGINAL_INITRD"
cp "$MOUNT_DIR/boot/grub2/grub.cfg" "$BUILD_DIR/grub.cfg"
cp "$MOUNT_DIR/LiveOS/.info" "$BUILD_DIR/liveos.info"
chmod u+w "$KERNEL" "$ORIGINAL_INITRD" "$BUILD_DIR/grub.cfg" "$BUILD_DIR/liveos.info"
for d in LiveOS/squashfs.img install/repodata install/media.1; do
    [ -e "$MOUNT_DIR/$d" ] || { echo "ERROR: ISO lacks $d (not an offline Agama installer?)" >&2; exit 1; }
done

echo "=== Step 3: Inspect initramfs (read-only) ==="
inspect_patterns=(
    'usr/lib/os-release'
    'usr/lib/initrd-release'
    'etc/cmdline.d/10-liveroot.conf'
    'usr/lib/modules/*/modules.dep'
    'usr/lib/modules/*/modules.builtin'
    'usr/lib/systemd/system/nm-wait-online-initrd.service'
    'usr/lib/systemd/system/dracut-initqueue.service'
    'var/lib/dracut/hooks/cmdline/99-agama-cmdline-conf.sh'
)
magic=$(od -An -tx1 -N6 "$ORIGINAL_INITRD" | tr -d ' \n')
case "$magic" in
    fd377a585a00) decompress=(xz -dc) ;;
    28b52ffd*) decompress=(zstd -dc) ;;
    1f8b*) decompress=(gzip -dc) ;;
    *) decompress=() ;;
esac
if [ "${#decompress[@]}" -gt 0 ]; then
    (cd "$INSPECT_DIR" && "${decompress[@]}" "$ORIGINAL_INITRD" | cpio -idm --quiet "${inspect_patterns[@]}")
elif command -v unmkinitramfs >/dev/null; then
    unmkinitramfs "$ORIGINAL_INITRD" "$INSPECT_DIR/full"
    INSPECT_DIR="$INSPECT_DIR/full"
    [ -d "$INSPECT_DIR/main" ] && INSPECT_DIR="$INSPECT_DIR/main"
elif command -v lsinitrd >/dev/null; then
    (cd "$INSPECT_DIR" && lsinitrd --unpack "$ORIGINAL_INITRD")
else
    echo "ERROR: unknown initramfs format ($magic) and neither unmkinitramfs nor lsinitrd available" >&2
    exit 1
fi

for f in usr/lib/os-release usr/lib/initrd-release etc/cmdline.d/10-liveroot.conf \
         usr/lib/systemd/system/nm-wait-online-initrd.service usr/lib/systemd/system/dracut-initqueue.service \
         var/lib/dracut/hooks/cmdline/99-agama-cmdline-conf.sh; do
    [ -e "$INSPECT_DIR/$f" ] || { echo "ERROR: initramfs is missing expected file: $f" >&2; exit 1; }
done
grep -qx 'Before=dracut-initqueue.service' "$INSPECT_DIR/usr/lib/systemd/system/nm-wait-online-initrd.service" || \
    { echo "ERROR: nm-wait-online-initrd.service is no longer ordered before dracut-initqueue" >&2; exit 1; }
grep -qx "root=live:LABEL=$OPENSUSE_ISO_LABEL" "$INSPECT_DIR/etc/cmdline.d/10-liveroot.conf" || \
    { echo "ERROR: initrd live root is not LABEL=$OPENSUSE_ISO_LABEL" >&2; exit 1; }
grep -q 'agama\* | live\* | inst\*' "$INSPECT_DIR/var/lib/dracut/hooks/cmdline/99-agama-cmdline-conf.sh" || \
    { echo "ERROR: Agama dracut hook no longer forwards inst.* options" >&2; exit 1; }

kernel_versions=$(ls "$INSPECT_DIR/usr/lib/modules")
[ "$(echo "$kernel_versions" | grep -c .)" -eq 1 ] || { echo "ERROR: expected one kernel in initramfs: $kernel_versions" >&2; exit 1; }
KVER=$kernel_versions
if ! file -b "$KERNEL" | grep -q "version $KVER "; then
    echo "ERROR: kernel image does not match initramfs kernel $KVER" >&2
    exit 1
fi
moddir="$INSPECT_DIR/usr/lib/modules/$KVER"
has_module()
{
    local pat="/${1//_/[_-]}\\.ko"
    grep -qE "$pat" "$moddir/modules.dep" || grep -qE "$pat" "$moddir/modules.builtin"
}
for m in $REQUIRED_MODULES; do
    has_module "$m" || { echo "ERROR: initramfs lacks required kernel module: $m" >&2; exit 1; }
    echo "  module $m: present"
done
missing_extra=""
for m in $EXTRA_MODULES; do
    if has_module "$m"; then
        echo "  module $m: present"
    else
        echo "  module $m: missing from initrd, will add from kernel-default"
        missing_extra="$missing_extra $m"
    fi
done
cp "$INSPECT_DIR/usr/lib/os-release" "$OSREL_FILE"
echo "  Kernel: $KVER"
echo "  OS: $(sed -n 's/^PRETTY_NAME=//p' "$OSREL_FILE")"

echo "=== Step 4: Stage FDO overlay ==="
cp -a "$REPO_DIR/rootfs-opensuse/." "$OVERLAY_DIR/"
install -D -m 0755 "$REPO_DIR/rootfs-installer/scripts/generate-ssh-host-keys.sh" \
    "$OVERLAY_DIR/usr/libexec/fdo/generate-ssh-host-keys.sh"

if [ -n "$missing_extra" ]; then
    # kernel-default-6.12.0-160000.35.1.x86_64.rpm for KVER 6.12.0-160000.35-default
    kver_base=${KVER%-default}
    kernel_rpm=""
    for f in "$MOUNT_DIR"/install/x86_64/kernel-default-"$kver_base".*.x86_64.rpm; do
        [ -f "$f" ] && { kernel_rpm=$f; break; }
    done
    [ -n "$kernel_rpm" ] || { echo "ERROR: no kernel-default RPM for $KVER on the ISO" >&2; exit 1; }
    echo "  Extracting$missing_extra from $(basename "$kernel_rpm")"
    payload="$BUILD_DIR/kernel-default.payload"
    rpm_payload_raw "$kernel_rpm" > "$payload"
    patterns=()
    for m in $missing_extra; do
        patterns+=("./usr/lib/modules/$KVER/kernel/drivers/*/$m.ko*")
    done
    pmagic=$(od -An -tx1 -N4 "$payload" | tr -d ' \n')
    case "$pmagic" in
        425a68*) pdec=(bzip2 -dc) ;;
        fd377a58*) pdec=(xz -dc) ;;
        28b52ffd*) pdec=(zstd -dc) ;;
        1f8b*) pdec=(gzip -dc) ;;
        *) echo "ERROR: unknown RPM payload compression ($pmagic)" >&2; exit 1 ;;
    esac
    (cd "$KMOD_DIR" && "${pdec[@]}" "$payload" | cpio -idm --quiet "${patterns[@]}")
    rm -f "$payload"
    mkdir -p "$OVERLAY_DIR/usr/lib/fdo/modules"
    for m in $missing_extra; do
        src=$(find "$KMOD_DIR" -name "$m.ko*" | sed -n 1p)
        [ -n "$src" ] || { echo "ERROR: $m not found in $(basename "$kernel_rpm")" >&2; exit 1; }
        case "$src" in
            *.zst) zstd -dqc "$src" > "$OVERLAY_DIR/usr/lib/fdo/modules/$m.ko" ;;
            *.xz) xz -dc "$src" > "$OVERLAY_DIR/usr/lib/fdo/modules/$m.ko" ;;
            *.ko) cp "$src" "$OVERLAY_DIR/usr/lib/fdo/modules/$m.ko" ;;
        esac
        vermagic=$(modinfo -F vermagic "$OVERLAY_DIR/usr/lib/fdo/modules/$m.ko" 2>/dev/null | awk '{print $1}')
        [ "$vermagic" = "$KVER" ] || { echo "ERROR: $m vermagic '$vermagic' != $KVER" >&2; exit 1; }
        chmod 0644 "$OVERLAY_DIR/usr/lib/fdo/modules/$m.ko"
        echo "  added usr/lib/fdo/modules/$m.ko (vermagic $vermagic)"
    done
fi

mkdir -p "$OVERLAY_DIR/usr/local/bin"
if [ -n "$ENDPOINT_BIN" ]; then
    install -m 0755 "$ENDPOINT_BIN" "$OVERLAY_DIR/usr/local/bin/fdo-endpoint"
else
    (
        cd "$ENDPOINT_REPO"
        CGO_ENABLED=0 GOROOT="$GO_ROOT" GOPATH="${GOPATH:-/tmp/gopath}" "$GO_ROOT/bin/go" build -tags=tpm \
            -o "$OVERLAY_DIR/usr/local/bin/fdo-endpoint" .
    )
fi
sed -i "s|@OPENSUSE_ISO_LABEL@|$OPENSUSE_ISO_LABEL|g" "$OVERLAY_DIR/usr/libexec/fdo/fdo-receive.sh"
mkdir -p "$OVERLAY_DIR/usr/lib/systemd/system/initrd.target.wants"
ln -sf ../fdo-receive.service "$OVERLAY_DIR/usr/lib/systemd/system/initrd.target.wants/fdo-receive.service"
chmod 0755 "$OVERLAY_DIR/usr/libexec/fdo/fdo-receive.sh" "$OVERLAY_DIR/usr/local/bin/fdo-endpoint"
chmod 0644 "$OVERLAY_DIR/usr/lib/systemd/system/fdo-receive.service" "$OVERLAY_DIR/etc/fdo/config.yaml"
find "$OVERLAY_DIR" -type d -exec chmod 0755 {} +

# The initramfs is usrmerged: bin, sbin, lib, lib64 are symlinks into /usr.
# An appended cpio entry for any of them would replace the symlink.
for p in bin sbin lib lib64; do
    if [ -e "$OVERLAY_DIR/$p" ] || [ -L "$OVERLAY_DIR/$p" ]; then
        echo "ERROR: overlay must not contain top-level /$p (usrmerge symlink)" >&2
        exit 1
    fi
done
if grep -q '@OPENSUSE_ISO_LABEL@' "$OVERLAY_DIR/usr/libexec/fdo/fdo-receive.sh"; then
    echo "ERROR: ISO label placeholder not substituted" >&2
    exit 1
fi
sudo umount "$MOUNT_DIR"

echo "=== Step 5: Append overlay to initramfs ==="
(
    cd "$OVERLAY_DIR"
    find . -mindepth 1 -print0 | LC_ALL=C sort -z | cpio --null -o -H newc -R 0:0 --quiet
) | gzip -9 > "$OVERLAY_CPIO"
cp "$ORIGINAL_INITRD" "$MODIFIED_INITRD"
# Concatenated initramfs members must start on a 4-byte boundary.
orig_size=$(stat -c %s "$MODIFIED_INITRD")
pad=$(( (4 - orig_size % 4) % 4 ))
if [ "$pad" -ne 0 ]; then
    truncate -s $((orig_size + pad)) "$MODIFIED_INITRD"
fi
cat "$OVERLAY_CPIO" >> "$MODIFIED_INITRD"
overlay_offset=$((orig_size + pad))

# Self-check: original bytes preserved, overlay readable at its offset.
cmp -n "$orig_size" "$ORIGINAL_INITRD" "$MODIFIED_INITRD"
tail -c +$((overlay_offset + 1)) "$MODIFIED_INITRD" | gzip -dc | cpio -t --quiet > "$BUILD_DIR/overlay.list"
if grep -qE '^(bin|sbin|lib|lib64)$' "$BUILD_DIR/overlay.list"; then
    echo "ERROR: appended archive contains a usrmerge symlink path" >&2
    exit 1
fi
echo "  Appended overlay at offset $overlay_offset:"
sed 's/^/    /' "$BUILD_DIR/overlay.list"

echo "=== Step 6: Kernel command line ==="
requested_mib=$(((OPENSUSE_ISO_SIZE + 1024 * 1024 - 1) / 1024 / 1024))
requested_mib=$(((requested_mib + 3) & ~3))
printf '%s' "root=live:LABEL=$OPENSUSE_ISO_LABEL rd.live.image inst.auto=file:///run/fdo/agama/profile.json inst.finish=poweroff inst.self_update=0 systemd.unit=multi-user.target ip=dhcp rd.neednet=1 memmap=${requested_mib}M!4G nokaslr console=tty0 console=ttyS0" > "$CMDLINE_FILE"

echo "=== Step 7: Build UKI ==="
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
sha256sum "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT" "$PROFILE" | tee "$BUILD_DIR/SHA256SUMS"
echo "Command line: $(cat "$CMDLINE_FILE")"
ls -lh "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT"

if [ "${DEPLOY:-0}" = "1" ] && [ -n "${DEPLOY_HOST:-}" ]; then
    echo "=== Deploying to $DEPLOY_HOST ==="
    ssh "$DEPLOY_HOST" "mkdir -p '$DEPLOY_FIRMWARE_DIR'"
    scp "$UKI_OUTPUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$INSTALLER_UKI_NAME"
    scp "$ISO_PATH" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$OPENSUSE_ISO_NAME"
    scp "$PROFILE" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$(basename "$PROFILE")"
fi
