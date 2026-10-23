#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# Boot an installed Windows disk from a start17 run archive and check it.
#
# Usage: boot-installed-windows.sh <run-dir> [--reboot-test] [--keep]
#   <run-dir>      archive dir with target.qcow2, OVMF_VARS.fd, known_hosts.fdo,
#                  harness_id (start17 INSTALLED_BOOT=1 + the copy step)
#   --reboot-test  after the first check, "shutdown /r" inside Windows and check
#                  again after the reboot (sshd auto-start, same host keys)
#   --keep         leave the VM running; log in with the printed ssh command
#
# Every SSH login uses StrictHostKeyChecking=yes against known_hosts.fdo, i.e.
# only the host keys the owner received via fdo.credentials.
# Env: SSH_FWD_PORT (2222), MEM (4096), VNC_DISPLAY (8), TIMEOUT (900)

set -euo pipefail

RUN=$(readlink -f "${1:?usage: $0 <run-dir> [--reboot-test] [--keep]}")
shift
REBOOT_TEST="" KEEP=""
for a in "$@"; do
    case $a in
        --reboot-test) REBOOT_TEST=1 ;;
        --keep) KEEP=1 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done
SSH_FWD_PORT=${SSH_FWD_PORT:-2222}
MEM=${MEM:-4096}
VNC_DISPLAY=${VNC_DISPLAY:-8}
TIMEOUT=${TIMEOUT:-900}

for f in target.qcow2 OVMF_VARS.fd known_hosts.fdo harness_id; do
    [ -f "$RUN/$f" ] || { echo "missing $RUN/$f" >&2; exit 1; }
done
chmod 600 "$RUN/harness_id"
# known_hosts.fdo was written for port 2222; rewrite for the port in use.
sed "s/^\[127.0.0.1\]:[0-9]*/[127.0.0.1]:$SSH_FWD_PORT/" "$RUN/known_hosts.fdo" >"$RUN/known_hosts.port"

SSH=(ssh -i "$RUN/harness_id" -p "$SSH_FWD_PORT" -o BatchMode=yes -o ConnectTimeout=10
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$RUN/known_hosts.port"
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR Administrator@127.0.0.1)

wait_ssh() { # $1 = label
    local t0=$SECONDS
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        if "${SSH[@]}" hostname >/dev/null 2>&1; then
            echo "[$1] SSH up after $((SECONDS - t0))s (host key verified against fdo.credentials keys)"
            return 0
        fi
        [ $((SECONDS - t0)) -gt "$TIMEOUT" ] && break
        sleep 5
    done
    echo "[$1] SSH did not come up" >&2
    return 1
}

check() { # $1 = label
    echo "[$1] checks:"
    "${SSH[@]}" 'hostname & systeminfo | find "System Boot Time" & sc query sshd | find "STATE" & sc qc sshd | find "START_TYPE" & type C:\fdo-installed.txt' \
        2>&1 | tr -d '\r' | sed '/^$/d; s/^/    /'
}

echo "=== Booting $RUN/target.qcow2 (alone), ssh -> 127.0.0.1:$SSH_FWD_PORT, VNC 127.0.0.1:$((5900 + VNC_DISPLAY)) ==="
sudo qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -smp 4 -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$RUN/OVMF_VARS.fd" \
    -device ahci,id=ahci \
    -drive file="$RUN/target.qcow2",format=qcow2,if=none,id=d0 -device ide-hd,drive=d0,bus=ahci.0 \
    -netdev user,id=n1,hostfwd=tcp:127.0.0.1:"$SSH_FWD_PORT"-:22 -device e1000e,romfile=,netdev=n1 \
    -vga std -display none -vnc 127.0.0.1:"$VNC_DISPLAY" \
    -serial file:"$RUN/serial-boot.log" >"$RUN/qemu-boot.log" 2>&1 &
QEMU_PID=$!
trap '[ -z "$KEEP" ] && sudo kill "$QEMU_PID" 2>/dev/null || true' EXIT

wait_ssh boot1
check boot1

if [ -n "$REBOOT_TEST" ]; then
    echo "[reboot] shutdown /r /t 0 inside Windows"
    "${SSH[@]}" 'shutdown /r /t 0' >/dev/null 2>&1 || true
    # wait until sshd goes away, then comes back
    for _ in $(seq 60); do "${SSH[@]}" hostname >/dev/null 2>&1 || break; sleep 2; done
    wait_ssh boot2
    check boot2
fi

if [ -n "$KEEP" ]; then
    echo "=== VM left running (pid $QEMU_PID). Log in from this host with:"
    echo "  ${SSH[*]}" | sed 's/-o BatchMode=yes //'
    echo "  stop: ssh ... 'shutdown /s /t 0'   or   sudo kill $QEMU_PID"
    trap - EXIT
else
    "${SSH[@]}" 'shutdown /s /t 0' >/dev/null 2>&1 || true
    wait "$QEMU_PID" 2>/dev/null || true
    echo "=== VM shut down"
fi
