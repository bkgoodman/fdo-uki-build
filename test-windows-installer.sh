#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end test of the Windows FDO installer on a QEMU test host. Exits 0
# only if every check passes (RESULT: PASS), so it can run unattended.
#
#   1. swtpm + DI (quick-di-tpm) -> voucher; owner server: fdo.bmo (Windows
#      UKI, URL + SHA-256 in a signed image-begin, or inline), fdo.payload
#      (answer file, install image, harness SSH key), fdo.credentials; TO0
#   2. device VM: fdo-uefi-rs TO1/TO2 -> BMO -> chainload -> WinPE ->
#      fdo-stage2.cmd: diskpart, TO1/TO2 over TBS, payloads, DISM, bcdboot ->
#      power off
#   3. the installed disk is booted alone: first-boot setup, SetupComplete.cmd;
#      the harness logs in over SSH with StrictHostKeyChecking=yes against ONLY
#      the host keys the owner received over fdo.credentials, checks the
#      system, runs a wrong-host-key negative control, and shuts it down
#
# Inputs ($FDO_FIRMWARE_DIR, from build-windows-installer.sh DEPLOY=1):
#   $INSTALLER_UKI_NAME, $INSTALL_WIM_NAME, unattend-test.xml
#
# Watching (all on this host; tunnel the ports):
#   live page  http://127.0.0.1:$VIEW_PORT/  (screenshots, milestones, serial)
#   serial     tail -f $WORKDIR/serial.log      VNC  127.0.0.1:5900+$VNC_DISPLAY
# Every run is archived to $ARCHIVE_DIR/<timestamp>[-<RUN_TAG>]/ (view/, logs,
# result.txt); the last line naming it is "ARCHIVE: <dir>".
#
# Env (defaults in brackets):
#   FDO_FIRMWARE_DIR [/tmp/fdo-firmware-server]  WORKDIR [/tmp/fdo-windows-test]
#   FDO_SERVER [~/server-installer]  FDO_QUICK_DI [~/quick-di-tpm]
#   FDO_EFI_DISK [~/efi-disk-release.img, else ~/bkgvm/efi-disk-release.img]
#   ARCHIVE_DIR [~/fdo-windows-runs]  RUN_TAG  KEEP_DISK [0: 1 = archive the
#   installed disk too, ~9 GB, for boot-installed-windows.sh]
#   DELIVERY [url | inline]  BMO_SIGN [1; empty = unsigned]  INSTALL [1; 0 =
#   stop after Stage 2 delivery, no image / installed boot]
#   ANSWER_MODE [password: the answer file as is, with its demo Administrator
#   password; password login must work | ssh-only: the same file without
#   UserAccounts; the device must randomize the password and make sshd
#   key-only; the demo password must be refused]
#   MEM [4096]  SMP [4]  ACCEL [kvm]  TARGET_GB [60]  TIMEOUT_QEMU [1800]
#   INSTALLED_TIMEOUT [1500]  VIEW_PORT [8099]  HTTP_PORT [9090]
#   SSH_FWD_PORT / VNC_DISPLAY [first free from 2222 / 7]  SHOT_SECS [5]
#   NIC [e1000e,romfile=]  FW_NIC [virtio-net-pci]  SERVER_DEBUG  SERVER_EXTRA
#   BAD_UKI_HASH=1  negative test: the owner signs a wrong SHA-256 for the UKI
#                   (URL delivery); the device must refuse it -> RESULT: FAIL
#                   (use a short TIMEOUT_QEMU, e.g. 300)
#
# QEMU notes (details: README-WINDOWS.md "Windows-specific gotchas"):
#   - No bootindex: with a QEMU boot order OVMF connects only the listed
#     devices, so the UEFI client would see no NIC.
#   - Two NICs on separate user networks (both reach the host as 10.0.2.2):
#     virtio-net for the firmware stage, e1000e for WinPE (in-box driver; no
#     virtio driver in WinPE). The e1000e gets NO option ROM: with QEMU's iPXE
#     ROM, OVMF drives it too and inline BMO rounds take ~1 s instead of ~25 ms.
#   - WORKDIR must be on tmpfs: the owner commits SQLite state with ~20
#     fdatasync per message (~0.5 s per round on a spinning disk).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
for env in "$HERE/config/windows-installer.env" "$HERE/windows-installer.env"; do
    # shellcheck source=config/windows-installer.env
    [ -f "$env" ] && { source "$env"; break; }
done
VIEW_PY=$HERE/windows/view.py
[ -f "$VIEW_PY" ] || VIEW_PY=$HERE/view.py

FIRMWARE_DIR=${FDO_FIRMWARE_DIR:-/tmp/fdo-firmware-server}
UKI=${UKI:-$FIRMWARE_DIR/${INSTALLER_UKI_NAME:-windows-server-2025-fdo.efi}}
INSTALL_WIM=${INSTALL_WIM:-$FIRMWARE_DIR/${INSTALL_WIM_NAME:-windows-server-2025-standard-core.wim}}
UNATTEND=${UNATTEND:-$FIRMWARE_DIR/$(basename "${WINDOWS_UNATTEND:-unattend-test.xml}")}
UNATTEND_MIME=${WINDOWS_UNATTEND_MIME:-application/vnd.microsoft.unattend+xml}
WIM_MIME=${WINDOWS_WIM_MIME:-application/vnd.microsoft.wim}
WORKDIR=${WORKDIR:-/tmp/fdo-windows-test}
FDO_TOOL=${FDO_SERVER:-$HOME/server-installer}
QUICK_DI=${FDO_QUICK_DI:-$HOME/quick-di-tpm}
EFI_DISK=${FDO_EFI_DISK:-$HOME/efi-disk-release.img}
[ -f "$EFI_DISK" ] || EFI_DISK=$HOME/bkgvm/efi-disk-release.img
ARCHIVE_DIR=${ARCHIVE_DIR:-$HOME/fdo-windows-runs}
RUN_TAG=${RUN_TAG:-}
KEEP_DISK=${KEEP_DISK:-0}
DELIVERY=${DELIVERY:-url}
BMO_SIGN=${BMO_SIGN-1}
BMO_TYPE=${BMO_TYPE:-application/efi}
INSTALL=${INSTALL:-1}
ANSWER_MODE=${ANSWER_MODE:-password}
case $ANSWER_MODE in password | ssh-only) ;; *) echo "ANSWER_MODE must be password or ssh-only" >&2; exit 2 ;; esac
MEM=${MEM:-4096}
SMP=${SMP:-4}
ACCEL=${ACCEL:-kvm}
TARGET_GB=${TARGET_GB:-60}
TIMEOUT_QEMU=${TIMEOUT_QEMU:-1800}
INSTALLED_TIMEOUT=${INSTALLED_TIMEOUT:-1500}
VIEW_PORT=${VIEW_PORT:-8099}
HTTP_PORT=${HTTP_PORT:-9090}
SHOT_SECS=${SHOT_SECS:-5}
NIC=${NIC-e1000e,romfile=}
FW_NIC=${FW_NIC-virtio-net-pci}
SERVER_DEBUG=${SERVER_DEBUG:-}
SERVER_EXTRA=${SERVER_EXTRA:-}
FDO_PORT=8080

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
if [ -z "${SSH_FWD_PORT:-}" ]; then
    SSH_FWD_PORT=2222
    while port_busy "$SSH_FWD_PORT"; do SSH_FWD_PORT=$((SSH_FWD_PORT + 1)); done
fi
if [ -z "${VNC_DISPLAY:-}" ]; then
    VNC_DISPLAY=7
    while port_busy $((5900 + VNC_DISPLAY)); do VNC_DISPLAY=$((VNC_DISPLAY + 1)); done
fi

for f in "$FDO_TOOL" "$QUICK_DI" "$EFI_DISK" "$UKI" "$VIEW_PY"; do
    [ -e "$f" ] || { echo "Missing: $f" >&2; exit 2; }
done
if [ "$INSTALL" = "1" ]; then
    for f in "$INSTALL_WIM" "$UNATTEND"; do [ -e "$f" ] || { echo "Missing: $f" >&2; exit 2; }; done
fi
for p in "$FDO_PORT" "$HTTP_PORT"; do
    port_busy "$p" && { echo "Port $p is in use (another FDO server / test?)" >&2; exit 2; }
done

# ---- checks ---------------------------------------------------------------
CHECKS=()
FAILED=0
check() { # $1 = name, rest = command; records PASS/FAIL, never aborts
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then CHECKS+=("PASS  $name"); else CHECKS+=("FAIL  $name"); FAILED=1; fi
}
logfile_has() { grep -qE "$2" "$1" 2>/dev/null; }

PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    [ -d "$WORKDIR/view" ] && sudo touch "$WORKDIR/view/STOP"
}
trap cleanup EXIT

# Stop anything left from a previous run of this script. Only PIDs whose
# command line names $WORKDIR: after a reboot a stale PID may be anything.
if [ -f "$WORKDIR/pids" ]; then
    while read -r pid; do
        [ -n "$pid" ] && grep -qaF "$WORKDIR" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid" 2>/dev/null
    done <"$WORKDIR/pids" || true
    sleep 1
fi
sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{http,view,tpm,vouchers}
bg() { "$@" & PIDS+=($!); echo $! >>"$WORKDIR/pids"; }
START=$(date +%s)

echo "=== 0. Inputs ==="
cp "$UKI" "$WORKDIR/http/winpe-uki.efi"
HASH=$(sha256sum "$WORKDIR/http/winpe-uki.efi" | cut -d' ' -f1)
echo "UKI         $(basename "$UKI") $(stat -c %s "$UKI") bytes, sha256 $HASH"
if [ "$INSTALL" = "1" ]; then
    echo "image       $(basename "$INSTALL_WIM") $(stat -c %s "$INSTALL_WIM") bytes"
    EXPECT_HOST=$(tr -d '\r' <"$UNATTEND" | sed -n 's:.*<ComputerName>\(.*\)</ComputerName>.*:\1:p' | head -1)
    # The demo password (used to prove password login works, or is refused)
    DEMO_PW=$(tr -d '\r\n' <"$UNATTEND" | sed -n 's:.*<AdministratorPassword>[[:space:]]*<Value>\([^<]*\)</Value>.*:\1:p')
    [ -n "$DEMO_PW" ] || { echo "answer file has no AdministratorPassword to derive both modes from" >&2; exit 2; }
    if [ "$ANSWER_MODE" = "ssh-only" ]; then
        # Same answer file without UserAccounts -> the device must go SSH-only.
        python3 - "$UNATTEND" "$WORKDIR/unattend-ssh-only.xml" <<'PY'
import re, sys
doc = open(sys.argv[1], newline='').read()
out = re.sub(r'(?s)\s*<UserAccounts>.*?</UserAccounts>', '', doc)
assert '<AdministratorPassword' not in out
open(sys.argv[2], 'w', newline='').write(out)
PY
        UNATTEND=$WORKDIR/unattend-ssh-only.xml
    fi
    echo "answer file $(basename "$UNATTEND") (ComputerName=$EXPECT_HOST, mode=$ANSWER_MODE)"
fi
cp "$EFI_DISK" "$WORKDIR/efi-disk.img"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORKDIR/OVMF_VARS.fd"
# Results disk: GPT, one FAT "basic data" partition (Windows gives no drive
# letter to an EFI system partition); fdo-stage2.cmd writes stage2.log there.
truncate -s 80M "$WORKDIR/results.img"
printf 'label: gpt\nstart=1MiB, size=64MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="FDORES"\n' | sfdisk -q "$WORKDIR/results.img"
mformat -i "$WORKDIR/results.img@@1M" -F -v FDORES ::
printf 'fdo results volume\r\n' | mcopy -i "$WORKDIR/results.img@@1M" - ::/FDORES.TAG

echo "=== 1. Viewer http://127.0.0.1:$VIEW_PORT/  VNC 127.0.0.1:$((5900 + VNC_DISPLAY))  SSH (installed) 127.0.0.1:$SSH_FWD_PORT ==="
if ! port_busy "$VIEW_PORT"; then
    # outlives this script for after-the-fact viewing; the next run stops it
    nohup python3 -m http.server "$VIEW_PORT" --bind 127.0.0.1 --directory "$WORKDIR/view" >"$WORKDIR/view-http.log" 2>&1 &
    echo $! >>"$WORKDIR/pids"
else
    echo "    (port $VIEW_PORT busy: live page not served; files still in $WORKDIR/view)"
fi
sudo nohup python3 "$VIEW_PY" "$WORKDIR" "$SHOT_SECS" >"$WORKDIR/view.log" 2>&1 &
VIEW_PID=$!
bg python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$WORKDIR/http" >"$WORKDIR/http.log" 2>&1

echo "=== 2. Owner DB, swtpm, DI ==="
timeout 10 "$FDO_TOOL" server -db "$WORKDIR/fdo.db" -http 127.0.0.1:$FDO_PORT -initOnly >/dev/null 2>&1 || true
"$FDO_TOOL" server -db "$WORKDIR/fdo.db" -print-owner-public SECP256R1 2>/dev/null | grep -A100 "BEGIN PUBLIC" >"$WORKDIR/owner.pem"
start_swtpm() { # $1 = extra args. QEMU needs a ctrl-only swtpm: with --server
    #             configured too, QEMU fails with CMD_SET_DATAFD E2BIG.
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
    -rv 10.0.2.2:$FDO_PORT:http -device-info FDO-Windows-Installer -output-dir "$WORKDIR/vouchers" \
    -signover-key "$WORKDIR/owner.pem" >"$WORKDIR/di.log" 2>&1 || { cat "$WORKDIR/di.log"; exit 1; }
VOUCHER=$(ls -t "$WORKDIR"/vouchers/*.fdoov | head -1)
GUID=$(basename "$VOUCHER" .fdoov)
sed -i "s/FDO OWNERSHIP VOUCHER/OWNERSHIP VOUCHER/g" "$VOUCHER"
echo "GUID $GUID"
kill "$SWTPM_PID"; wait "$SWTPM_PID" 2>/dev/null || true
rm -f "$WORKDIR/swtpm-server" "$WORKDIR/swtpm-ctrl"
start_swtpm ""
"$FDO_TOOL" server -db "$WORKDIR/fdo.db" -import-voucher "$VOUCHER" -initOnly >"$WORKDIR/import.log" 2>&1 || true

echo "=== 3. Owner server (delivery=$DELIVERY, signed=${BMO_SIGN:-no}) + TO0 ==="
if [ "$DELIVERY" = "inline" ]; then
    BMO_ARGS=(-bmo "$BMO_TYPE:$WORKDIR/http/winpe-uki.efi")
else
    BMO_HASH=$HASH
    if [ "${BAD_UKI_HASH:-0}" = "1" ]; then
        # Negative test of the device AND this harness: the owner signs a
        # wrong SHA-256; the device must refuse the image, the run must FAIL.
        BMO_HASH=$(printf 'not the UKI' | sha256sum | cut -d' ' -f1)
        echo "    NEGATIVE RUN: image-begin carries a wrong SHA-256 ($BMO_HASH); expect RESULT: FAIL"
    fi
    BMO_ARGS=(-bmo-url "$BMO_TYPE:http://10.0.2.2:$HTTP_PORT/winpe-uki.efi:$BMO_HASH")
fi
PAYLOAD_ARGS=(-request-pubkey device_info:device_info)
if [ "$INSTALL" = "1" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "fdo-harness" -f "$WORKDIR/harness_id"
    # order matters: the answer file first, then the image, then the admin key
    PAYLOAD_ARGS+=(-payload "$UNATTEND_MIME:$UNATTEND" -payload "$WIM_MIME:$INSTALL_WIM"
                   -payload "application/vnd.fdo.ssh-authorized-keys:$WORKDIR/harness_id.pub")
fi
# shellcheck disable=SC2086
bg "$FDO_TOOL" ${SERVER_DEBUG:+-debug} server -http 0.0.0.0:$FDO_PORT -db "$WORKDIR/fdo.db" -reuse-cred \
    "${BMO_ARGS[@]}" ${BMO_SIGN:+-bmo-sign} "${PAYLOAD_ARGS[@]}" $SERVER_EXTRA >"$WORKDIR/server.log" 2>&1
sleep 2
kill -0 "${PIDS[-1]}" 2>/dev/null || { echo "ERROR: owner server died"; cat "$WORKDIR/server.log"; exit 1; }
timeout 30 "$FDO_TOOL" server -db "$WORKDIR/fdo.db" -to0 http://127.0.0.1:$FDO_PORT -to0-guid "$GUID" \
    -ext-http "10.0.2.2:$FDO_PORT" >"$WORKDIR/to0.log" 2>&1 || true
check "TO0 registration" logfile_has "$WORKDIR/to0.log" "RV blob registered"

echo "=== 4. Device VM: Stage 1 (UEFI) + Stage 2 (WinPE), timeout ${TIMEOUT_QEMU}s ==="
echo "    serial: tail -f $WORKDIR/serial.log"
FW_NIC_ARGS=()
[ -n "$FW_NIC" ] && FW_NIC_ARGS=(-netdev user,id=n0 -device "$FW_NIC",netdev=n0)
NIC_ARGS=()
[ -n "$NIC" ] && NIC_ARGS=(-netdev user,id=n1 -device "$NIC",netdev=n1)
qemu-img create -q -f qcow2 "$WORKDIR/target.qcow2" "${TARGET_GB}G"
CPU_ARGS=()
[ "$ACCEL" = kvm ] && CPU_ARGS=(-cpu host)
t0=$(date +%s)
set +e
sudo timeout "$TIMEOUT_QEMU" qemu-system-x86_64 \
    -machine q35 -accel "$ACCEL" "${CPU_ARGS[@]}" -smp "$SMP" -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$WORKDIR/OVMF_VARS.fd" \
    -device ahci,id=ahci \
    -drive file="$WORKDIR/efi-disk.img",format=raw,if=none,id=d0 -device ide-hd,drive=d0,bus=ahci.0 \
    -drive file="$WORKDIR/results.img",format=raw,if=none,id=d1 -device ide-hd,drive=d1,bus=ahci.1 \
    -drive file="$WORKDIR/target.qcow2",format=qcow2,if=none,id=d2 -device ide-hd,drive=d2,bus=ahci.2 \
    -chardev socket,id=chrtpm,path="$WORKDIR/swtpm-ctrl" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -device virtio-rng-pci \
    "${FW_NIC_ARGS[@]}" "${NIC_ARGS[@]}" \
    -vga std -display none -vnc 127.0.0.1:"$VNC_DISPLAY" \
    -monitor unix:"$WORKDIR/monitor.sock",server,nowait \
    -serial file:"$WORKDIR/serial.log" >"$WORKDIR/qemu.log" 2>&1
rc=$?
set -e
STAGE12_S=$(( $(date +%s) - t0 ))
echo "    device VM exit=$rc after ${STAGE12_S}s (124 = timeout)"
check "device VM powered off by itself (no timeout)" test "$rc" -eq 0

# stage2.log (and dism.log on failure) from the results disk
for f in $(mdir -i "$WORKDIR/results.img@@1M" -b ::/ 2>/dev/null | grep -i '\.log$' || true); do
    name=$(basename "$f" | tr '[:upper:]' '[:lower:]')
    mtype -i "$WORKDIR/results.img@@1M" "::/$name" 2>/dev/null | tr -d '\r' >"$WORKDIR/view/$name"
done
sudo touch "$WORKDIR/view/STOP"
wait "$VIEW_PID" 2>/dev/null || true
sudo chown -R "$(id -u):$(id -g)" "$WORKDIR"
SERIAL_TXT=$(tr -d '\r' <"$WORKDIR/serial.log" | sed 's/\x1b\[[0-9;=?]*[A-Za-z]//g')
S2=$WORKDIR/view/stage2.log

check "Stage 1: TO2 complete (voucher + owner signature verified)" grep -q "TO2 Protocol Complete" <<<"$SERIAL_TXT"
check "Stage 1: BMO image integrity verified" grep -qE "Image ready for boot .*integrity verified|BMO image received" <<<"$SERIAL_TXT"
check "Stage 1: chainloaded winpe-uki-stub" grep -q "winpe-uki-stub [0-9]" <<<"$SERIAL_TXT"
check "Boot chain: wimboot found boot.wim" grep -q "found WIM file boot.wim" <<<"$SERIAL_TXT"
check "Stage 2: fdo-stage2.cmd ran (stage2.log)" test -s "$S2"
check "Stage 2: TO2 with credential reuse" logfile_has "$S2" "TO2 Completed - Credential Reuse: true"
check "Stage 2: endpoint exit 0" logfile_has "$S2" "^endpoint-exit=0"
check "Owner: SSH host keys registered (fdo.credentials)" logfile_has "$WORKDIR/server.log" "Public key registered successfully"
if [ "$INSTALL" = "1" ]; then
    check "Stage 2: answer file delivered" logfile_has "$S2" "Payload streamed to W:.fdo.unattend.xml|unattend.xml received"
    check "Owner: all 3 payloads applied (answer file, image, admin key; hash-checked)" \
        test "$(grep -c 'fdo.payload applied successfully' "$WORKDIR/server.log")" -ge 3
    check "Stage 2: dism /Apply-Image exit 0" logfile_has "$S2" "^dism-exit=0"
    check "Stage 2: answer file staged in $ANSWER_MODE mode" \
        bash -c "grep -q '^answerfile-exit=0' '$S2' && grep -q '^mode=$ANSWER_MODE' '$S2'"
    check "Stage 2: bcdboot exit 0" logfile_has "$S2" "^bcdboot-exit=0"
    check "Stage 2: install staged" logfile_has "$S2" "^install-staged=1"
fi

INSTALLED_S=""
if [ "$INSTALL" = "1" ] && logfile_has "$S2" "^install-staged=1"; then
    echo "=== 5. Installed disk, booted alone: first-boot setup, then SSH ==="
    KH=$WORKDIR/known_hosts.fdo
    grep -A3 "Received public key registration" "$WORKDIR/server.log" | sed -n 's/^ *Key: *//p' | tail -1 \
        | sed 's/ (length: [0-9]* bytes)$//' \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("[127.0.0.1]:'"$SSH_FWD_PORT"'", " ".join(d[k].split()[:2])) for k in ("ssh_host_ed25519_key","ssh_host_ecdsa_key","ssh_host_rsa_key") if d.get(k)]' \
        >"$KH" || true
    echo "    known_hosts from fdo.credentials only: $(wc -l <"$KH") keys"
    check "known_hosts built from the owner's fdo.credentials record" test "$(wc -l <"$KH")" -ge 1
    kill -0 "$SWTPM_PID" 2>/dev/null && [ -S "$WORKDIR/swtpm-ctrl" ] || { rm -f "$WORKDIR/swtpm-ctrl"; start_swtpm ""; }
    sudo nohup python3 "$VIEW_PY" "$WORKDIR" "$SHOT_SECS" installed >"$WORKDIR/view-installed.log" 2>&1 &
    VIEW2_PID=$!
    t1=$(date +%s)
    sudo timeout "$INSTALLED_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -accel "$ACCEL" "${CPU_ARGS[@]}" -smp "$SMP" -m "$MEM" \
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
    SSH=(ssh -i "$WORKDIR/harness_id" -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10
         -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" -o GlobalKnownHostsFile=/dev/null
         -o LogLevel=ERROR Administrator@127.0.0.1)
    up=""
    while kill -0 "$QEMU2_PID" 2>/dev/null; do
        if "${SSH[@]}" hostname >/dev/null 2>"$WORKDIR/ssh-err.txt"; then up=$(( $(date +%s) - t1 )); break; fi
        sleep 10
    done
    check "Installed: SSH up, host key = an FDO-registered key (StrictHostKeyChecking=yes)" test -n "$up"
    if [ -n "$up" ]; then
        INSTALLED_S=$up
        echo "    SSH up after ${up}s"
        "${SSH[@]}" 'hostname & type C:\fdo-installed.txt & sc query sshd | find "STATE" & sc qc sshd | find "START_TYPE" & ver & echo ---leftovers--- & dir /b C:\fdo\ssh-host-keys & dir /b C:\Windows\Panther\unattend.xml C:\fdo\unattend.xml & echo ---acl--- & icacls C:\ProgramData\ssh\ssh_host_ed25519_key & echo ---setupcomplete--- & type C:\Windows\Setup\Scripts\SetupComplete.log' \
            2>&1 | tr -d '\r' >"$WORKDIR/view/installed-check.log" || true
        IC=$WORKDIR/view/installed-check.log
        sed 's/^/      /' "$IC" | head -12
        check "Installed: hostname = answer file ComputerName ($EXPECT_HOST)" grep -qix "$EXPECT_HOST" <(head -1 "$IC")
        check "Installed: SetupComplete.cmd ran (marker)" grep -q "^fdo-installed" "$IC"
        check "Installed: sshd running, auto-start" bash -c "grep -q 'RUNNING' '$IC' && grep -q 'AUTO_START' '$IC'"
        check "Installed: no private host-key copies left in C:\\fdo" bash -c "sed -n '/---leftovers---/,/---acl---/p' '$IC' | grep -E '^ssh_host_.*_key$' | grep -q . && exit 1 || exit 0"
        check "Installed: answer file copies removed (plaintext password)" test "$(grep -c 'File Not Found' "$IC")" -ge 2
        check "Installed: sshd host key ACL = SYSTEM + Administrators only" bash -c "sed -n '/---acl---/,/---setupcomplete---/p' '$IC' | grep -q 'NT AUTHORITY.SYSTEM:(F)' && ! sed -n '/---acl---/,/---setupcomplete---/p' '$IC' | grep -qiE 'Users|Everyone|Authenticated'"
        check "Installed: SetupComplete.cmd in $ANSWER_MODE mode" grep -q "^mode: $ANSWER_MODE" "$IC"
        # Which login methods does sshd offer? (auth "none" -> the server lists them)
        ssh -v -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o PreferredAuthentications=none \
            -o PubkeyAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KH" \
            -o GlobalKnownHostsFile=/dev/null Administrator@127.0.0.1 true 2>&1 \
            | sed -n 's/.*Authentications that can continue: //p' | head -1 >"$WORKDIR/ssh-methods.txt" || true
        echo "    sshd offers: $(cat "$WORKDIR/ssh-methods.txt")"
        # A real password login with the demo password, fed by SSH_ASKPASS
        printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$DEMO_PW" >"$WORKDIR/askpass.sh"
        chmod 700 "$WORKDIR/askpass.sh"
        set +e
        SSH_ASKPASS="$WORKDIR/askpass.sh" SSH_ASKPASS_REQUIRE=force timeout 60 \
            ssh -p "$SSH_FWD_PORT" -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive \
            -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$KH" -o GlobalKnownHostsFile=/dev/null \
            Administrator@127.0.0.1 hostname </dev/null >"$WORKDIR/ssh-password.txt" 2>&1
        pwrc=$?
        set -e
        echo "    password login (demo password): exit $pwrc: $(tr -d '\r' <"$WORKDIR/ssh-password.txt" | tail -1)"
        if [ "$ANSWER_MODE" = "password" ]; then
            check "Installed: sshd offers password login (demo mode)" grep -q "password" "$WORKDIR/ssh-methods.txt"
            check "Installed: password login with the answer-file password works" \
                bash -c "[ $pwrc -eq 0 ] && grep -qix '$EXPECT_HOST' <(tr -d '\r' <'$WORKDIR/ssh-password.txt')"
        else
            check "Installed: sshd offers publickey only (no password, no keyboard-interactive)" \
                bash -c "[ \"\$(tr -d ' \r\n' <'$WORKDIR/ssh-methods.txt')\" = publickey ]"
            check "Negative: password login refused (demo password, SSH-only install)" \
                bash -c "[ $pwrc -ne 0 ] && grep -q 'Permission denied' '$WORKDIR/ssh-password.txt'"
        fi
        # Negative control: a known_hosts holding a different key must be refused.
        ssh-keygen -q -t ed25519 -N "" -f "$WORKDIR/bogus_hostkey"
        echo "[127.0.0.1]:$SSH_FWD_PORT $(cut -d' ' -f1,2 "$WORKDIR/bogus_hostkey.pub")" >"$WORKDIR/known_hosts.bogus"
        set +e
        ssh -i "$WORKDIR/harness_id" -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WORKDIR/known_hosts.bogus" \
            -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 \
            Administrator@127.0.0.1 hostname >/dev/null 2>"$WORKDIR/ssh-negative.txt"
        neg=$?
        set -e
        check "Negative control: wrong host key refused" bash -c "[ $neg -ne 0 ] && grep -qiE 'IDENTIFICATION HAS CHANGED|verification failed' '$WORKDIR/ssh-negative.txt'"
        "${SSH[@]}" 'shutdown /s /t 5' >/dev/null 2>&1 || true
    else
        echo "    SSH never came up: $(tail -1 "$WORKDIR/ssh-err.txt" 2>/dev/null)"
    fi
    wait "$QEMU2_PID" 2>/dev/null || true
    sudo touch "$WORKDIR/view/installed/STOP" 2>/dev/null || true
    wait "$VIEW2_PID" 2>/dev/null || true
    sudo sed -i 's|full serial log</a>|full serial log</a> \| <a href="installed/index.html">installed-system boot</a>|' "$WORKDIR/view/index.html" 2>/dev/null || true
    sudo chown -R "$(id -u):$(id -g)" "$WORKDIR"
fi

# ---- verdict + archive ------------------------------------------------------
TOTAL_S=$(( $(date +%s) - START ))
RUN_DIR="$ARCHIVE_DIR/$(date +%Y%m%d-%H%M%S)${RUN_TAG:+-$RUN_TAG}"
mkdir -p "$RUN_DIR"
{
    echo "test-windows-installer.sh  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "UKI $(basename "$UKI") sha256 $HASH  delivery=$DELIVERY signed=${BMO_SIGN:-no} answer=$ANSWER_MODE  GUID $GUID"
    echo "times: device VM (Stage 1+2) ${STAGE12_S}s, installed boot to SSH ${INSTALLED_S:-n/a}s, total ${TOTAL_S}s"
    printf '%s\n' "${CHECKS[@]}"
    if [ "$FAILED" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
} >"$RUN_DIR/result.txt"
cp -a "$WORKDIR/view" "$RUN_DIR/"
cp -a "$WORKDIR"/{server,to0,di}.log "$WORKDIR"/known_hosts.fdo "$WORKDIR"/OVMF_VARS.fd \
      "$WORKDIR"/harness_id "$WORKDIR"/harness_id.pub "$RUN_DIR/" 2>/dev/null || true
if [ "$KEEP_DISK" = "1" ] && [ -f "$WORKDIR/target.qcow2" ]; then
    cp --sparse=always "$WORKDIR/target.qcow2" "$RUN_DIR/"
fi
echo
echo "=== Checks ==="
sed -n '/^PASS\|^FAIL/p' "$RUN_DIR/result.txt" | sed 's/^/  /'
sed -n '/^times:/p; /^RESULT:/p' "$RUN_DIR/result.txt"
echo "ARCHIVE: $RUN_DIR"
exit "$FAILED"
