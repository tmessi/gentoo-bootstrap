#!/bin/bash
source /etc/profile

# Build the kernel
chroot "$chroot" /bin/bash <<DATAEOF
USE="symlink -cryptsetup" emerge =sys-kernel/gentoo-sources-$kernel_version sys-kernel/genkernel gentoolkit

cd /usr/src/linux
# use a default configuration as a starting point
make defconfig

# add settings for hardware
cat <<EOF >>/usr/src/linux/.config
EOF
# build and install kernel, using the config created above
genkernel --install --symlink --oldconfig --bootloader=grub all
DATAEOF

