#!/usr/bin/bash
#
# FDO onboarding inside the openSUSE Leap (Agama live, dracut/systemd) initramfs.
#
# Runs as fdo-receive.service: after NetworkManager-in-initrd is online and
# before dracut-initqueue.service, i.e. before dmsquash-live looks for the live
# medium (root=live:LABEL=...) on /dev/pmem0.
#
# Note: the installer initrd has no head/wc/touch; avoid them here.

ISO_LABEL="@OPENSUSE_ISO_LABEL@"
PROFILE=/run/fdo/agama/profile.json
EXTRA_MODULES=/usr/lib/fdo/modules

diag()
{
    echo "FDO-DIAG: $*" >&2
}

fail()
{
    echo "FDO installer error: $*" >&2
    exit 1
}

diag "fdo-receive starting"

# The stock kiwi initrd ships libnvdimm/nd_e820 but not nd_pmem (or its
# dependency nd_btt); the build appends both from the ISO's matching
# kernel-default package. Prefer modprobe in case a future initrd has them.
diag "loading nvdimm/pmem/isofs modules"
for m in libnvdimm nd_e820 isofs; do
    modprobe "$m" 2>/dev/null || true
done
for m in nd_btt nd_pmem; do
    modprobe "$m" 2>/dev/null || insmod "$EXTRA_MODULES/$m.ko" 2>/dev/null || true
done
diag "udevadm settle (30s timeout)"
udevadm settle --timeout=30 2>/dev/null || true

diag "NICs:"
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = lo ] && continue
    diag "  $name carrier=$(cat "$iface/carrier" 2>/dev/null || echo "?")"
done
diag "IP addresses:"
ip -4 -o addr show scope global >&2 2>/dev/null || true

diag "waiting for /dev/tpmrm0 and /dev/pmem0"
tries=0
while { [ ! -e /dev/tpmrm0 ] || [ ! -e /dev/pmem0 ]; } && [ "$tries" -lt 30 ]; do
    sleep 1
    tries=$((tries + 1))
done
diag "wait done (tries=$tries)"
[ -e /dev/tpmrm0 ] || fail "/dev/tpmrm0 is unavailable"
[ -e /dev/pmem0 ] || fail "/dev/pmem0 is unavailable (is nd_pmem loaded?)"

pmem_bytes=$(( $(cat /sys/block/pmem0/size) * 512 ))
diag "/dev/pmem0 size: $pmem_bytes bytes"

mkdir -p /run/fdo /run/fdo/agama /tmp/fdo_payloads

# SSH host keys are generated here so fdo-endpoint can send the public halves to
# the owner via the fdo.credentials FSIM; the Agama profile copies them to the target.
if [ -x /usr/libexec/fdo/generate-ssh-host-keys.sh ]; then
    /usr/libexec/fdo/generate-ssh-host-keys.sh || fail "SSH host key generation failed"
fi

# Device IP (convenience, non-security-relevant) conveyed via fdo.credentials.
ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, a, "/"); print a[1]}' > /run/fdo/device-ip.txt
echo "FDO installer: device IP address: $(cat /run/fdo/device-ip.txt)"

# Server address comes from the RvInfo in the TPM credential written during DI.
echo "FDO installer: starting TO2 (server address from TPM credential)"
/usr/local/bin/fdo-endpoint -config /etc/fdo/config.yaml
status=$?
[ "$status" -eq 0 ] || fail "endpoint exited with status $status"

[ -s "$PROFILE" ] || fail "Agama profile was not received"

media_type=$(blkid -p -s TYPE -o value /dev/pmem0 2>/dev/null)
media_label=$(blkid -p -s LABEL -o value /dev/pmem0 2>/dev/null)
diag "pmem0 TYPE=$media_type LABEL=$media_label"
[ "$media_type" = iso9660 ] || fail "received payload is not ISO9660 media"
[ "$media_label" = "$ISO_LABEL" ] || fail "received ISO label '$media_label' != expected '$ISO_LABEL'"

# No hand-off needed: the cmdline carries inst.auto=file://$PROFILE, which the
# Agama dracut hook recorded in /run/agama/cmdline.d/agama.conf, and
# agama-autoinstall reads the file in the live system (/run survives switch_root).

# Make sure /dev/disk/by-label/<ISO_LABEL> exists before the initqueue runs.
udevadm trigger --action=change /dev/pmem0 2>/dev/null || true
udevadm settle --timeout=30 2>/dev/null || true
[ -e "/dev/disk/by-label/$ISO_LABEL" ] || fail "/dev/disk/by-label/$ISO_LABEL did not appear"
diag "by-label link: $(readlink -f "/dev/disk/by-label/$ISO_LABEL")"

: > /run/fdo/installer-media.complete
echo "FDO installer: media and Agama profile ready; handing off to the live root"
exit 0
