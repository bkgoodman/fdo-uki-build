#!/bin/bash
#
# End-to-end FDO Fedora installer test
#
# Runs on the QEMU test host. Performs DI via quick-di-tpm, starts the
# FDO server with BMO + payload + credentials FSIMs, and boots the
# Fedora installer UKI in QEMU with a software TPM.
#
# Prerequisites (on the test host):
#   - server-installer binary    (FDO server, built from go-fdo examples/cmd)
#   - quick-di-tpm binary        (DI helper, built from go-fdo-quick-di)
#   - efi-disk-release.img       (UEFI FDO client disk, built from fdo-uefi-rs)
#   - Fedora installer UKI + ISO + kickstart in $FIRMWARE_DIR
#     (DEPLOY=1 DEPLOY_HOST=<host> ./build-fedora-installer-uki.sh copies all three)
#   - swtpm, qemu-system-x86_64, qemu-img
#
# All paths are configurable via environment variables.

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR=/tmp/fdo-fedora-test-$TIMESTAMP
VOUCHER_DIR=/tmp/fdo-fedora-vouchers-$TIMESTAMP
LATEST_LINK=/tmp/fdo-fedora-test-latest

# Only ever kill processes this harness started (recorded in $WORKDIR/pids.txt);
# the test host may run other VMs, swtpm instances and FDO servers.
fdo_record_pid() { echo "$2 $3" >> "$1/pids.txt"; }
fdo_cleanup()
{
    local pidfile="$1/pids.txt"
    [ -f "$pidfile" ] || return 0
    while read -r pid name; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "  killing $name (PID $pid)"; sudo kill -9 "$pid" 2>/dev/null || true; }
    done < "$pidfile"
    rm -f "$pidfile"
}

# Paths — override via environment for your deployment layout
SERVER="${FDO_SERVER:-$HOME/server-installer}"
QUICK_DI="${FDO_QUICK_DI:-$HOME/quick-di-tpm}"
EFI_DISK="${FDO_EFI_DISK:-$HOME/efi-disk-release.img}"
FIRMWARE_DIR="${FDO_FIRMWARE_DIR:-/tmp/fdo-firmware-server}"
UKI="$FIRMWARE_DIR/${FEDORA_UKI_NAME:-fedora-44-server-dvd-fdo.efi}"
ISO="$FIRMWARE_DIR/${FEDORA_ISO_NAME:-Fedora-Server-dvd-x86_64-44-1.7.iso}"
KICKSTART="$FIRMWARE_DIR/${FEDORA_KICKSTART_NAME:-kickstart-test.ks}"
KS_MIME="${FEDORA_KS_MIME:-application/vnd.fedora.kickstart}"
TARGET_DISK="$WORKDIR/target.qcow2"
# The UKI reserves ~3.7 GiB at 4 GiB for /dev/pmem0; leave room for Anaconda.
QEMU_MEM="${QEMU_MEM:-12288}"
VNC_DISPLAY="${VNC_DISPLAY:-:3}"
SSH_HOST_FWD="${SSH_HOST_FWD:-2222}"

# Validate
for f in "$SERVER" "$QUICK_DI" "$EFI_DISK" "$UKI" "$ISO" "$KICKSTART"; do
    if [ ! -e "$f" ]; then
        echo "Missing: $f" >&2
        exit 1
    fi
done

echo "=== Cleanup ==="
if [ -L "$LATEST_LINK" ] && [ -d "$LATEST_LINK" ]; then
    fdo_cleanup "$(readlink -f "$LATEST_LINK")"
fi
sleep 1
rm -rf "$WORKDIR" "$VOUCHER_DIR"
mkdir -p "$WORKDIR" "$VOUCHER_DIR"
ln -sfn "$WORKDIR" "$LATEST_LINK"
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
fdo_record_pid "$WORKDIR" $SWTPM_PID swtpm
sleep 2

if [ ! -S "$WORKDIR/swtpm-ctrl" ]; then
    echo "swtpm socket was not created" >&2
    exit 1
fi

timeout 30 env FDO_TPM_DEVICE="$WORKDIR/swtpm-server" \
    "$QUICK_DI" -quick -protocol-version 2.0 -rv 10.0.2.2:8080:http \
    -device-info FDO-Fedora-Server-Installer -output-dir "$VOUCHER_DIR" \
    -signover-key "$WORKDIR/owner.pem"

VOUCHER=$(ls -t "$VOUCHER_DIR"/*.fdoov | head -1)
sed -i "s/FDO OWNERSHIP VOUCHER/OWNERSHIP VOUCHER/g" "$VOUCHER"
"$SERVER" server -db "$WORKDIR/fdo.db" -import-voucher "$VOUCHER" -initOnly

# The kickstart must be listed before the ISO so it arrives first.
"$SERVER" server -http 0.0.0.0:8080 -db "$WORKDIR/fdo.db" -reuse-cred \
    -bmo "application/x-uefi-image:$UKI" \
    -payload "$KS_MIME:$KICKSTART" \
    -payload "application/x-iso9660-image:$ISO" \
    -request-pubkey "device_info:device_info" \
    > "$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
fdo_record_pid "$WORKDIR" $SERVER_PID fdo-server
sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$WORKDIR/server.log"
    exit 1
fi

# TO0: register the RV blob so both the UEFI client and the installer-initrd
# endpoint can run TO1 -> TO2 (the endpoint has no RV-bypass fallback). The
# TO2 address must be the owner as seen from the guest (QEMU user-net host).
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

echo "=== Starting Fedora installer test ==="
echo "VNC: $VNC_DISPLAY"
echo "SSH forward: localhost:$SSH_HOST_FWD -> guest:22"
echo "Serial log: $WORKDIR/qemu.log"
echo "Server log: $WORKDIR/server.log"

sudo qemu-system-x86_64 \
    -machine q35 -m "$QEMU_MEM" -no-reboot \
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
echo "  - Installed disk: $TARGET_DISK (boot with ./boot-installed-vm.sh)"
echo ""
echo "=== SSH host keys / IP address received by owner during TO2 ==="
grep -A5 "Received public key registration" "$WORKDIR/server.log" || echo "  (none found - check server.log)"
echo ""
echo "To clean up: rm -rf $WORKDIR"

kill "$SERVER_PID" "$SWTPM_PID" 2>/dev/null || true
rm -f "$WORKDIR/pids.txt"
