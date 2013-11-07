#!/bin/bash
source /etc/profile

# Settings
build_arch="amd64"
build_proc="amd64"
stage3current=`curl -s http://distfiles.gentoo.org/releases/${build_arch}/autobuilds/latest-stage3-${build_proc}.txt|grep -v "^#"`
stage3url="http://distfiles.gentoo.org/releases/${build_arch}/autobuilds/${stage3current}"
stage3file=${stage3current##*/}

# chost
chost="x86_64-pc-linux-gnu"

# kernel version to use
kernel_version="3.10.17"

# timezone (as a subdirectory of /usr/share/zoneinfo)
timezone="UTC"

# locale
locale="en_US.utf8"

# chroot directory for the installation
chroot=/mnt/gentoo

# number of cpus in the host system (to speed up make and for kernel config)
nr_cpus=$(</proc/cpuinfo grep processor|wc -l)


function base() {
    # Partition the disk (http://www.rodsbooks.com/gdisk/sgdisk.html)
    sgdisk -n 1:0:+512M -t 1:8300 -c 1:"linux-boot" \
           -n 2:0:0     -t 2:8300 -c 2:"linux-root" \
           -p /dev/sda

    sleep 1

    # Set up lvms
    pvcreate -y /dev/sda2
    vgcreate vgsys /dev/sda2
    lvcreate -l2G  -n lvroot vgsys
    lvcreate -l5G  -n lvopt  vgsys
    lvcreate -l20G -n lvusr  vgsys
    lvcreate -l2G  -n lvtmp  vgsys
    lvcreate -l2G  -n lvvar  vgsys
    lvcreate -l1G  -n lvsrv  vgsys
    lvcreate -l50G -n lvhome vgsys
    lvcreate -l6G  -n lvswap vgsys

    # Setup swap
    mkswap -L swap /dev/mapper/vgsys-lvswap
    swapon -L swap

    # Make file systems
    mkfs.ext2 -L/boot /dev/sda1
    mkfs.xfs  -L/     /dev/mapper/vgsys-lvroot
    mkfs.xfs  -L/opt  /dev/mapper/vgsys-lvopt
    mkfs.xfs  -L/usr  /dev/mapper/vgsys-lvusr
    mkfs.xfs  -L/tmp  /dev/mapper/vgsys-lvtmp
    mkfs.xfs  -L/var  /dev/mapper/vgsys-lvvar
    mkfs.xfs  -L/srv  /dev/mapper/vgsys-lvsrv
    mkfs.xfs  -L/home /dev/mapper/vgsys-lvhome

    # Mount partitions
    mount  -L/    "$chroot"
    mkdir -p "$chroot"/{boot,opt,usr,tmp,var,srv,home}
    mount -L/boot "$chroot/boot"
    mount -L/opt  "$chroot/opt"
    mount -L/usr  "$chroot/usr"
    mount -L/tmp  "$chroot/tmp"
    mount -L/var  "$chroot/var"
    mount -L/srv  "$chroot/srv"
    mount -L/home "$chroot/home"

    # Download and unpack stage3
    pushd "$chroot"
    wget -nv --tries=5 "$stage3url"
    tar xpf "$stage3file" && rm "$stage3file"
    popd

    # Copy nameserver information
    cp -L /etc/resolv.conf "$chroot/etc/"

    # Mount additional mount points
    mount -t proc none "$chroot/proc"
    mount --rbind /sys "$chroot/sys"
    mount --rbind /dev "$chroot/dev"

    chroot "$chroot" env-update

    # disable systemd device naming
    chroot "$chroot" /bin/bash <<DATAEOF
touch /etc/udev/rules.d/80-net-name-slot.rules
DATAEOF

    # Set eth0 and ssh to start on boot
    chroot "$chroot" /bin/bash <<DATAEOF
pushd /etc/conf.d
echo 'config_eth0=( "dhcp" )' >> net
ln -s net.lo /etc/init.d/net.eth0
rc-update add net.eth0 default
rc-update add sshd default
popd
DATAEOF

    # Set fstab
    cat <<DATAEOF > "$chroot/etc/fstab"
# /etc/fstab: static file system information.
#
# noatime turns off atimes for increased performance (atimes normally aren't
# needed); notail increases performance of ReiserFS (at the expense of storage
# efficiency).  It's safe to drop the noatime options if you want and to
# switch between notail / tail freely.
#
# The root filesystem should have a pass number of either 0 or 1.
# All other filesystems should have a pass number of 0 or greater than 1.
#
# See the manpage fstab(5) for more information.
#

# <fs>            <mountpoint>    <type>        <opts>            <dump/pass>
LABEL=/boot       /boot            ext2         noatime            1 2
LABEL=/           /                xfs          defaults           0 1
LABEL=/opt        /opt             xfs          defaults           0 0
LABEL=/usr        /usr             xfs          defaults           0 0
LABEL=/tmp        /tmp             xfs          defaults           0 0
LABEL=/var        /var             xfs          defaults           0 0
LABEL=/srv        /srv             xfs          defaults           0 0
LABEL=/home       /home            xfs          defaults           0 0
LABEL=swap        none             swap         sw                 0 0

none              /var/tmp/portage tmpfs        size=4096M,uid=250,gid=250,mode=755,noatime 0 0

DATAEOF

    # Set makeconf
    cat <<DATAEOF > "$chroot/etc/portage/make.conf"
# These settings were set by the catalyst build script that automatically
# built this stage.
# Please consult /usr/share/portage/config/make.conf.example for a more
# detailed example.
CFLAGS="-march=native -O2 -pipe"
CXXFLAGS="\${CFLAGS}"
# WARNING: Changing your CHOST is not something that should be done lightly.
# Please consult http://www.gentoo.org/doc/en/change-chost.xml before changing.
CHOST="$chost"
MAKEOPTS="-j$((1 + $nr_cpus)) -l${nr_cpus}.5"

EMERGE_DEFAULT_OPTS="--jobs --load-average=${nr_cpus}.5"

INPUT_DEVICES="evdev"
VIDEO_CARDS="nouveau nvidia"
LINGUAS="en"

FEATURES="parallel-fetch parallel-install candy"

# Set PORTDIR for backward compatibility with various tools:
#   gentoo-bashcomp - bug #478444
#   euse - bug #474574
#   euses and ufed - bug #478318
PORTDIR="/usr/portage"
DATAEOF

    # set localtime
    chroot "$chroot" ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime

    # set locale
    chroot "$chroot" /bin/bash <<DATAEOF
locale-gen
eselect locale set $locale
env-update && source /etc/profile
DATAEOF

    # Update portage tree to most current state
    chroot "$chroot" emerge-webrsync

    # Ensure latest portage is installed and clear news
    chroot "$chroot" /bin/bash <<DATAEOF
emerge --oneshot sys-apps/portage
DATAEOF
}


function kernel() {
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
}


function cron() {
    # install cron
    chroot "$chroot" /bin/bash <<DATAEOF
emerge sys-process/fcron
rc-update add fcron default
DATAEOF
}


function syslog() {
    # install system logger
    chroot "$chroot" /bin/bash <<DATAEOF
emerge app-admin/rsyslog
rc-update add rsyslog default
DATAEOF
}


function grub() {
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
}


function salt() {
    # Install salt via bootstrap
    chroot "$chroot" /bin/bash <<DATAEOF
wget -O - http://bootstrap.saltstack.org | sh
DATAEOF
}


function cleanup() {
    # cleanup
    chroot "$chroot" /bin/bash <<DATAEOF
eclean -d distfiles
rm -rf /tmp/*
rm -rf /var/log/*
rm -rf /var/tmp/*
DATAEOF
}


base
kernel
cron
syslog
grub
salt
cleanup
