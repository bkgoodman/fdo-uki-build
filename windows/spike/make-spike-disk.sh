#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 spike: build a GPT disk image with one FAT32 ESP holding
#   \EFI\BOOT\BOOTX64.EFI  wimboot (OVMF boots it as the removable path)
#   \boot.wim              stock Windows Setup boot.wim, unmodified
#   \winpeshl.ini, \fdo-spike.cmd, \tbs-probe.exe   injected by wimboot
#                                                   into X:\Windows\System32
# and a second, small FAT partition of type "Microsoft basic data" with
#   \FDORES.TAG            marker: fdo-spike.cmd writes spike.log here
# (Windows does not assign drive letters to ESP-typed partitions.)
# wimboot reads every file in the root of the volume it was loaded from.
# No root needed (sfdisk on a file + mtools).
#
# Usage: make-spike-disk.sh <boot.wim> <wimboot> <tbs-probe.exe> <out.img>
#        make-spike-disk.sh --uki <windows-uki.efi> <out.img>
# --uki: the ESP holds ONLY \EFI\BOOT\BOOTX64.EFI = a winpe-uki-stub image
# (wimboot, boot.wim and the injected files all live inside it).

set -euo pipefail

UKI=
if [ "${1:-}" = "--uki" ] && [ $# -eq 3 ]; then
    UKI=$2
    OUT=$3
    payload=$UKI
elif [ $# -eq 4 ]; then
    BOOT_WIM=$1
    WIMBOOT=$2
    PROBE=$3
    OUT=$4
    payload=$BOOT_WIM
else
    echo "usage: $0 <boot.wim> <wimboot> <tbs-probe.exe> <out.img> | --uki <uki.efi> <out.img>" >&2
    exit 1
fi
SPIKE_DIR=$(cd "$(dirname "$0")" && pwd)

for f in ${UKI:-"$BOOT_WIM" "$WIMBOOT" "$PROBE"}; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

wim_mib=$(( $(stat -c %s "$payload") / 1024 / 1024 ))
esp_mib=$(( wim_mib + 128 ))
res_mib=64
rm -f "$OUT"
truncate -s "$(( 1 + esp_mib + res_mib + 1 ))M" "$OUT"
printf 'label: gpt\nstart=1MiB, size=%sMiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"\nstart=%sMiB, size=%sMiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="FDORES"\n' \
    "$esp_mib" "$(( 1 + esp_mib ))" "$res_mib" | sfdisk -q "$OUT"

IMG="$OUT@@1M"
RES="$OUT@@$(( 1 + esp_mib ))M"
mformat -i "$RES" -F -v FDORES ::
printf 'fdo spike results volume\r\n' | mcopy -i "$RES" - ::/FDORES.TAG
echo "results partition offset: $(( 1 + esp_mib ))M"
mformat -i "$IMG" -F -v FDOSPIKE ::
mmd -i "$IMG" ::/EFI ::/EFI/BOOT
if [ -n "$UKI" ]; then
    mcopy -i "$IMG" "$UKI" ::/EFI/BOOT/BOOTX64.EFI
    mdir -i "$IMG" -/ ::
    sha256sum "$UKI" "$OUT"
    exit 0
fi
mcopy -i "$IMG" "$WIMBOOT" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG" "$BOOT_WIM" ::/boot.wim
for f in winpeshl.ini fdo-spike.cmd; do
    sed 's/\r*$/\r/' "$SPIKE_DIR/$f" > "/tmp/$f.crlf"
    mcopy -i "$IMG" "/tmp/$f.crlf" "::/$f"
    rm -f "/tmp/$f.crlf"
done
mcopy -i "$IMG" "$PROBE" ::/tbs-probe.exe

mdir -i "$IMG" -/ ::
sha256sum "$BOOT_WIM" "$WIMBOOT" "$PROBE" "$OUT"
