#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 spike, on the QEMU test host:
#   1. fresh swtpm, DI with quick-di-tpm (writes the FDO TPM credential)
#   2. Linux baseline: tbs-probe over the swtpm socket
#   3. boot wimboot -> stock boot.wim -> WinPE under OVMF (KVM), which runs
#      tbs-probe.exe over TBS against the SAME swtpm state, then powers off
#   4. print both results; GUID / DCTPM hash / DAK key / HMAC must match
#
# Usage: run-spike-pe2.sh <spike-disk.img> <tbs-probe (linux)>
# Env:   WORKDIR (default ~/fdo-win-spike), QUICK_DI (default ~/quick-di-tpm),
#        TIMEOUT_QEMU seconds (default 600), TPM_MODEL tpm-tis|tpm-crb

set -euo pipefail

DISK_SRC=$1
PROBE=$2
WORKDIR=${WORKDIR:-$HOME/fdo-win-spike}
QUICK_DI=${QUICK_DI:-$HOME/quick-di-tpm}
TIMEOUT_QEMU=${TIMEOUT_QEMU:-600}
TPM_MODEL=${TPM_MODEL:-tpm-tis}
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd

SWTPM_PID=
cleanup() {
    [ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/tpm"
cp "$DISK_SRC" "$WORKDIR/disk.img"
cp "$OVMF_VARS" "$WORKDIR/OVMF_VARS.fd"

# $1 = extra swtpm args. Direct tool access needs --server; QEMU's emulator
# backend hands swtpm its data channel over --ctrl and fails with E2BIG
# (CMD_SET_DATAFD) if a --server channel is configured.
start_swtpm() {
    # shellcheck disable=SC2086
    swtpm socket --tpmstate dir="$WORKDIR/tpm" $1 \
        --ctrl type=unixio,path="$WORKDIR/swtpm-ctrl" \
        --tpm2 --flags startup-clear >>"$WORKDIR/swtpm.log" 2>&1 &
    SWTPM_PID=$!
    for _ in $(seq 50); do [ -S "$WORKDIR/swtpm-ctrl" ] && return 0; sleep 0.1; done
    echo "ERROR: swtpm did not start" >&2; exit 1
}

echo "=== 1. swtpm + DI (quick-di-tpm) ==="
start_swtpm "--server type=unixio,path=$WORKDIR/swtpm-server"
FDO_TPM_DEVICE="$WORKDIR/swtpm-server" "$QUICK_DI" -quick -protocol-version 2.0 \
    -rv 10.0.2.2:8080:http -device-info FDO-WinPE-Spike -output-dir "$WORKDIR/vouchers" \
    >"$WORKDIR/di.log" 2>&1 || { cat "$WORKDIR/di.log"; exit 1; }
grep -iE "guid|complete" "$WORKDIR/di.log" | head -5

echo "=== 2. Linux baseline (swtpm socket) ==="
FDO_TPM_DEVICE="$WORKDIR/swtpm-server" "$PROBE" | tee "$WORKDIR/probe-linux.log"

# Restart swtpm ctrl-only for QEMU; the TPM state persists in tpm/.
kill "$SWTPM_PID"; wait "$SWTPM_PID" 2>/dev/null || true
rm -f "$WORKDIR"/swtpm-server "$WORKDIR"/swtpm-ctrl
start_swtpm ""

echo "=== 3. WinPE via wimboot (KVM, $TPM_MODEL, e1000e), timeout ${TIMEOUT_QEMU}s ==="
start=$(date +%s)
# Screenshots every 20s via the monitor socket (root-owned, QEMU runs as root).
(
    n=0
    while sleep 20; do
        [ -S "$WORKDIR/monitor.sock" ] || continue
        n=$((n + 1))
        sudo python3 - "$WORKDIR/monitor.sock" "$WORKDIR/screen-$(printf %03d $n).ppm" <<'EOF' || break
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(("screendump " + sys.argv[2] + "\n").encode()); time.sleep(1); s.close()
EOF
    done
) &
SHOT_PID=$!
set +e
sudo timeout "$TIMEOUT_QEMU" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -smp 4 -m 4096 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
    -drive file="$WORKDIR/disk.img",format=raw,if=none,id=d0 \
    -device ahci,id=ahci -device ide-hd,drive=d0,bus=ahci.0 \
    -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device "$TPM_MODEL",tpmdev=tpm0 \
    -netdev user,id=n0 -device e1000e,netdev=n0 \
    -vga std -display none \
    -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
    -serial file:"$WORKDIR/serial.log" >"$WORKDIR/qemu.log" 2>&1
rc=$?
set -e
kill "$SHOT_PID" 2>/dev/null || true
echo "qemu exit=$rc after $(( $(date +%s) - start ))s (124 = timeout)"
sudo chown "$(id -u):$(id -g)" "$WORKDIR"/* 2>/dev/null || true

echo "=== 4. Results ==="
res_start=$(sfdisk -d "$WORKDIR/disk.img" | sed -n 's/.*start= *\([0-9]*\),.*name="FDORES".*/\1/p')
if [ -n "$res_start" ] && mtype -i "$WORKDIR/disk.img@@$(( res_start * 512 ))" ::/spike.log >"$WORKDIR/spike.log" 2>/dev/null; then
    tr -d '\r' <"$WORKDIR/spike.log"
else
    echo "no spike.log on the disk (WinPE did not reach fdo-spike.cmd?)"
fi
echo "--- compare (Linux vs WinPE) ---"
for k in "NV_Read DCTPM" "DCTPM decode" "load DAK" "HMAC (spec key)"; do
    l=$(grep -F "$k" "$WORKDIR/probe-linux.log" | head -1 | sed 's/^OK *//' || true)
    w=$(tr -d '\r' <"$WORKDIR/spike.log" 2>/dev/null | grep -F "$k" | head -1 | sed 's/^OK *//' || true)
    if [ -n "$l" ] && [ "$l" = "$w" ]; then echo "MATCH    $k"; else echo "MISMATCH $k"; echo "  linux: $l"; echo "  winpe: $w"; fi
done
