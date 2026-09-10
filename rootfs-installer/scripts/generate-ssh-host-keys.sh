#!/bin/sh

# Generate SSH host keys and place them in a location accessible to go-fdo-endpoint
# This script runs during the installer UKI boot to generate host keys that can be
# returned to the onboarding service via FDO ServiceInfo.
#
# The installer initramfs (busybox) does not include an ssh-keygen binary, so key
# generation is done by fdo-endpoint itself (-gen-ssh-keys), which uses Go's stdlib
# crypto packages + golang.org/x/crypto/ssh to write standard OpenSSH-format keys.

KEY_DIR=/run/fdo/ssh-host-keys

echo "Generating SSH host keys for FDO onboarding..."

/usr/local/bin/fdo-endpoint -gen-ssh-keys "$KEY_DIR"
status=$?
if [ "$status" -ne 0 ]; then
    echo "FDO installer error: SSH host key generation failed (exit $status)" >&2
    exit 1
fi

echo "SSH host keys generated in $KEY_DIR"
echo "Public keys:"
cat "$KEY_DIR"/*.pub
