#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# start17-winpe-uki.sh - Windows Stage 1 end to end on the QEMU test host:
#   swtpm + DI (quick-di-tpm) -> owner server with fdo.bmo URL delivery of a
#   Windows UKI (winpe-uki-stub), SHA-256 pinned in image-begin -> TO0 ->
#   QEMU: fdo-uefi-rs TO1/TO2 -> download + hash check -> chainload ->
#   winpe-uki-stub -> wimboot -> WinPE -> fdo-spike.cmd runs tbs-probe.exe
#   over TBS against the same TPM and writes spike.log to a results disk.
#
# Usage: start17-winpe-uki.sh <winpe-uki.efi> [<tbs-probe linux binary>]
#
# Watching:
#   live page   http://127.0.0.1:$VIEW_PORT/ on this host (tunnel it), refreshes
#               every 3 s: latest screen, milestones, serial tail
#   serial      tail -f $WORKDIR/serial.log
#   VNC         127.0.0.1:$((5900 + VNC_DISPLAY)) on this host
#   afterwards  $WORKDIR/view/{index,timeline}.html, serial.txt, spike.log
#
# Env: WORKDIR (/tmp/fdo-win-bmo; keep on tmpfs), FDO_TOOL (~/server-installer), SERVER_DEBUG
#      (set: owner -debug; hex-dumps every message, slows inline BMO), QUICK_DI
#      (~/quick-di-tpm), EFI_DISK (~/bkgvm/efi-disk-release.img), MEM (4096),
#      TIMEOUT_QEMU (900), HTTP_PORT (9090), VIEW_PORT (8099), VNC_DISPLAY (7),
#      SHOT_SECS (5), NIC (WinPE NIC: e1000e,romfile=), FW_NIC (virtio-net-pci),
#      DELIVERY (url | inline),
#      BMO_SIGN (1; empty = unsigned image-begin, Model 1),
#      ARCHIVE_DIR (~/bkgvm/winspike/runs), RUN_TAG (suffix for the archive dir),
#      INSTALLED_BOOT (1 = Phase 3: see below), INSTALLED_TIMEOUT (1500),
#      SSH_FWD_PORT (2222)
#
# INSTALLED_BOOT=1 (needs TARGET_GB and an install.wim payload): a fresh SSH
# key pair is generated here and its public half delivered as the
# application/vnd.fdo.ssh-authorized-keys payload. After the WinPE run powers
# off, the target disk is booted ALONE (hostfwd :$SSH_FWD_PORT -> 22); the
# harness waits for sshd and logs in with StrictHostKeyChecking=yes against a
# known_hosts built only from the host keys the owner received over
# fdo.credentials (no TOFU), plus a negative control with a wrong host key.
#
# Every run is archived to $ARCHIVE_DIR/<timestamp>[-<RUN_TAG>]/ (view/ +
# owner/DI/TO0 logs), so later runs never overwrite earlier evidence.
#
# DELIVERY=url    signed image-begin carries URL + SHA-256; the device fetches
#                 over HTTP (fdo-uefi-rs caps the body at 512 MiB).
# DELIVERY=inline the image is chunked inside the TO2 session (no cap).
# TARGET_GB=60    attach an empty qcow2 target disk of that size (Stage 2).
# SERVER_EXTRA    extra owner args, word-split, e.g. Stage 2 payloads:
#                 "-payload application/vnd.microsoft.unattend+xml:/p/u.xml
#                  -request-pubkey device_info:device_info"
#
# Two NICs, each on its own user-mode network (both reach the host as
# 10.0.2.2): $FW_NIC (virtio-net) for the firmware stage and $NIC for WinPE
# (in-box Intel driver; WinPE has no virtio driver). The e1000e gets NO option
# ROM (romfile=): with QEMU's iPXE EFI ROM, OVMF drives it too, fdo-uefi-rs
# then runs TO2 over it, and every inline round takes ~1 s instead of ~25 ms
# (111 MB: 33 s via virtio vs <10 % after 150 s via the iPXE e1000e).
# No bootindex anywhere: with a QEMU boot order, OVMF connects ONLY the listed
# devices, so the NICs get no driver and the client finds no SNP handles.

set -euo pipefail

UKI=$(readlink -f "${1:?usage: $0 <winpe-uki.efi> [tbs-probe]}")
PROBE=${2:+$(readlink -f "$2")}
HERE=$(cd "$(dirname "$0")" && pwd)
# tmpfs: the owner commits SQLite state with ~20 fdatasync per message; on a
# spinning disk that is ~0.5 s per round (inline BMO, payload chunks).
WORKDIR=${WORKDIR:-/tmp/fdo-win-bmo}
FDO_TOOL=${FDO_TOOL:-$HOME/server-installer}
SERVER_DEBUG=${SERVER_DEBUG:-}
QUICK_DI=${QUICK_DI:-$HOME/quick-di-tpm}
EFI_DISK=${EFI_DISK:-$HOME/bkgvm/efi-disk-release.img}
MEM=${MEM:-4096}
TIMEOUT_QEMU=${TIMEOUT_QEMU:-900}
HTTP_PORT=${HTTP_PORT:-9090}
VIEW_PORT=${VIEW_PORT:-8099}
VNC_DISPLAY=${VNC_DISPLAY:-7}
SHOT_SECS=${SHOT_SECS:-5}
NIC=${NIC-e1000e,romfile=}
FW_NIC=${FW_NIC-virtio-net-pci}
DELIVERY=${DELIVERY:-url}
TARGET_GB=${TARGET_GB:-}
SERVER_EXTRA=${SERVER_EXTRA:-}
BMO_SIGN=${BMO_SIGN-1}
ACCEL=${ACCEL:-kvm}
SMP=${SMP:-4}
BMO_TYPE=${BMO_TYPE:-application/efi}
INSTALLED_BOOT=${INSTALLED_BOOT:-}
INSTALLED_TIMEOUT=${INSTALLED_TIMEOUT:-1500}
SSH_FWD_PORT=${SSH_FWD_PORT:-2222}
ARCHIVE_DIR=${ARCHIVE_DIR:-$HOME/bkgvm/winspike/runs}
RUN_TAG=${RUN_TAG:-}
FDO_PORT=8080

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    [ -d "$WORKDIR/view" ] && sudo touch "$WORKDIR/view/STOP"
}
trap cleanup EXIT

# Stop anything left from a previous run of this script.
if [ -f "$WORKDIR/pids" ]; then
    xargs -r kill <"$WORKDIR/pids" 2>/dev/null || true
    sleep 1
fi
sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{http,view,tpm,vouchers}
bg() { "$@" & PIDS+=($!); echo $! >>"$WORKDIR/pids"; }

echo "=== 0. Payload ==="
cp "$UKI" "$WORKDIR/http/winpe-uki.efi"
HASH=$(sha256sum "$WORKDIR/http/winpe-uki.efi" | cut -d' ' -f1)
echo "UKI $(stat -c %s "$WORKDIR/http/winpe-uki.efi") bytes, sha256 $HASH"
cp "$EFI_DISK" "$WORKDIR/efi-disk.img"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORKDIR/OVMF_VARS.fd"

# Results disk: GPT, one FAT "basic data" partition with FDORES.TAG.
truncate -s 80M "$WORKDIR/results.img"
printf 'label: gpt\nstart=1MiB, size=64MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="FDORES"\n' | sfdisk -q "$WORKDIR/results.img"
mformat -i "$WORKDIR/results.img@@1M" -F -v FDORES ::
printf 'fdo results volume\r\n' | mcopy -i "$WORKDIR/results.img@@1M" - ::/FDORES.TAG

echo "=== 1. Viewer: http://127.0.0.1:$VIEW_PORT/  VNC: 127.0.0.1:$((5900 + VNC_DISPLAY)) ==="
# The page server outlives this script (for after-the-fact viewing); the next
# run stops it via the pids file.
nohup python3 -m http.server "$VIEW_PORT" --bind 127.0.0.1 --directory "$WORKDIR/view" >"$WORKDIR/view-http.log" 2>&1 &
echo $! >>"$WORKDIR/pids"
sudo nohup python3 "$HERE/view.py" "$WORKDIR" "$SHOT_SECS" >"$WORKDIR/view.log" 2>&1 &
VIEW_PID=$!

echo "=== 2. Image HTTP server :$HTTP_PORT ==="
bg python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$WORKDIR/http" >"$WORKDIR/http.log" 2>&1

echo "=== 3. Owner DB, swtpm, DI ==="
timeout 10 "$FDO_TOOL" server -db "$WORKDIR/fdo.db" -http 127.0.0.1:$FDO_PORT -initOnly >/dev/null 2>&1 || true
"$FDO_TOOL" server -db "$WORKDIR/fdo.db" -print-owner-public SECP256R1 2>/dev/null | grep -A100 "BEGIN PUBLIC" >"$WORKDIR/owner.pem"

start_swtpm() { # $1 = extra args; QEMU needs a ctrl-only swtpm (see run-spike-pe2.sh)
    # shellcheck disable=SC2086
    swtpm socket --tpmstate dir="$WORKDIR/tpm" $1 \
        --ctrl type=unixio,path="$WORKDIR/swtpm-ctrl" \
        --tpm2 --flags startup-clear >>"$WORKDIR/swtpm.log" 2>&1 &
    SWTPM_PID=$!
    echo "$SWTPM_PID" >>"$WORKDIR/pids"
    PIDS+=("$SWTPM_PID")
    for _ in $(seq 50); do [ -S "$WORKDIR/swtpm-ctrl" ] && return 0; sleep 0.1; done
    echo "ERROR: swtpm did not start" >&2; exit 1
}
start_swtpm "--server type=unixio,path=$WORKDIR/swtpm-server"
FDO_TPM_DEVICE="$WORKDIR/swtpm-server" timeout 60 "$QUICK_DI" -quick -protocol-version 2.0 \
    -rv 10.0.2.2:$FDO_PORT:http -device-info FDO-WinPE-UKI -output-dir "$WORKDIR/vouchers" \
    -signover-key "$WORKDIR/owner.pem" >"$WORKDIR/di.log" 2>&1 || { cat "$WORKDIR/di.log"; exit 1; }
VOUCHER=$(ls -t "$WORKDIR"/vouchers/*.fdoov | head -1)
GUID=$(basename "$VOUCHER" .fdoov)
sed -i "s/FDO OWNERSHIP VOUCHER/OWNERSHIP VOUCHER/g" "$VOUCHER"
echo "GUID $GUID"
if [ -n "$PROBE" ]; then
    FDO_TPM_DEVICE="$WORKDIR/swtpm-server" "$PROBE" >"$WORKDIR/probe-linux.log" 2>&1 || true
    grep -E "^(OK|FAIL)|RESULT" "$WORKDIR/probe-linux.log"
fi
kill "$SWTPM_PID"; wait "$SWTPM_PID" 2>/dev/null || true
rm -f "$WORKDIR/swtpm-server" "$WORKDIR/swtpm-ctrl"
start_swtpm ""
"$FDO_TOOL" server -db "$WORKDIR/fdo.db" -import-voucher "$VOUCHER" -initOnly >"$WORKDIR/import.log" 2>&1 || true

if [ -n "$INSTALLED_BOOT" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "fdo-harness" -f "$WORKDIR/harness_id"
    SERVER_EXTRA="$SERVER_EXTRA -payload application/vnd.fdo.ssh-authorized-keys:$WORKDIR/harness_id.pub"
fi
if [ "$DELIVERY" = "inline" ]; then
    echo "=== 4. Owner server: fdo.bmo INLINE delivery (chunked inside TO2) ==="
    BMO_ARGS=(-bmo "$BMO_TYPE:$WORKDIR/http/winpe-uki.efi")
else
    echo "=== 4. Owner server: fdo.bmo URL delivery, hash pinned ==="
    BMO_ARGS=(-bmo-url "$BMO_TYPE:http://10.0.2.2:$HTTP_PORT/winpe-uki.efi:$HASH")
fi
# shellcheck disable=SC2086
bg "$FDO_TOOL" ${SERVER_DEBUG:+-debug} server -http 0.0.0.0:$FDO_PORT -db "$WORKDIR/fdo.db" -reuse-cred \
    "${BMO_ARGS[@]}" ${BMO_SIGN:+-bmo-sign} $SERVER_EXTRA >"$WORKDIR/server.log" 2>&1
sleep 2
kill -0 "${PIDS[-1]}" 2>/dev/null || { echo "ERROR: owner server died"; cat "$WORKDIR/server.log"; exit 1; }
timeout 30 "$FDO_TOOL" server -db "$WORKDIR/fdo.db" -to0 http://127.0.0.1:$FDO_PORT -to0-guid "$GUID" \
    -ext-http "10.0.2.2:$FDO_PORT" \
    >"$WORKDIR/to0.log" 2>&1 || echo "WARN: TO0 registration failed (see to0.log)"

echo "=== 5. QEMU (KVM, ${MEM} MiB, $NIC, tpm-tis), timeout ${TIMEOUT_QEMU}s ==="
echo "    live:   ssh -L $VIEW_PORT:127.0.0.1:$VIEW_PORT <this host>  then  http://localhost:$VIEW_PORT/"
echo "    serial: ssh <this host> tail -f $WORKDIR/serial.log"
FW_NIC_ARGS=()
[ -n "$FW_NIC" ] && FW_NIC_ARGS=(-netdev user,id=n0 -device "$FW_NIC",netdev=n0)
NIC_ARGS=()
[ -n "$NIC" ] && NIC_ARGS=(-netdev user,id=n1 -device "$NIC",netdev=n1)
TARGET_ARGS=()
if [ -n "$TARGET_GB" ]; then
    qemu-img create -q -f qcow2 "$WORKDIR/target.qcow2" "${TARGET_GB}G"
    TARGET_ARGS=(-drive file="$WORKDIR/target.qcow2",format=qcow2,if=none,id=d2 -device ide-hd,drive=d2,bus=ahci.2)
    echo "    target disk: $WORKDIR/target.qcow2 (${TARGET_GB} GB)"
fi
start=$(date +%s)
set +e
if [ -n "${LEGACY_QEMU:-}" ]; then
    # A/B: exactly the device set of test-installer-pe2.sh (no results disk,
    # one virtio NIC, default disk bus, 8 GiB, no -smp/-cpu).
    echo "    LEGACY_QEMU: test-installer-pe2.sh device set"
    sudo timeout "$TIMEOUT_QEMU" qemu-system-x86_64 \
        -machine q35 -m 8192 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
        -drive file="$WORKDIR/efi-disk.img",format=raw,index=0 \
        -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -device virtio-rng-pci \
        -nic user,model=virtio-net-pci \
        -vnc 127.0.0.1:"$VNC_DISPLAY" \
        -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
        -serial file:"$WORKDIR/serial.log" >"$WORKDIR/qemu.log" 2>&1
else
sudo timeout "$TIMEOUT_QEMU" qemu-system-x86_64 \
    -machine q35 -accel "$ACCEL" $([ "$ACCEL" = kvm ] && echo "-cpu host") -smp "$SMP" -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
    -device ahci,id=ahci \
    -drive file="$WORKDIR/efi-disk.img",format=raw,if=none,id=d0 -device ide-hd,drive=d0,bus=ahci.0 \
    -drive file="$WORKDIR/results.img",format=raw,if=none,id=d1 -device ide-hd,drive=d1,bus=ahci.1 \
    "${TARGET_ARGS[@]}" \
    -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -device virtio-rng-pci \
    "${FW_NIC_ARGS[@]}" \
    "${NIC_ARGS[@]}" \
    -vga std -display none -vnc 127.0.0.1:"$VNC_DISPLAY" \
    -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
    -serial file:"$WORKDIR/serial.log" >"$WORKDIR/qemu.log" 2>&1
fi
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
echo "qemu exit=$rc after ${elapsed}s (124 = timeout)"

echo "=== 6. Results ==="
logs=$(mdir -i "$WORKDIR/results.img@@1M" -b ::/ 2>/dev/null | grep -i '\.log$' || true)
for f in $logs; do
    name=$(basename "$f" | tr '[:upper:]' '[:lower:]')
    mtype -i "$WORKDIR/results.img@@1M" "::/$name" 2>/dev/null | tr -d '\r' >"$WORKDIR/view/$name"
    echo "--- $name ($(wc -l <"$WORKDIR/view/$name") lines) ---"
    grep -E "^(OK|FAIL)|RESULT|-exit=|IPv4|Description|ERROR|--- (PASS|FAIL)|TO2|[Pp]ayload|[Cc]redential|install.wim|unattend" "$WORKDIR/view/$name" | head -60 || true
done
[ -n "$logs" ] || echo "no *.log on the results disk (WinPE did not run its script)"
sudo touch "$WORKDIR/view/STOP"
wait "$VIEW_PID" 2>/dev/null || true
sudo chown -R "$(id -u):$(id -g)" "$WORKDIR"

echo "--- milestones (serial) ---"
tr -d '\r' <"$WORKDIR/serial.log" | sed 's/\x1b\[[0-9;=?]*[A-Za-z]//g' \
    | grep -E "BMO: (URL|image|Fetch|Down)|SHA256|Chainload(ing|:.*(load|Start))|winpe-uki-stub|wimboot v|starting wimboot|found WIM|patching WIM|REFUS|ERROR|error" \
    | head -30 || true
echo "--- server (bmo) ---"
grep -iE "bmo|image-begin|ack|result" "$WORKDIR/server.log" | grep -v DEBUG | head -10 || true
echo "--- owner: payload / credentials ---"
grep -iE "payload|credential|device_info|public key" "$WORKDIR/server.log" | head -20 || true
if [ -n "$PROBE" ] && [ -s "$WORKDIR/view/spike.log" ]; then
    echo "--- compare (Linux vs WinPE) ---"
    for k in "NV_Read DCTPM" "DCTPM decode" "load DAK" "HMAC (spec key)"; do
        l=$(grep -F "$k" "$WORKDIR/probe-linux.log" | head -1 | sed 's/^OK *//' || true)
        w=$(grep -F "$k" "$WORKDIR/view/spike.log" | head -1 | sed 's/^OK *//' || true)
        if [ -n "$l" ] && [ "$l" = "$w" ]; then echo "MATCH    $k"; else echo "MISMATCH $k"; echo "  linux: $l"; echo "  winpe: $w"; fi
    done
fi
echo "--- after the fact: $WORKDIR/view/index.html, timeline.html ($(ls "$WORKDIR"/view/shot-*.png 2>/dev/null | wc -l) screenshots), serial.txt"

if [ -n "$INSTALLED_BOOT" ] && [ -f "$WORKDIR/target.qcow2" ]; then
    echo "=== 7. Boot the installed disk alone (first boot: specialize, OOBE, SetupComplete) ==="
    # FDO-registered host keys -> known_hosts (the only keys we will trust).
    KH="$WORKDIR/known_hosts.fdo"
    grep -A3 "Received public key registration" "$WORKDIR/server.log" | sed -n 's/^ *Key: *//p' | tail -1 \
        | sed 's/ (length: [0-9]* bytes)$//' \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("[127.0.0.1]:'"$SSH_FWD_PORT"'", " ".join(d[k].split()[:2])) for k in ("ssh_host_ed25519_key","ssh_host_ecdsa_key","ssh_host_rsa_key") if d.get(k)]' \
        >"$KH" || true
    echo "    known_hosts from fdo.credentials: $(wc -l <"$KH") keys"
    sed 's/^/      /' "$KH" | cut -c1-110
    start_swtpm_if_gone() {
        kill -0 "$SWTPM_PID" 2>/dev/null && [ -S "$WORKDIR/swtpm-ctrl" ] && return 0
        rm -f "$WORKDIR/swtpm-ctrl"; start_swtpm ""
    }
    start_swtpm_if_gone
    sudo nohup python3 "$HERE/view.py" "$WORKDIR" "$SHOT_SECS" installed >"$WORKDIR/view-installed.log" 2>&1 &
    VIEW2_PID=$!
    istart=$(date +%s)
    sudo timeout "$INSTALLED_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -accel "$ACCEL" $([ "$ACCEL" = kvm ] && echo "-cpu host") -smp "$SMP" -m "$MEM" \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
        -device ahci,id=ahci \
        -drive file="$WORKDIR/target.qcow2",format=qcow2,if=none,id=d2 -device ide-hd,drive=d2,bus=ahci.0 \
        -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
        -netdev user,id=n1,hostfwd=tcp:127.0.0.1:"$SSH_FWD_PORT"-:22 -device e1000e,romfile=,netdev=n1 \
        -vga std -display none -vnc 127.0.0.1:"$VNC_DISPLAY" \
        -monitor unix:"$WORKDIR/monitor-installed.sock",server,nowait \
        -serial file:"$WORKDIR/serial-installed.log" >"$WORKDIR/qemu-installed.log" 2>&1 &
    QEMU2_PID=$!
    SSH_OPTS=(-i "$WORKDIR/harness_id" -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10
              -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" -o GlobalKnownHostsFile=/dev/null)
    up=""
    while kill -0 "$QEMU2_PID" 2>/dev/null; do
        if ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 "hostname" >"$WORKDIR/ssh-hostname.txt" 2>"$WORKDIR/ssh-err.txt"; then
            up=$(( $(date +%s) - istart )); break
        fi
        sleep 15
    done
    if [ -n "$up" ]; then
        echo "    SSH up after ${up}s, host key verified against fdo.credentials keys (StrictHostKeyChecking=yes)"
        ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 \
            'hostname & type C:\fdo-installed.txt & type C:\Windows\Setup\Scripts\SetupComplete.log & sc query sshd | find "STATE" & ver & echo --- leftovers (expect only *.pub, no unattend): & dir /b C:\fdo\ssh-host-keys & dir /b C:\Windows\Panther\unattend.xml C:\fdo\unattend.xml & echo --- sshd host key ACL: & icacls C:\ProgramData\ssh\ssh_host_ed25519_key' \
            2>&1 | tr -d '\r' | tee "$WORKDIR/view/installed-check.log" | sed 's/^/      /'
        # Negative control: same server, a known_hosts with a WRONG key must be refused.
        ssh-keygen -q -t ed25519 -N "" -f "$WORKDIR/bogus_hostkey"
        echo "[127.0.0.1]:$SSH_FWD_PORT $(cut -d' ' -f1,2 "$WORKDIR/bogus_hostkey.pub")" >"$WORKDIR/known_hosts.bogus"
        if ssh -i "$WORKDIR/harness_id" -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
               -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WORKDIR/known_hosts.bogus" \
               -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 \
               Administrator@127.0.0.1 hostname >/dev/null 2>"$WORKDIR/ssh-negative.txt"; then
            echo "    NEGATIVE CONTROL FAILED: login succeeded with a wrong host key"
        else
            echo "    negative control OK: $(grep -m1 -iE 'verification failed|IDENTIFICATION HAS CHANGED' "$WORKDIR/ssh-negative.txt")"
        fi
        ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'shutdown /s /t 5' >/dev/null 2>&1 || true
    else
        echo "    SSH never came up (last error: $(tail -1 "$WORKDIR/ssh-err.txt"))"
    fi
    wait "$QEMU2_PID" 2>/dev/null || true
    echo "    installed VM exited after $(( $(date +%s) - istart ))s"
    sudo touch "$WORKDIR/view/installed/STOP" 2>/dev/null || true
    wait "$VIEW2_PID" 2>/dev/null || true
    sudo sed -i 's|full serial log</a>|full serial log</a> \| <a href="installed/index.html">installed-system boot</a>|' "$WORKDIR/view/index.html"
    sudo chown -R "$(id -u):$(id -g)" "$WORKDIR"
fi

# Archive every run (WORKDIR is wiped by the next run).
RUN_DIR="$ARCHIVE_DIR/$(date +%Y%m%d-%H%M%S)${RUN_TAG:+-$RUN_TAG}"
mkdir -p "$RUN_DIR"
cp -a "$WORKDIR/view" "$RUN_DIR/"
cp -a "$WORKDIR"/{server,to0,di,qemu}.log "$RUN_DIR/" 2>/dev/null || true
echo "--- archived: $RUN_DIR"
