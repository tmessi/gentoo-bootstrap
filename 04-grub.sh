#!/bin/bash
source /etc/profile


# Install grub
chroot "$chroot" emerge sys-boot/grub:2

# Make the disk bootable
chroot "$chroot" /bin/bash <<DATAEOF
source /etc/profile && \
env-update && \
grep -v rootfs /proc/mounts > /etc/mtab && \
mkdir -p /boot/grub && \
grub2-mkconfig -o /boot/grub/grub.cfg && \
grub2-install --no-floppy /dev/sda
DATAEOF

