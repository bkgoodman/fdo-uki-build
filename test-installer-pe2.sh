#!/bin/bash
#
# End-to-end FDO installer test
#
# Runs on the QEMU test host. Performs DI via quick-di-tpm, starts the
# FDO server with BMO + payload + credentials FSIMs, and boots the
# installer UKI in QEMU with a software TPM.
#
# Prerequisites (on the test host):
#   - server-installer binary    (FDO server, built from go-fdo examples/cmd)
#   - quick-di-tpm binary        (DI helper, built from go-fdo-quick-di)
#   - efi-disk-release.img       (UEFI FDO client disk, built from fdo-uefi-rs)
#   - Installer UKI + ISO + autoinstall in $FIRMWARE_DIR
#   - swtpm, qemu-system-x86_64, qemu-img
#
# All paths are configurable via environment variables.

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR=/tmp/fdo-installer-test-$TIMESTAMP
VOUCHER_DIR=/tmp/fdo-installer-vouchers-$TIMESTAMP

# Paths — override via environment for your deployment layout
SERVER="${FDO_SERVER:-$HOME/server-installer}"
QUICK_DI="${FDO_QUICK_DI:-$HOME/quick-di-tpm}"
EFI_DISK="${FDO_EFI_DISK:-$HOME/efi-disk-release.img}"
FIRMWARE_DIR="${FDO_FIRMWARE_DIR:-/tmp/fdo-firmware-server}"
UKI="$FIRMWARE_DIR/ubuntu-26.04.1-live-server-fdo.efi"
ISO="$FIRMWARE_DIR/ubuntu-26.04.1-live-server-amd64.iso"
AUTOINSTALL="$FIRMWARE_DIR/autoinstall-test.yaml"
# FORCE_FAIL=1 makes the install fail (a failing first late-command) so the
# error-commands report path is exercised.
FORCE_FAIL="${FORCE_FAIL:-0}"
REPORT_DIR="$WORKDIR/reports"
TARGET_DISK="$WORKDIR/target.qcow2"
VNC_DISPLAY="${VNC_DISPLAY:-:3}"
SSH_HOST_FWD="${SSH_HOST_FWD:-2222}"

# Validate
for f in "$SERVER" "$QUICK_DI" "$EFI_DISK" "$UKI" "$ISO" "$AUTOINSTALL"; do
    if [ ! -e "$f" ]; then
        echo "Missing: $f" >&2
        exit 1
    fi
done

echo "=== Cleanup ==="
# Only processes from earlier runs of this harness (their paths contain
# /tmp/fdo-installer-test-): never other VMs or swtpm instances on the host.
# ([/] keeps the pattern from matching this pkill's own sudo parent.)
sudo pkill -9 -f '[/]tmp/fdo-installer-test-' 2>/dev/null || true
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
    "$QUICK_DI" -quick -protocol-version 2.0 -rv 10.0.2.2:8080:http \
    -device-info FDO-Ubuntu-Live-Server-Installer -output-dir "$VOUCHER_DIR" \
    -signover-key "$WORKDIR/owner.pem"

VOUCHER=$(ls -t "$VOUCHER_DIR"/*.fdoov | head -1)
sed -i "s/FDO OWNERSHIP VOUCHER/OWNERSHIP VOUCHER/g" "$VOUCHER"
"$SERVER" server -db "$WORKDIR/fdo.db" -import-voucher "$VOUCHER" -initOnly

if [ "$FORCE_FAIL" = "1" ]; then
    sed '/^  late-commands:/a\    - "false"  # FORCE_FAIL: exercise error-commands' "$AUTOINSTALL" > "$WORKDIR/autoinstall-test.yaml"
    AUTOINSTALL="$WORKDIR/autoinstall-test.yaml"
    echo "FORCE_FAIL=1: install will fail at the first late-command"
fi

"$SERVER" server -http 0.0.0.0:8080 -db "$WORKDIR/fdo.db" -reuse-cred \
    -bmo "application/x-uefi-image:$UKI" \
    -payload "application/vnd.canonical.autoinstall+yaml:$AUTOINSTALL" \
    -payload-log-dir "$REPORT_DIR" \
    -payload "application/x-iso9660-image:$ISO" \
    -request-pubkey "device_info:device_info" \
    > "$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$WORKDIR/server.log"
    exit 1
fi

# TO0: register the RV blob so the installer-initrd endpoint can run
# TO1 -> TO2 (it has no RV-bypass fallback; without this, TO1 returns
# "not found" and Stage 2 stops). The TO2 address must be the owner as seen
# from the guest (QEMU user-net host). Same step as test-ros2-installer.sh.
GUID=$(basename "$VOUCHER" .fdoov)
echo "=== TO0: registering RV blob for $GUID ==="
timeout 30 "$SERVER" server -db "$WORKDIR/fdo.db" -to0 http://127.0.0.1:8080 -to0-guid "$GUID" \
    -ext-http "${FDO_EXT_HTTP:-10.0.2.2:8080}" > "$WORKDIR/to0.log" 2>&1 || true
if ! grep -q "RV blob registered" "$WORKDIR/to0.log"; then
    cat "$WORKDIR/to0.log"
    echo "TO0 registration failed" >&2
    exit 1
fi

cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORKDIR/OVMF_VARS.fd"

echo "=== Starting installer test ==="
echo "VNC: $VNC_DISPLAY"
echo "SSH forward: localhost:$SSH_HOST_FWD -> guest:22"
echo "Serial log: $WORKDIR/qemu.log"
echo "Server log: $WORKDIR/server.log"

sudo qemu-system-x86_64 \
    -machine q35 -m 8192 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
    -drive file="$EFI_DISK",format=raw,index=0 \
    -drive file="$TARGET_DISK",format=qcow2,index=1 \
    -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -device virtio-rng-pci \
    -nic user,model=virtio-net-pci,hostfwd=tcp::${SSH_HOST_FWD}-:22 \
    -vnc "$VNC_DISPLAY" -serial mon:stdio 2>&1 | tee "$WORKDIR/qemu.log"

echo "=== Test complete ==="
echo "Logs preserved in: $WORKDIR"
echo "  - Serial output: $WORKDIR/qemu.log"
echo "  - Server log: $WORKDIR/server.log"
echo "  - Database: $WORKDIR/fdo.db"
echo "  - TPM state: $WORKDIR/tpm2-00.permall"
echo ""
echo "=== SSH host keys / IP address received by owner during TO2 ==="
grep -A5 "Received public key registration" "$WORKDIR/server.log" || echo "  (none found - check server.log)"
echo ""
echo "=== Install reports received by owner (report mode) ==="
grep "device report" "$WORKDIR/server.log" || echo "  (none found - check server.log)"
for meta in "$REPORT_DIR"/*/*.json; do
    [ -e "$meta" ] || continue
    echo "--- ${meta%.json}"
    cat "$meta"
done
echo ""
echo "To clean up: rm -rf $WORKDIR"

kill "$SERVER_PID" "$SWTPM_PID" 2>/dev/null || true
