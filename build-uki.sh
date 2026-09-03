#!/bin/bash
# Build Ubuntu UKI with FDO Stage 2 support
# This script documents the complete build process for the FDO UKI

set -e

# Configuration
# Override these environment variables as needed
UBUNTU_MINI_ISO="${UBUNTU_MINI_ISO:-/home/bradgoodman/fdo-uki-build/assets/ubuntu-mini-iso-26.10-snapshot1-mini-iso-amd64.iso}"
BUILD_DIR="${BUILD_DIR:-/home/bradgoodman/fdo-uki-build/build}"
FIRMWARE_SERVER="${FIRMWARE_SERVER:-/home/bradgoodman/fdo-uki-build/firmware}"
UKI_OUTPUT="${UKI_OUTPUT:-/home/bradgoodman/fdo-uki-build/ubuntu-installer-fdo.efi}"

# Remote deployment (pe2)
REMOTE_HOST="${REMOTE_HOST:-pe2}"
REMOTE_FIRMWARE_SERVER="${REMOTE_FIRMWARE_SERVER:-/tmp/fdo-firmware-server}"
REMOTE_INITRD="${REMOTE_INITRD:-/tmp/ubuntu-initrd-fdo.gz}"  # Full initrd with all packages

# Paths to external binaries
GO_FDO_ENDPOINT="${GO_FDO_ENDPOINT:-/home/bradgoodman/fdo-uki-build/assets/fdo-endpoint}"  # Built from go-fdo-endpoint with -tags=tpm

echo "=== FDO UKI Build Script ==="
echo "Build dir: $BUILD_DIR"
echo "Output: $UKI_OUTPUT"
echo ""

# Clean and create build directory
echo "=== Cleaning build directory ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 1: Get kernel and full initrd
echo "=== Step 1: Getting kernel and full initrd ==="

# Download kernel from mini-ISO if not present
if [ ! -f "$BUILD_DIR/vmlinuz" ]; then
    echo "  Kernel not found, extracting from mini-ISO..."
    if [ ! -f "$UBUNTU_MINI_ISO" ]; then
        echo "  ISO not found, downloading from pe2..."
        mkdir -p "$(dirname "$UBUNTU_MINI_ISO")"
        scp "$REMOTE_HOST:/home/bkg/bkgvm/ubuntu-mini-iso-26.10-snapshot1-mini-iso-amd64.iso" "$UBUNTU_MINI_ISO"
    fi
    sudo mount -o loop "$UBUNTU_MINI_ISO" /mnt
    cp /mnt/casper/vmlinuz "$BUILD_DIR/vmlinuz"
    sudo umount /mnt
fi

# Copy full initrd from pe2
echo "  Copying full initrd from pe2..."
scp "$REMOTE_HOST:$REMOTE_INITRD" "$BUILD_DIR/initrd.gz"
echo "  Kernel: $BUILD_DIR/vmlinuz"
echo "  Initrd: $BUILD_DIR/initrd.gz"

# Step 2: Unpack initrd
echo "=== Step 2: Unpacking initrd ==="
mkdir -p "$BUILD_DIR/initrd"
cd "$BUILD_DIR/initrd"

# Check if initrd is gzip or raw cpio
if file "$BUILD_DIR/initrd.gz" | grep -q gzip; then
    gunzip -c "$BUILD_DIR/initrd.gz" | cpio -i -H newc
else
    cpio -i -H newc < "$BUILD_DIR/initrd.gz"
fi
echo "  Unpacked to $BUILD_DIR/initrd/"

# Step 3: Add custom init script
echo "=== Step 3: Adding custom init script ==="
cat > "$BUILD_DIR/initrd/init" << 'INITEOF'
#!/bin/sh
# Minimal init for FDO BMO Ubuntu UKI - Stage 2
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "FDO BMO: Initializing..."

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs udev /dev
mkdir -p /dev/pts /run /tmp
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp

# Load essential modules
echo "FDO BMO: Loading modules..."
modprobe virtio_net 2>/dev/null
modprobe virtio_pci 2>/dev/null

# Start udev for device discovery
if [ -x /usr/lib/systemd/systemd-udevd ]; then
    /usr/lib/systemd/systemd-udevd --daemon 2>/dev/null
    udevadm trigger --action=add 2>/dev/null
    udevadm settle --timeout=10 2>/dev/null
fi

# Configure networking via DHCP
echo "FDO BMO: Configuring network..."
for iface in /sys/class/net/e*; do
    iface=$(basename "$iface")
    ip link set "$iface" up 2>/dev/null
done
sleep 2

# Try dhcpcd or busybox udhcpc
if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd --oneshot --waitip 2>/dev/null
elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i eth0 -q 2>/dev/null
fi

echo ""
echo "=== FDO BMO Ubuntu UKI Booted - Stage 1 Complete ==="
echo "Kernel: $(uname -r)"
echo "Network:"
ip addr show 2>/dev/null | grep "inet " || echo "  no IP"
echo ""

# Wait for TPM device
echo "FDO BMO: Waiting for TPM device..."
TRIES=0
while [ ! -e /dev/tpmrm0 ] && [ $TRIES -lt 10 ]; do
    sleep 1
    TRIES=$((TRIES + 1))
done

if [ -e /dev/tpmrm0 ]; then
    echo "TPM: /dev/tpmrm0 ready"
else
    echo "WARNING: /dev/tpmrm0 not found after 10s"
fi

# Stage 2: Run go-fdo-endpoint
if [ -x /usr/local/bin/fdo-endpoint ]; then
    echo ""
    echo "=== Stage 2: Running FDO Endpoint Client ==="
    echo "Config: /etc/fdo/config_generic.yaml"
    echo ""

    # Create payload temp dir
    mkdir -p /tmp/fdo_payloads

    # Run TO2 directly against server (skip RV)
    cd /etc/fdo
    /usr/local/bin/fdo-endpoint -to2 http://10.0.2.2:8080 -config /etc/fdo/config_generic.yaml 2>&1
    FDO_EXIT=$?

    echo ""
    echo "=== FDO Endpoint exited with code $FDO_EXIT ==="
fi

echo ""
echo "Dropping to shell..."
exec /bin/sh
INITEOF
chmod +x "$BUILD_DIR/initrd/init"
echo "  Created $BUILD_DIR/initrd/init"

# Step 4: Add go-fdo-endpoint binary
echo "=== Step 4: Adding go-fdo-endpoint binary ==="
mkdir -p "$BUILD_DIR/initrd/usr/local/bin"
cp "$GO_FDO_ENDPOINT" "$BUILD_DIR/initrd/usr/local/bin/fdo-endpoint"
chmod +x "$BUILD_DIR/initrd/usr/local/bin/fdo-endpoint"
echo "  Copied $GO_FDO_ENDPOINT"

# Step 5: Add config_generic.yaml
echo "=== Step 5: Adding config_generic.yaml ==="
mkdir -p "$BUILD_DIR/initrd/etc/fdo"
cat > "$BUILD_DIR/initrd/etc/fdo/config_generic.yaml" << 'YAMLEOF'
# Stage 2 FDO Endpoint Configuration
# Runs inside UKI after Stage 1 chainload

blob_path: ""
debug: true
fdo_version: 200

di:
  url: "http://10.0.2.2:8080"
  key: "ec256"
  key_enc: "x509"

crypto:
  cipher_suite: "A128GCM"
  kex_suite: "ECDH256"

transport:
  insecure_tls: true
  tpm_path: ""

operation:
  print_device: false
  rv_only: false

# Generic Handler Configuration
handlers:
  sysconfig:
    hostname:
      command: "echo 'Setting hostname to: {value}'"
      enabled: true
    timezone:
      command: "echo 'Setting timezone to: {value}'"
      enabled: true
    ntp-server:
      command: "echo 'Setting NTP server to: {value}'"
      enabled: true

  payload:
    temp_dir: "/tmp/fdo_payloads"
    default_action: "accept"
    mime_types:
      application/octet-stream:
        enabled: true
        command: "echo 'Received binary payload: {filename} ({size} bytes)'"
      application/json:
        enabled: true
        command: "echo 'Received JSON payload: {filename}'"
      text/plain:
        enabled: true
        command: "echo 'Received text payload: {filename}'"

service_info:
  download_dir: ""
  echo_commands: true
  wget_dir: ""
  upload_paths: []

fdo_sys:
  enabled: false
YAMLEOF
echo "  Created $BUILD_DIR/initrd/etc/fdo/config_generic.yaml"

# Step 6: Repack initrd
echo "=== Step 6: Repacking initrd ==="
cd "$BUILD_DIR/initrd"
rm -f "$BUILD_DIR/initrd.gz"
find . | cpio -o -H newc 2>/dev/null | gzip -1 > "$BUILD_DIR/initrd.gz"
echo "  Repacked to $BUILD_DIR/initrd.gz"

# Step 7: Build UKI with ukify (run on pe2 which has ukify)
echo "=== Step 7: Building UKI with ukify (on pe2) ==="
# Copy kernel to pe2
scp "$BUILD_DIR/vmlinuz" "$REMOTE_HOST:/tmp/fdo-uki-build-temp/vmlinuz"
# Run ukify on pe2 (initrd already there from pe2)
ssh "$REMOTE_HOST" "ukify build --linux /tmp/fdo-uki-build-temp/vmlinuz --initrd $REMOTE_INITRD --cmdline 'console=tty0 console=ttyS0' --output /tmp/fdo-uki-build-temp/ubuntu-installer-fdo.efi"
# Copy UKI back
scp "$REMOTE_HOST:/tmp/fdo-uki-build-temp/ubuntu-installer-fdo.efi" "$UKI_OUTPUT"
echo "  Built: $UKI_OUTPUT"

# Step 8: Copy to firmware server
echo "=== Step 8: Copying to firmware server ==="
mkdir -p "$FIRMWARE_SERVER"
cp "$UKI_OUTPUT" "$FIRMWARE_SERVER/ubuntu-installer.efi"
echo "  Copied to $FIRMWARE_SERVER/ubuntu-installer.efi"

# Step 9: Deploy to remote host (pe2)
echo "=== Step 9: Deploying to remote host ($REMOTE_HOST) ==="
scp "$UKI_OUTPUT" "$REMOTE_HOST:$REMOTE_FIRMWARE_SERVER/ubuntu-installer.efi"
echo "  Deployed to $REMOTE_HOST:$REMOTE_FIRMWARE_SERVER/ubuntu-installer.efi"

# Summary
echo ""
echo "=== Build Complete ==="
echo "UKI: $UKI_OUTPUT"
echo "Local firmware server: $FIRMWARE_SERVER/ubuntu-installer.efi"
echo "Remote firmware server: $REMOTE_HOST:$REMOTE_FIRMWARE_SERVER/ubuntu-installer.efi"
echo ""
echo "Size:"
ls -lh "$UKI_OUTPUT"
ls -lh "$FIRMWARE_SERVER/ubuntu-installer.efi"
