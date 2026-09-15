#!/bin/bash

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
source "$REPO_DIR/config/ubuntu-installer.env"

ASSET_DIR="$REPO_DIR/assets"
BUILD_DIR="$REPO_DIR/build-installer"
ISO_PATH="$ASSET_DIR/$UBUNTU_ISO_NAME"
UKI_OUTPUT="$REPO_DIR/firmware/$INSTALLER_UKI_NAME"
ENDPOINT_REPO="${ENDPOINT_REPO:-$REPO_DIR/../go-fdo-endpoint}"
if [ -z "${GO_ROOT:-}" ]; then
    GO_BIN=$(command -v go 2>/dev/null || true)
    if [ -n "$GO_BIN" ]; then
        GO_ROOT=$("$GO_BIN" env GOROOT)
    else
        echo "ERROR: Go not found. Set GO_ROOT or add go to PATH." >&2
        exit 1
    fi
fi
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"

MOUNT_DIR="$BUILD_DIR/iso"
ROOTFS_DIR="$BUILD_DIR/rootfs"
ORIGINAL_INITRD="$BUILD_DIR/initrd.original"
MODIFIED_INITRD="$BUILD_DIR/initrd.fdo"
KERNEL="$BUILD_DIR/vmlinuz"
CMDLINE_FILE="$BUILD_DIR/cmdline"

cleanup()
{
    if mountpoint -q "$MOUNT_DIR"; then
        sudo umount "$MOUNT_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$ASSET_DIR" "$REPO_DIR/firmware"
rm -rf "$BUILD_DIR"
mkdir -p "$MOUNT_DIR" "$ROOTFS_DIR"

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

sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"
cp "$MOUNT_DIR/casper/vmlinuz" "$KERNEL"
cp "$MOUNT_DIR/casper/initrd" "$ORIGINAL_INITRD"
cp "$MOUNT_DIR/boot/grub/grub.cfg" "$BUILD_DIR/grub.cfg"
sudo umount "$MOUNT_DIR"

unmkinitramfs "$ORIGINAL_INITRD" "$ROOTFS_DIR"
MAIN_ROOT="$ROOTFS_DIR/main"
if [ ! -x "$MAIN_ROOT/init" ]; then
    echo "Unpacked initramfs main archive does not contain /init" >&2
    exit 1
fi

mkdir -p "$MAIN_ROOT/usr/local/bin"
(
    cd "$ENDPOINT_REPO"
    GOROOT="$GO_ROOT" GOPATH=/tmp/gopath "$GO_ROOT/bin/go" build -tags=tpm -o "$MAIN_ROOT/usr/local/bin/fdo-endpoint" .
)
cp -a "$REPO_DIR/rootfs-installer/." "$MAIN_ROOT/"
cp "$REPO_DIR/rootfs-installer/scripts/generate-ssh-host-keys.sh" "$MAIN_ROOT/scripts/"
sed -i '/20iso_scan/i /scripts/casper-premount/20fdo-receive "$@"' "$MAIN_ROOT/scripts/casper-premount/ORDER"
sed -i '/99casperboot/i /scripts/casper-bottom/62fdo-autoinstall "$@"' "$MAIN_ROOT/scripts/casper-bottom/ORDER"
chmod 0755 "$MAIN_ROOT/scripts/casper-premount/20fdo-receive" "$MAIN_ROOT/scripts/casper-bottom/62fdo-autoinstall" "$MAIN_ROOT/scripts/generate-ssh-host-keys.sh" "$MAIN_ROOT/usr/local/bin/fdo-endpoint"



: > "$MODIFIED_INITRD"
for archive in early early2; do
    if [ -d "$ROOTFS_DIR/$archive" ]; then
        (
            cd "$ROOTFS_DIR/$archive"
            find . -print0 | cpio --null -o -H newc 2>/dev/null
        ) >> "$MODIFIED_INITRD"
    fi
done
(
    cd "$MAIN_ROOT"
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1
) >> "$MODIFIED_INITRD"

requested_mib=$(((UBUNTU_ISO_SIZE + 1024 * 1024 - 1) / 1024 / 1024))
requested_mib=$(((requested_mib + 3) & ~3))
printf 'boot=casper ip=dhcp live-media=/dev/pmem0 memmap=%sM!4G nokaslr autoinstall subiquity.autoinstallpath=/autoinstall.yaml console=ttyS0 console=tty0' "$requested_mib" > "$CMDLINE_FILE"

linux_vma=$((0x2000000))
linux_size=$(stat -c %s "$KERNEL")
initrd_vma=$((((linux_vma + linux_size + 0xfffff) / 0x100000) * 0x100000))
printf -v linux_vma_hex '0x%x' "$linux_vma"
printf -v initrd_vma_hex '0x%x' "$initrd_vma"

cp "$EFI_STUB" "$UKI_OUTPUT"
objcopy \
    --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 --set-section-flags .osrel=contents,alloc,load,readonly,data \
    --add-section .cmdline="$CMDLINE_FILE" --change-section-vma .cmdline=0x30000 --set-section-flags .cmdline=contents,alloc,load,readonly,data \
    --add-section .linux="$KERNEL" --change-section-vma .linux="$linux_vma_hex" --set-section-flags .linux=contents,alloc,load,readonly,code \
    --add-section .initrd="$MODIFIED_INITRD" --change-section-vma .initrd="$initrd_vma_hex" --set-section-flags .initrd=contents,alloc,load,readonly,data \
    "$UKI_OUTPUT"

objdump -h "$UKI_OUTPUT" | grep -E 'cmdline|linux|initrd'
sha256sum "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT" | tee "$BUILD_DIR/SHA256SUMS"
echo "Command line: $(cat "$CMDLINE_FILE")"
ls -lh "$ISO_PATH" "$KERNEL" "$ORIGINAL_INITRD" "$MODIFIED_INITRD" "$UKI_OUTPUT"

if [ "${DEPLOY:-0}" = "1" ] && [ -n "${DEPLOY_HOST:-}" ]; then
    echo "=== Deploying to $DEPLOY_HOST ==="
    ssh "$DEPLOY_HOST" "mkdir -p '$DEPLOY_FIRMWARE_DIR'"
    scp "$UKI_OUTPUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$INSTALLER_UKI_NAME"
    scp "$ISO_PATH" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/$UBUNTU_ISO_NAME"
fi
