#!/usr/bin/bash
#
# FDO onboarding inside the Fedora (dracut/systemd) installer initramfs.
#
# Runs as fdo-receive.service: after NetworkManager-in-initrd is online and
# before dracut-initqueue.service, i.e. before Anaconda's diskroot logic looks
# for the installer media on /dev/pmem0.
#
# Note: the Fedora installer initrd has no head/wc/touch; avoid them here.

ISO_LABEL="@FEDORA_ISO_LABEL@"
KS_RECEIVED=/run/fdo/kickstart/ks.cfg

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

diag "loading nvdimm/pmem/isofs modules"
for m in libnvdimm nd_e820 nd_pmem isofs; do
    modprobe "$m" 2>/dev/null || true
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
[ -e /dev/pmem0 ] || fail "/dev/pmem0 is unavailable"

pmem_bytes=$(( $(cat /sys/block/pmem0/size) * 512 ))
diag "/dev/pmem0 size: $pmem_bytes bytes"

mkdir -p /run/fdo /run/install /tmp/fdo_payloads

# SSH host keys are generated here so fdo-endpoint can send the public halves to
# the owner via the fdo.credentials FSIM; the kickstart copies them to the target.
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

[ -s "$KS_RECEIVED" ] || fail "kickstart was not received"

media_type=$(blkid -p -s TYPE -o value /dev/pmem0 2>/dev/null)
media_label=$(blkid -p -s LABEL -o value /dev/pmem0 2>/dev/null)
diag "pmem0 TYPE=$media_type LABEL=$media_label"
[ "$media_type" = iso9660 ] || fail "received payload is not ISO9660 media"
[ "$media_label" = "$ISO_LABEL" ] || fail "received ISO label '$media_label' != expected '$ISO_LABEL'"

# Hand the kickstart to Anaconda exactly as its own fetch-kickstart-disk does:
# /tmp/ks.cfg -> parse_kickstart (writes /etc/cmdline.d/80-kickstart.conf and
# copies the processed file to /run/install/ks.cfg, which stage2 picks up) ->
# run_kickstart (re-generates repo udev rules, replays block events, and marks
# /tmp/ks.cfg.done). inst.ks= is deliberately NOT on the cmdline: its file:
# form is resolved at cmdline-hook time, long before this runs.
cp "$KS_RECEIVED" /tmp/ks.cfg
(
    [ -f /dracut-state.sh ] && . /dracut-state.sh 2>/dev/null
    . /lib/dracut-lib.sh
    . /lib/anaconda-lib.sh
    parse_kickstart /tmp/ks.cfg
    run_kickstart
) || diag "anaconda kickstart hand-off returned non-zero"
if [ ! -s /run/install/ks.cfg ]; then
    diag "processed kickstart missing; installing raw copy at /run/install/ks.cfg"
    cp "$KS_RECEIVED" /run/install/ks.cfg
fi
[ -e /tmp/ks.cfg.done ] || : > /tmp/ks.cfg.done

# Make sure /dev/disk/by-label/<ISO_LABEL> exists before the initqueue runs.
udevadm trigger --action=change /dev/pmem0 2>/dev/null || true
udevadm settle --timeout=30 2>/dev/null || true
[ -e "/dev/disk/by-label/$ISO_LABEL" ] || fail "/dev/disk/by-label/$ISO_LABEL did not appear"

: > /run/fdo/installer-media.complete
echo "FDO installer: media and kickstart ready; handing off to Anaconda"
exit 0
