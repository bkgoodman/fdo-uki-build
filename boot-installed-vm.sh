#!/bin/bash

set -e

# Simple script to boot the installed VM for verification
# Usage: ./boot-installed-vm.sh <target-disk.qcow2>

if [ -z "$1" ]; then
    echo "Usage: $0 <target-disk.qcow2>"
    echo "Example: $0 /tmp/fdo-installer-test-20260908-103046/target.qcow2"
    exit 1
fi

TARGET_DISK="$1"

if [ ! -f "$TARGET_DISK" ]; then
    echo "Error: Target disk not found: $TARGET_DISK"
    exit 1
fi

echo "=== Booting installed VM ==="
echo "Target disk: $TARGET_DISK"
echo "VNC: pe2:5905"
echo "Serial: mon:stdio (this terminal)"
echo ""
echo "Press Ctrl+A then X to quit QEMU monitor"
echo "Press Ctrl+C to stop the VM"
echo ""

sudo qemu-system-x86_64 \
    -machine q35 -m 4096 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file=/usr/share/OVMF/OVMF_VARS_4M.fd \
    -drive file="$TARGET_DISK",format=qcow2,index=0 \
    -device virtio-rng-pci \
    -nic user,model=virtio-net-pci \
    -vnc :5 -serial mon:stdio
