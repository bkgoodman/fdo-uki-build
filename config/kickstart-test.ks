# FDO-delivered test kickstart for the Fedora 44 Server DVD installer UKI.
# Delivered per-device via fdo.payload as application/vnd.fedora.kickstart.
# Mirrors config/autoinstall-test.yaml (Ubuntu).

text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --hostname=fdo-installed --activate
firstboot --disable
selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd

rootpw --lock
# Password: "fdo" (hashed)
user --name=fdo --gecos="FDO Device User" --groups=wheel --iscrypted --password="$6$FDO.SALT$rD0sGDQl0UONZCEGST2cf5KpVgjN8Cb6ETtvFLDHA.fCWqM4u6Jj6l6XG5XUlave7lGunXO3RMPb.In/oKbqR/"
sshkey --username=fdo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECb1b7JjbIThvin1gum8LH5ctWoCCKGuUsyAQoa3ko3 fdo-onboarding"

# Disk selection is generated in %pre: never touch /dev/pmem0 (the RAM-backed
# installer ISO) or the small disk carrying the FDO UEFI client.
%include /tmp/fdo-disk.ks

poweroff

%pre --log=/tmp/fdo-pre.log
target=$(lsblk -dnbo NAME,SIZE,TYPE,RM | awk '$3 == "disk" && $4 == 0 && $1 !~ /^(pmem|zram|loop|sr|fd)/ { print $2, $1 }' | sort -n | tail -1 | awk '{ print $2 }')
if [ -z "$target" ]; then
    echo "FDO: no suitable target disk found" >&2
    exit 1
fi
echo "FDO: installing to /dev/$target"
cat > /tmp/fdo-disk.ks <<EOF
ignoredisk --only-use=$target
zerombr
clearpart --all --initlabel --drives=$target
autopart --type=lvm
bootloader --boot-drive=$target
EOF
%end

%packages
@^server-product-environment
openssh-server
%end

# Copy the SSH host keys generated during FDO onboarding (and already
# registered with the owner via fdo.credentials) onto the target.
%post --nochroot --erroronfail --log=/tmp/fdo-post-nochroot.log
if [ -d /run/fdo/ssh-host-keys ]; then
    cp -a /run/fdo/ssh-host-keys/ssh_host_* "$ANA_INSTALL_PATH/etc/ssh/"
    echo "FDO: copied SSH host keys to $ANA_INSTALL_PATH/etc/ssh"
else
    echo "FDO: /run/fdo/ssh-host-keys not found" >&2
    exit 1
fi
cp /tmp/fdo-pre.log /tmp/fdo-post-nochroot.log "$ANA_INSTALL_PATH/root/" 2>/dev/null || true
%end

%post --erroronfail --log=/root/fdo-post.log
# Ownership, modes and SELinux labels for the copied host keys. sshd-keygen@
# only generates missing keys, so these survive first boot.
chown root:root /etc/ssh/ssh_host_*
chmod 0600 /etc/ssh/ssh_host_*_key
chmod 0644 /etc/ssh/ssh_host_*_key.pub
restorecon -Rv /etc/ssh

# fdo user: passwordless sudo
echo "fdo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-fdo-user
chmod 0440 /etc/sudoers.d/90-fdo-user

# Key-only SSH
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/10-fdo.conf
chmod 0600 /etc/ssh/sshd_config.d/10-fdo.conf

# Mark installation complete
mkdir -p /var/lib
echo FDO_AUTOINSTALL_COMPLETE > /var/lib/fdo-autoinstall-complete
%end
