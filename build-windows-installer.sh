#!/bin/bash
#
# Copyright 2026 Dell Technologies, All Rights Reserved
# SPDX-License-Identifier: Apache-2.0
#
# Build the Windows Server 2025 FDO installer: a "Windows UKI" (winpe-uki-stub
# + wimboot + stock WinPE + the FDO Stage 2 files) and the install image.
#
# Linux only: wimlib, objcopy, cpio, Go, Rust nightly. Nothing from the ISO is
# modified; WinPE and one edition are exported with wimlib (no recompression),
# and the FDO files are injected by wimboot at boot.
#
# Outputs (firmware/):
#   $INSTALLER_UKI_NAME   the Windows UKI       (BMO, application/efi)
#   $INSTALL_WIM_NAME     the install image     (Payload, application/vnd.microsoft.wim)
#   unattend-test.xml     the answer file, CRLF (Payload, application/vnd.microsoft.unattend+xml)
#
# Env:
#   GO_ROOT          Go >= 1.25 (default: `go env GOROOT` of the go in PATH)
#   ENDPOINT_REPO    ../go-fdo-endpoint      ENDPOINT_EXE  prebuilt fdo-endpoint.exe
#   STUB_REPO        ../winpe-uki-stub       STUB_EFI      prebuilt winpe-uki-stub.efi
#   ENDPOINT_TESTS=1 also inject the endpoint's Windows unit-test binary (run in WinPE)
#   FORCE=1          re-export the WIMs even if the cached exports match
#   DEPLOY=1 DEPLOY_HOST=<host>   copy outputs + test scripts to the test host
#   TEST=1           (with DEPLOY=1) run test-windows-installer.sh there, fetch
#                    the run archive into build-windows/runs/, exit with its status

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_DIR"
# shellcheck source=config/windows-installer.env
source config/windows-installer.env

ASSET_DIR="$REPO_DIR/assets"
BUILD_DIR="$REPO_DIR/build-windows"
OUT_DIR="$REPO_DIR/firmware"
ISO_PATH="$ASSET_DIR/$WINDOWS_ISO_NAME"
WIMBOOT="$ASSET_DIR/wimboot-$WIMBOOT_VERSION"
MOUNT_DIR="$BUILD_DIR/iso"
INJECT_DIR="$BUILD_DIR/inject"
WINPE_WIM="$BUILD_DIR/winpe.wim"
INSTALL_WIM="$OUT_DIR/$INSTALL_WIM_NAME"
UKI_OUTPUT="$OUT_DIR/$INSTALLER_UKI_NAME"
UNATTEND_OUT="$OUT_DIR/$(basename "$WINDOWS_UNATTEND")"
ENDPOINT_REPO="${ENDPOINT_REPO:-$REPO_DIR/../go-fdo-endpoint}"
ENDPOINT_EXE="${ENDPOINT_EXE:-}"
STUB_REPO="${STUB_REPO:-$REPO_DIR/../winpe-uki-stub}"
STUB_EFI="${STUB_EFI:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then sudo umount "$MOUNT_DIR"; fi
}
trap cleanup EXIT

echo "=== FDO Windows Installer Build ==="
for tool in curl sha256sum blkid wimlib-imagex wimdir objcopy objdump cpio python3 sudo; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool (wimlib: apt install wimtools)"
done
if [ -z "${GO_ROOT:-}" ]; then
    GO_BIN=$(command -v go 2>/dev/null || true)
    [ -n "$GO_BIN" ] || die "Go not found. Set GO_ROOT (Go >= 1.25) or add go to PATH."
    GO_ROOT=$("$GO_BIN" env GOROOT)
fi
mkdir -p "$ASSET_DIR" "$BUILD_DIR" "$OUT_DIR" "$MOUNT_DIR"

fetch_verified() { # $1 path, $2 url, $3 sha256, [$4 size]
    if [ ! -f "$1" ]; then
        curl -fL --retry 3 -o "$1.partial" "$2"
        mv "$1.partial" "$1"
    fi
    echo "$3  $1" | sha256sum -c - >/dev/null || die "SHA-256 mismatch: $1"
    if [ -n "${4:-}" ] && [ "$(stat -c %s "$1")" -ne "$4" ]; then die "size mismatch: $1"; fi
    echo "verified $(basename "$1")"
}

echo "=== Step 1: Fetch and verify ISO + wimboot ==="
fetch_verified "$ISO_PATH" "$WINDOWS_ISO_URL" "$WINDOWS_ISO_SHA256" "$WINDOWS_ISO_SIZE"
fetch_verified "$WIMBOOT" "$WIMBOOT_URL" "$WIMBOOT_SHA256"
label=$(blkid -p -s LABEL -o value "$ISO_PATH")
[ "$label" = "$WINDOWS_ISO_LABEL" ] || die "ISO label mismatch: expected $WINDOWS_ISO_LABEL, got $label"

# Exports are cached: same ISO + same index -> same image, so skip unless FORCE=1.
export_cached() { # $1 src wim (in ISO), $2 index, $3 out, [$4 extra wimlib flag]
    local stamp="$3.stamp" want="$WINDOWS_ISO_SHA256 $(basename "$1") $2"
    if [ -z "${FORCE:-}" ] && [ -f "$3" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
        echo "cached: $(basename "$3") (FORCE=1 to re-export)"
        return 0
    fi
    rm -f "$3" "$stamp"    # wimlib export APPENDS to an existing WIM
    # shellcheck disable=SC2086
    wimlib-imagex export "$1" "$2" "$3" ${4:-} >/dev/null
    echo "$want" >"$stamp"
    echo "exported $(basename "$1") index $2 -> $(basename "$3") ($(stat -c %s "$3") bytes)"
}

require_paths() { # $1 wim, $2 index, $3 label, rest: paths that must exist
    local wim=$1 idx=$2 what=$3 list
    shift 3
    list=$(wimdir "$wim" "$idx")
    for p in "$@"; do
        grep -qixF "$p" <<<"$list" || die "$what: $p not found in $(basename "$wim") index $idx"
    done
    echo "checked $what: $# paths present"
}

echo "=== Step 2: Export WinPE and the install image (wimlib, no recompression) ==="
sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_DIR"
echo "$WINDOWS_BOOT_WIM_SHA256  $MOUNT_DIR/sources/boot.wim" | sha256sum -c - >/dev/null \
    || die "boot.wim on the ISO does not match WINDOWS_BOOT_WIM_SHA256"
export_cached "$MOUNT_DIR/sources/boot.wim" "$WINPE_INDEX" "$WINPE_WIM" --boot
name=$(wimlib-imagex info "$MOUNT_DIR/sources/install.wim" "$INSTALL_INDEX" | sed -n 's/^Name: *//p')
[ "$name" = "$INSTALL_IMAGE_NAME" ] || die "install.wim index $INSTALL_INDEX is '$name', expected '$INSTALL_IMAGE_NAME'"
export_cached "$MOUNT_DIR/sources/install.wim" "$INSTALL_INDEX" "$INSTALL_WIM"
sudo umount "$MOUNT_DIR"

# What Stage 2 and the installed system rely on (checked in Phase 0 by hand).
require_paths "$WINPE_WIM" 1 "WinPE (TPM, tools, boot files)" \
    /Windows/System32/tbs.dll /Windows/System32/drivers/tpm.sys /Windows/System32/wbem/Win32_Tpm.dll \
    /Windows/System32/diskpart.exe /Windows/System32/Dism.exe /Windows/System32/bcdboot.exe \
    /Windows/System32/wpeinit.exe /Windows/System32/wpeutil.exe \
    /Windows/Boot/EFI/bootmgfw.efi /Windows/Boot/DVD/EFI/BCD /Windows/Boot/DVD/EFI/boot.sdi
require_paths "$INSTALL_WIM" 1 "install image (OpenSSH Server)" /Windows/System32/OpenSSH/sshd.exe

echo "=== Step 3: fdo-endpoint.exe (Windows, TPM via TBS) ==="
rm -rf "$INJECT_DIR"
mkdir -p "$INJECT_DIR"
if [ -n "$ENDPOINT_EXE" ]; then
    install -m 0644 "$ENDPOINT_EXE" "$INJECT_DIR/fdo-endpoint.exe"
else
    (
        cd "$ENDPOINT_REPO"
        export GOROOT="$GO_ROOT" GOPATH="${GOPATH:-/tmp/gopath}" GOOS=windows GOARCH=amd64 CGO_ENABLED=0
        "$GO_ROOT/bin/go" build -tags=tpm -trimpath -ldflags "-s -w" -o "$INJECT_DIR/fdo-endpoint.exe" .
        if [ "${ENDPOINT_TESTS:-0}" = "1" ]; then
            "$GO_ROOT/bin/go" test -c -trimpath -ldflags "-s -w" -o "$INJECT_DIR/fdo-endpoint-test.exe" .
        fi
    )
fi
# fdo-answerfile.exe: stages the answer file in WinPE (password vs SSH-only
# mode). Its unit tests gate the build.
(
    cd windows/answerfile
    export GOROOT="$GO_ROOT" GOPATH="${GOPATH:-/tmp/gopath}" CGO_ENABLED=0
    "$GO_ROOT/bin/go" test -count=1 ./... | sed 's/^/  /'
    GOOS=windows GOARCH=amd64 "$GO_ROOT/bin/go" build -trimpath -ldflags "-s -w" -o "$INJECT_DIR/fdo-answerfile.exe" .
)
ls -l "$INJECT_DIR"/*.exe | sed 's/^/  /'

echo "=== Step 4: winpe-uki-stub ==="
if [ -z "$STUB_EFI" ]; then
    make -s -C "$STUB_REPO" release >/dev/null
    STUB_EFI="$STUB_REPO/target/x86_64-unknown-uefi/release/winpe-uki-stub.efi"
fi
[ -f "$STUB_EFI" ] || die "stub not found: $STUB_EFI"
MKUKI="$STUB_REPO/tools/mkuki.sh"
[ -x "$MKUKI" ] || die "mkuki.sh not found: $MKUKI"
echo "stub: $STUB_EFI ($(stat -c %s "$STUB_EFI") bytes)"

echo "=== Step 5: Stage the injected files (CRLF for cmd.exe) ==="
for f in winpeshl.ini fdo-stage2.cmd fdo-endpoint.yaml SetupComplete.cmd; do
    sed 's/\r*$/\r/' "windows/stage2/$f" >"$INJECT_DIR/$f"
done
ln -sf "$WINPE_WIM" "$INJECT_DIR/winpe.wim"    # mkuki.sh serves it as boot.wim
ls -l "$INJECT_DIR" | sed 's/^/  /'

echo "=== Step 6: Build the Windows UKI ==="
"$MKUKI" -s "$STUB_EFI" -w "$WIMBOOT" -o "$UKI_OUTPUT" "$INJECT_DIR"/* | sed 's/^/  /'
uki_size=$(stat -c %s "$UKI_OUTPUT")
headroom=$(( (FDO_UEFI_URL_CAP - uki_size) / 1048576 ))
if [ "$uki_size" -gt "$FDO_UEFI_URL_CAP" ]; then
    echo "WARNING: UKI is $uki_size bytes, over fdo-uefi-rs's URL-delivery cap ($FDO_UEFI_URL_CAP)."
    echo "         URL / meta-URL delivery will fail; use inline BMO (test: DELIVERY=inline)."
else
    echo "UKI: $uki_size bytes; ${headroom} MiB under the fdo-uefi-rs URL-delivery cap"
fi

echo "=== Step 7: Answer file ==="
python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$WINDOWS_UNATTEND" \
    || die "$WINDOWS_UNATTEND is not well-formed XML"
computer=$(sed -n 's:.*<ComputerName>\(.*\)</ComputerName>.*:\1:p' "$WINDOWS_UNATTEND" | head -1)
[ -n "$computer" ] || die "$WINDOWS_UNATTEND has no <ComputerName>"
sed 's/\r*$/\r/' "$WINDOWS_UNATTEND" >"$UNATTEND_OUT"
echo "unattend: $(basename "$UNATTEND_OUT") (ComputerName=$computer)"

{
    echo "# build $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# fdo-endpoint $(git -C "$ENDPOINT_REPO" describe --always --dirty 2>/dev/null || echo "(no git revision)")"
    echo "# winpe-uki-stub $(git -C "$STUB_REPO" describe --always --dirty 2>/dev/null || echo "(no git revision)")"
    echo "# fdo-uki-build $(git -C "$REPO_DIR" describe --always --dirty 2>/dev/null || echo unknown)"
    echo "$WINDOWS_ISO_SHA256  $ISO_PATH"    # verified in step 1
    sha256sum "$WIMBOOT" "$WINPE_WIM" "$INJECT_DIR"/*.exe "$UKI_OUTPUT" "$INSTALL_WIM" "$UNATTEND_OUT"
} | tee "$BUILD_DIR/SHA256SUMS"
ls -lh "$UKI_OUTPUT" "$INSTALL_WIM" "$UNATTEND_OUT"

if [ "${DEPLOY:-0}" = "1" ]; then
    [ -n "${DEPLOY_HOST:-}" ] || die "DEPLOY=1 needs DEPLOY_HOST"
    echo "=== Deploying to $DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR (payloads) and ~/$DEPLOY_SCRIPT_DIR (scripts) ==="
    ssh "$DEPLOY_HOST" "mkdir -p '$DEPLOY_FIRMWARE_DIR' '$DEPLOY_SCRIPT_DIR/windows' '$DEPLOY_SCRIPT_DIR/config'"
    # --checksum: the cached 3 GB image is only sent when it actually changed
    rsync -a --checksum "$UKI_OUTPUT" "$INSTALL_WIM" "$UNATTEND_OUT" "$DEPLOY_HOST:$DEPLOY_FIRMWARE_DIR/"
    rsync -a test-windows-installer.sh boot-installed-windows.sh "$DEPLOY_HOST:$DEPLOY_SCRIPT_DIR/"
    rsync -a windows/view.py "$DEPLOY_HOST:$DEPLOY_SCRIPT_DIR/windows/"
    rsync -a config/windows-installer.env "$DEPLOY_HOST:$DEPLOY_SCRIPT_DIR/config/"
    echo "deployed. On $DEPLOY_HOST:  cd ~/$DEPLOY_SCRIPT_DIR && ./test-windows-installer.sh"

    if [ "${TEST:-0}" = "1" ]; then
        echo "=== Running test-windows-installer.sh on $DEPLOY_HOST ==="
        set +e
        ssh "$DEPLOY_HOST" "cd '$DEPLOY_SCRIPT_DIR' && FDO_FIRMWARE_DIR='$DEPLOY_FIRMWARE_DIR' ./test-windows-installer.sh" \
            2>&1 | tee "$BUILD_DIR/last-test.log"
        status=${PIPESTATUS[0]}
        set -e
        archive=$(sed -n 's/^ARCHIVE: //p' "$BUILD_DIR/last-test.log" | tail -1)
        if [ -n "$archive" ]; then
            mkdir -p "$BUILD_DIR/runs"
            rsync -a --exclude target.qcow2 "$DEPLOY_HOST:$archive" "$BUILD_DIR/runs/"
            echo "fetched: $BUILD_DIR/runs/$(basename "$archive")  (open view/index.html)"
        fi
        exit "$status"
    fi
fi
