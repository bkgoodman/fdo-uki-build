#!/bin/bash

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR=/tmp/fdo-installer-test-$TIMESTAMP
VOUCHER_DIR=/tmp/fdo-installer-vouchers-$TIMESTAMP
SERVER=/home/bkg/bkgvm/server-installer
UKI=/tmp/fdo-firmware-server/ubuntu-26.04.1-live-server-fdo.efi
ISO=/tmp/fdo-firmware-server/ubuntu-26.04.1-live-server-amd64.iso
AUTOINSTALL=/tmp/fdo-firmware-server/autoinstall-test.yaml
TARGET_DISK="$WORKDIR/target.qcow2"

if [ ! -x "$SERVER" ] || [ ! -f "$UKI" ] || [ ! -f "$ISO" ] || [ ! -f "$AUTOINSTALL" ]; then
    echo "Missing server, UKI, or ISO artifact" >&2
    exit 1
fi

echo "=== Cleanup ==="
sudo killall -9 swtpm server-installer qemu-system-x86_64 2>/dev/null || true
sleep 1
rm -rf "$WORKDIR" "$VOUCHER_DIR"
mkdir -p "$WORKDIR" "$VOUCHER_DIR"
echo "Work directory: $WORKDIR"
qemu-img create -f qcow2 "$TARGET_DISK" 24G

echo "=== Init database ==="
timeout 10 "$SERVER" server -db "$WORKDIR/fdo.db" -http 127.0.0.1:8080 -initOnly 2>&1 || true

"$SERVER" server -db "$WORKDIR/fdo.db" -print-owner-public SECP256R1 2>/dev/null | grep -A100 "BEGIN PUBLIC" > "$WORKDIR/owner.pem"

swtpm socket --tpmstate dir="$WORKDIR" \
    --server type=unixio,path="$WORKDIR/swtpm-server" \
    --ctrl type=unixio,path="$WORKDIR/swtpm-ctrl" \
    --tpm2 --flags startup-clear &
SWTPM_PID=$!
sleep 2

if [ ! -S "$WORKDIR/swtpm-ctrl" ]; then
    echo "swtpm socket was not created" >&2
    exit 1
fi

timeout 30 env FDO_TPM_DEVICE="$WORKDIR/swtpm-server" \
    /home/bkg/quick-di-tpm -quick -protocol-version 2.0 -rv 10.0.2.2:8080:http \
    -device-info FDO-Ubuntu-Live-Server-Installer -output-dir "$VOUCHER_DIR" \
    -signover-key "$WORKDIR/owner.pem"

VOUCHER=$(ls -t "$VOUCHER_DIR"/*.fdoov | head -1)
sed -i "s/FDO OWNERSHIP VOUCHER/OWNERSHIP VOUCHER/g" "$VOUCHER"
"$SERVER" server -db "$WORKDIR/fdo.db" -import-voucher "$VOUCHER" -initOnly

"$SERVER" server -http 0.0.0.0:8080 -db "$WORKDIR/fdo.db" -reuse-cred \
    -bmo "application/x-uefi-image:$UKI" \
    -payload "application/vnd.canonical.autoinstall+yaml:$AUTOINSTALL" \
    -payload "application/x-iso9660-image:$ISO" > "$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$WORKDIR/server.log"
    exit 1
fi

cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORKDIR/OVMF_VARS.fd"

echo "=== Starting installer test ==="
echo "VNC: pe2:5903"
echo "Serial log: $WORKDIR/qemu.log"
echo "Server log: $WORKDIR/server.log"

sudo qemu-system-x86_64 \
    -machine q35 -m 8192 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
    -drive file=/home/bkg/bkgvm/efi-disk-release.img,format=raw,index=0 \
    -drive file="$TARGET_DISK",format=qcow2,index=1 \
    -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -device virtio-rng-pci \
    -nic user,model=virtio-net-pci \
    -vnc :3 -serial mon:stdio 2>&1 | tee "$WORKDIR/qemu.log"

echo "=== Test complete ==="
echo "Logs preserved in: $WORKDIR"
echo "  - Serial output: $WORKDIR/qemu.log"
echo "  - Server log: $WORKDIR/server.log"
echo "  - Database: $WORKDIR/fdo.db"
echo "  - TPM state: $WORKDIR/tpm2-00.permall"
echo ""
echo "To clean up: rm -rf $WORKDIR"

kill "$SERVER_PID" "$SWTPM_PID" 2>/dev/null || true
