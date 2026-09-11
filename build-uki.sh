#!/bin/bash
# Build simple Ubuntu UKI with FDO Stage 2 support
#
# This script builds a minimal UKI from the Ubuntu mini-ISO kernel
# and initramfs, injecting the FDO endpoint binary and a custom init.
#
# Prerequisites:
#   - Ubuntu mini-ISO in assets/ (see config/simple-uki.env)
#   - go-fdo-endpoint binary in assets/fdo-endpoint
#   - objcopy, cpio, gzip

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
source "$REPO_DIR/config/simple-uki.env"

# Paths — all relative to the repo root
ASSET_DIR="$REPO_DIR/assets"
BUILD_DIR="$REPO_DIR/build"
FIRMWARE_DIR="$REPO_DIR/firmware"
MINI_ISO="$ASSET_DIR/$MINI_ISO_NAME"
UKI_OUTPUT="$FIRMWARE_DIR/ubuntu-installer-fdo.efi"
ENDPOINT_BIN="$ASSET_DIR/fdo-endpoint"
EFI_STUB="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"

echo "=== FDO Simple UKI Build ==="
echo "Build dir: $BUILD_DIR"
echo "Output:    $UKI_OUTPUT"
echo ""

# Validate prerequisites
if [ ! -f "$ENDPOINT_BIN" ]; then
    echo "ERROR: fdo-endpoint binary not found at $ENDPOINT_BIN" >&2
    echo "Build it with: cd <go-fdo-endpoint-repo> && go build -tags=tpm -o $ENDPOINT_BIN ." >&2
    exit 1
fi

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$FIRMWARE_DIR"

# Step 1: Get the mini-ISO
echo "=== Step 1: Getting mini-ISO ==="
if [ ! -f "$MINI_ISO" ]; then
    if [ -n "${MINI_ISO_URL:-}" ]; then
        echo "  Downloading from $MINI_ISO_URL ..."
        mkdir -p "$ASSET_DIR"
        curl -fL --retry 3 -o "$MINI_ISO.partial" "$MINI_ISO_URL"
        mv "$MINI_ISO.partial" "$MINI_ISO"
    else
        echo "ERROR: Mini-ISO not found at $MINI_ISO" >&2
        echo "Place it in assets/ or set MINI_ISO_URL in config/simple-uki.env" >&2
        exit 1
    fi
fi
if [ -n "${MINI_ISO_SHA256:-}" ]; then
    echo "$MINI_ISO_SHA256  $MINI_ISO" | sha256sum -c -
fi

# Step 2: Extract kernel from mini-ISO
echo "=== Step 2: Extracting kernel and initrd from mini-ISO ==="
MOUNT_DIR="$BUILD_DIR/iso"
mkdir -p "$MOUNT_DIR"

cleanup() {
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        sudo umount "$MOUNT_DIR"
    fi
}
trap cleanup EXIT

sudo mount -o loop,ro "$MINI_ISO" "$MOUNT_DIR"
cp "$MOUNT_DIR/casper/vmlinuz" "$BUILD_DIR/vmlinuz"
# Mini-ISO initrd may be gzip or raw cpio
cp "$MOUNT_DIR/casper/initrd" "$BUILD_DIR/initrd.original"
sudo umount "$MOUNT_DIR"

echo "  Kernel: $BUILD_DIR/vmlinuz"
echo "  Initrd: $BUILD_DIR/initrd.original"

# Step 3: Unpack initrd
echo "=== Step 3: Unpacking initrd ==="
ROOTFS_DIR="$BUILD_DIR/initrd"
mkdir -p "$ROOTFS_DIR"
cd "$ROOTFS_DIR"

if file "$BUILD_DIR/initrd.original" | grep -q gzip; then
    gunzip -c "$BUILD_DIR/initrd.original" | cpio -i -H newc 2>/dev/null
else
    cpio -i -H newc < "$BUILD_DIR/initrd.original" 2>/dev/null
fi
echo "  Unpacked to $ROOTFS_DIR/"

# Step 4: Inject FDO components from rootfs-simple/
echo "=== Step 4: Injecting FDO components ==="
cp "$REPO_DIR/rootfs-simple/init" "$ROOTFS_DIR/init"
chmod +x "$ROOTFS_DIR/init"
echo "  Installed init script"

mkdir -p "$ROOTFS_DIR/usr/local/bin"
cp "$ENDPOINT_BIN" "$ROOTFS_DIR/usr/local/bin/fdo-endpoint"
chmod +x "$ROOTFS_DIR/usr/local/bin/fdo-endpoint"
echo "  Installed fdo-endpoint binary"

mkdir -p "$ROOTFS_DIR/etc/fdo"
cp "$REPO_DIR/rootfs-simple/etc/fdo/config_generic.yaml" "$ROOTFS_DIR/etc/fdo/config_generic.yaml"
echo "  Installed config_generic.yaml"

# Step 5: Repack initrd
echo "=== Step 5: Repacking initrd ==="
cd "$ROOTFS_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$BUILD_DIR/initrd.fdo.gz"
echo "  Repacked to $BUILD_DIR/initrd.fdo.gz"

# Step 6: Build UKI with objcopy
echo "=== Step 6: Building UKI ==="
KERNEL="$BUILD_DIR/vmlinuz"
INITRD="$BUILD_DIR/initrd.fdo.gz"
CMDLINE_FILE="$BUILD_DIR/cmdline"
printf 'console=tty0 console=ttyS0' > "$CMDLINE_FILE"

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
    --add-section .initrd="$INITRD" --change-section-vma .initrd="$initrd_vma_hex" --set-section-flags .initrd=contents,alloc,load,readonly,data \
    "$UKI_OUTPUT"

objdump -h "$UKI_OUTPUT" | grep -E 'cmdline|linux|initrd'
sha256sum "$KERNEL" "$INITRD" "$UKI_OUTPUT" | tee "$BUILD_DIR/SHA256SUMS"
echo ""
ls -lh "$UKI_OUTPUT"

# Step 7: Deploy (optional)
if [ -n "${DEPLOY_HOST:-}" ]; then
    echo "=== Step 7: Deploying to $DEPLOY_HOST ==="
    ssh "$DEPLOY_HOST" "mkdir -p '$DEPLOY_FIRMWARE_DIR'"
    scp "$UKI_OUTPUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/ubuntu-installer.efi"
    echo "  Deployed to $DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/ubuntu-installer.efi"
fi

echo ""
echo "=== Build Complete ==="
echo "UKI: $UKI_OUTPUT"
