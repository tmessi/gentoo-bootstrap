#!/bin/bash
source /etc/profile

name=${0##*/}


# Settings
wipe_old=0
hostname="felarof"
iwl7260=0
crypt=0
crypt_key=""
crypt_args=""
crypt_boot=0
crypt_boot_args=""
crypt_boot_key=""
build_arch="amd64"
build_proc="amd64"
stage3current=`curl -s -L https://bouncer.gentoo.org/fetch/root/all/releases/${build_arch}/autobuilds/latest-stage3-${build_proc}-openrc.txt | grep -v "^#" | cut -f 1 -d ' '`
stage3url="https://bouncer.gentoo.org/fetch/root/all/releases/${build_arch}/autobuilds/${stage3current}"
stage3file=${stage3current##*/}

# chost
chost="x86_64-pc-linux-gnu"

# timezone (as a subdirectory of /usr/share/zoneinfo)
timezone="US/Eastern"

# locale
locale="en_US.utf8"

# chroot directory for the installation
chroot=/mnt/gentoo

# number of cpus in the host system (to speed up make and for kernel config)
nr_cpus=$(</proc/cpuinfo grep processor|wc -l)


function print_help() {
    echo "usage: $name [options]

optional args:

    -w|--wipe         erase old partitions
    -n|--hostname     set hostname
       --iwl7260      include iwl7260 ucode
    -c|--crypt        encrypt lvm partition
    --crypt-key       path to encrypt key
    --crypt-args      args to pass to cryptsetup
    --crypt-boot      encrypt boot partition
    --crypt-boot-args args to pass to cryptsetup for boot
    --crypt-boot-key  path to encrypt key
    -h|--help         print this help."
}

function _wipe_old() {
    old_vgs=$(vgs | awk '!/VG/ {print $1}')
    for old_vg in $old_vgs; do
        echo "Removing volume group $old_vg"
        vgremove -f $old_vg
    done
    old_pvs=$(pvs | awk '!/PV/ {print $1}')
    for old_pv in $old_pvs; do
        echo "Removing physical volume $old_pv"
        pvremove -f $old_pv
    done
    echo "Wiping partition table"
    # destroys the existing MBR and GTP data
    sgdisk -Z /dev/nvme0n1
    partprobe
}

function base() {
    if [[ $wipe_old -eq 1 ]]; then
        _wipe_old
    fi

    # Partition the disk (http://www.rodsbooks.com/gdisk/sgdisk.html)
    sgdisk -n 1:0:+2M   -t 1:ef02 -c 1:"linux-bios" \
           -n 2:0:+512M -t 2:ef00 -c 2:"efi" \
           -n 3:0:+1G   -t 3:8309 -c 3:"linux-boot" \
           -n 4:0:0     -t 4:8e09 -c 3:"linux-root" \
           -p /dev/nvme0n1

    sleep 1

    rootpv=/dev/nvme0n1p4

    if [[ $crypt -eq 1 ]]; then
        open_args=""
        cryptsetup $crypt_args luksFormat /dev/nvme0n1p4 $crypt_key
        if [[ $crypt_key ]]; then
            open_args="--key-file $crypt_key"
        fi
        cryptsetup open $open_args /dev/nvme0n1p4 cryptlvm
        rootpv=/dev/mapper/cryptlvm
    fi

    bootpart=/dev/nvme0n1p3
    if [[ $crypt_boot -eq 1 ]]; then
        open_args=""
        cryptsetup $crypt_boot_args luksFormat --type luks1 /dev/nvme0n1p3 $crypt_boot_key
        if [[ $crypt_boot_key ]]; then
            open_args="--key-file $crypt_boot_key"
        fi
        cryptsetup open $open_args /dev/nvme0n1p3 cryptboot

        pvcreate -y /dev/mapper/cryptboot
        vgcreate vgboot /dev/mapper/cryptboot
        lvcreate -L1020M -n lvboot vgboot
        bootpart=/dev/mapper/vgboot-lvboot
    fi

    # Set up lvms
    pvcreate -y ${rootpv}
    vgcreate vgsys ${rootpv}

    lvcreate -L2G  -n lvroot     vgsys
    lvcreate -L5G  -n lvopt      vgsys
    lvcreate -L10G -n lvusr      vgsys
    lvcreate -L2G  -n lvtmp      vgsys
    lvcreate -L2G  -n lvvar      vgsys
    lvcreate -L2G  -n lvvardb    vgsys
    lvcreate -L10G -n lvvarcache vgsys
    lvcreate -L1G  -n lvsrv      vgsys
    lvcreate -L20G -n lvhome     vgsys
    lvcreate -L4G  -n lvswap     vgsys

    # Setup swap
    mkswap -L swap /dev/mapper/vgsys-lvswap
    swapon -L swap

    # Make file systems
    mkfs.fat -n efi -F32   /dev/nvme0n1p2
    mkfs.vfat -nboot       ${bootpart}
    mkfs.xfs  -f -L/          /dev/mapper/vgsys-lvroot
    mkfs.xfs  -f -L/opt       /dev/mapper/vgsys-lvopt
    mkfs.xfs  -f -L/usr       /dev/mapper/vgsys-lvusr
    mkfs.xfs  -f -L/tmp       /dev/mapper/vgsys-lvtmp
    mkfs.xfs  -f -L/var       /dev/mapper/vgsys-lvvar
    mkfs.xfs  -f -L/var/db    /dev/mapper/vgsys-lvvardb
    mkfs.xfs  -f -L/var/cache /dev/mapper/vgsys-lvvarcache
    mkfs.xfs  -f -L/srv       /dev/mapper/vgsys-lvsrv
    mkfs.xfs  -f -L/home      /dev/mapper/vgsys-lvhome

    # Mount partitions
    mount -L/          "$chroot"
    mkdir -p           "$chroot"/{efi,boot,opt,usr,tmp,var,srv,home}
    mount -Lefi        "$chroot/efi"
    mount -Lboot       "$chroot/boot"
    mount -L/opt       "$chroot/opt"
    mount -L/usr       "$chroot/usr"
    mount -L/tmp       "$chroot/tmp"
    mount -L/var       "$chroot/var"
    mkdir -p           "$chroot/var"/{db,cache}
    mount -L/var/db    "$chroot/var/db"
    mount -L/var/cache "$chroot/var/cache"
    mount -L/srv       "$chroot/srv"
    mount -L/home      "$chroot/home"

    # Set proper perms for /tmp
    chmod 1777 "$chroot/tmp"

    # Download and unpack stage3
    pushd "$chroot"
    wget -nv --tries=5 "$stage3url"
    tar xpvf "$stage3file" --xattrs-include='*.*' --numeric-owner && rm "$stage3file"
    popd

    # Copy nameserver information
    cp -L /etc/resolv.conf "$chroot/etc/"

    # Mount additional mount points
    mount -t proc none "$chroot/proc"
    mount --rbind /sys "$chroot/sys"
    mount --make-rslave "$chroot/sys"
    mount --rbind /dev "$chroot/dev"
    mount --make-rslave "$chroot/dev"
    mount -t tmpfs -o size=8G,uid=250,gid=250,mode=755,noatime none "$chroot/var/tmp/portage"

    chroot "$chroot" env-update

    # Set ssh to start on boot
    chroot "$chroot" /bin/bash <<DATAEOF
rc-update add sshd default
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

#<fs>            <mountpoint>     <type> <opts>                                   <dump/pass>
LABEL=boot       /boot            vfat   noatime                                  1 2
LABEL=/          /                xfs    defaults                                 0 1
LABEL=/opt       /opt             xfs    defaults                                 0 0
LABEL=/usr       /usr             xfs    defaults                                 0 0
LABEL=/tmp       /tmp             xfs    defaults,noatime                         0 0
LABEL=/var       /var             xfs    defaults,noatime                         0 0
LABEL=/var/db    /var/db          xfs    defaults,noatime                         0 0
LABEL=/var/cache /var/cache       xfs    defaults,noatime                         0 0
LABEL=/srv       /srv             xfs    defaults                                 0 0
LABEL=/home      /home            xfs    defaults                                 0 0
LABEL=swap       none             swap   sw                                       0 0

none             /var/tmp/portage tmpfs  size=8G,uid=250,gid=250,mode=755,noatime 0 0

DATAEOF

    # Set makeconf
    cat <<DATAEOF > "$chroot/etc/portage/make.conf"
CFLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
CHOST="$chost"
MAKEOPTS="-j$((1 + $nr_cpus)) -l${nr_cpus}.5"
GRUB_PLATFORMS="efi-64"

EMERGE_DEFAULT_OPTS="--jobs --load-average=${nr_cpus}.5"

INPUT_DEVICES="evdev"
VIDEO_CARDS="nouveau nvidia"
LINGUAS="en"
ACCEPT_LICENSE="-* @BINARY-REDISTRIBUTABLE"

FEATURES="parallel-fetch parallel-install candy"

PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"

GENTOO_MIRRORS="http://distfiles.gentoo.org http://www.ibiblio.org/pub/Linux/distributions/gentoo"

PORTAGE_ELOG_CLASSES="info qa warn log error"
PORTAGE_ELOG_SYSTEM="save echo:qa,error"
PORTAGE_NICENESS="10"

PYTHON_TARGETS="python3_9"
PYTHON_SINGLE_TARGET="python3_9"
LC_MESSAGES=C
DATAEOF

    # set locale
    chroot "$chroot" /bin/bash <<DATAEOF
locale-gen
eselect locale set $locale
env-update && source /etc/profile
DATAEOF

    chroot "$chroot" /bin/bash <<DATAEOF
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
DATAEOF

    # Update portage tree to most current state
    chroot "$chroot" emerge-webrsync

    # Ensure latest portage is installed and clear news
    chroot "$chroot" /bin/bash <<DATAEOF
emerge --oneshot sys-apps/portage
eselect news read
DATAEOF

    # set localtime
    chroot "$chroot" /bin/bash <<DATAEOF
echo "$timezone" > /etc/timezone
emerge --config sys-libs/timezone-data
DATAEOF
}


function _iwl7260_ucode() {
    mkdir -p "$chroot/etc/portage/package.accept_keywords/sys-kernel"
    cat <<DATAEOF > "$chroot/etc/portage/package.accept_keywords/sys-kernel/linux-firmware"
sys-kernel/linux-firmware
DATAEOF
    chroot "$chroot" /bin/bash <<DATAEOF
emerge sys-kernel/linux-firmware
DATAEOF
}

function kernel() {
    # Build the kernel
    if [[ $iwl7260 -eq 1 ]]; then
        _iwl7260_ucode
    fi
    chroot "$chroot" /bin/bash <<DATAEOF
git clone https://github.com/tmessi/initramfs.git /usr/src/initramfs
cd /usr/src/initramfs
./install.sh
USE="symlink" emerge sys-kernel/gentoo-sources gentoolkit

cd /usr/src/linux
# use a default configuration as a starting point
wget https://raw.githubusercontent.com/tmessi/kernel-configs/master/config.$hostname -O /usr/src/linux/.config
make olddefconfig

# build and install kernel, using the config created above
make -j${nr_cpus} bzImage modules && make modules_install && make install
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

function additional_progs() {
    # install fs tools
    chroot "$chroot" /bin/bash <<DATAEOF
emerge sys-fs/xfsprogs net-misc/connman dev-vcs/git sys-fs/lvm2
rc-update add lvm boot
rc-update add connman default
DATAEOF
}

function set_hostname() {
    cat <<DATAEOF > "$chroot/etc/conf.d/hostname"
hostname="$hostname"
DATAEOF
}

function grub() {
    # Install grub
    chroot "$chroot" emerge sys-boot/grub

    # Make the disk bootable
    chroot "$chroot" /bin/bash <<DATAEOF
source /etc/profile && \
env-update && \
grep -v rootfs /proc/mounts > /etc/mtab && \
mkdir -p /boot/grub && \
grub-install --target=x86_64-efi --efi-directory=/efi --no-floppy /dev/sda && \
grub-mkconfig -o /boot/grub/grub.cfg
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

    cat <<DATAEOF > "$chroot/recovery.sh"
#!/bin/bash
DATAEOF

    if [[ $crypt_boot -eq 1 ]]; then
        cat <<DATAEOF >> "$chroot/recovery.sh"
cryptsetup open /dev/nvme0n1p3 cryptboot
DATAEOF
    fi
    if [[ $crypt -eq 1 ]]; then
        cat <<DATAEOF >> "$chroot/recovery.sh"
cryptsetup open /dev/nvme0n1p4 cryptlvm
DATAEOF
    fi

    cat <<DATAEOF >> "$chroot/recovery.sh"
mount -L/boot "$chroot/boot"
mount -L/opt  "$chroot/opt"
mount -L/usr  "$chroot/usr"
mount -L/tmp  "$chroot/tmp"
mount -L/var  "$chroot/var"
mount -L/srv  "$chroot/srv"
mount -L/home "$chroot/home"
cp -L /etc/resolv.conf "$chroot/etc/"
mount -t proc none  "$chroot/proc"
mount --rbind /sys  "$chroot/sys"
mount --make-rslave "$chroot/sys"
mount --rbind /dev  "$chroot/dev"
mount --make-rslave "$chroot/dev"
mount -t tmpfs -o size=4096M,uid=250,gid=250,mode=755,noatime none "$chroot/var/tmp/portage"
chroot "$chroot" /bin/bash
DATAEOF
    chmod +x "$chroot/recovery.sh"
}

function _reset() {
    umount -l "$chroot/dev"
    umount -l "$chroot/sys"
    umount    "$chroot/var/db"
    umount    "$chroot/var/cache"
    umount    "$chroot/var/tmp/portage"
    umount    "$chroot/proc"
    umount    "$chroot/home"
    umount    "$chroot/srv"
    umount    "$chroot/var"
    umount    "$chroot/tmp"
    umount    "$chroot/usr"
    umount    "$chroot/opt"
    umount    "$chroot/boot"
    umount    "$chroot/efi"
    umount    "$chroot"
    swapoff -L swap
}

OPTS=$(getopt -o cwn:rh --long crypt-boot,crypt-boot-args:,crypt-boot-key:,crypt,crypt-args:,crypt-key:,wipe,hostname:,iwl7260,reset,help -n "$name" -- "$@")
if [[ $? != 0 ]]; then echo "option error" >&2; exit 1; fi

eval set -- "$OPTS"

while true; do
    case "$1" in
        -n|--hostname)
            hostname=$2
            shift 2;;
        -w|--wipe)
            wipe_old=1
            shift;;
        --iwl7260)
            iwl7260=1
            shift;;
        -c|--crypt)
            crypt=1
            shift;;
        --crypt-key)
            crypt=1
            crypt_key=$2
            shift 2;;
        --crypt-args)
            crypt=1
            crypt_args="$2"
            shift 2;;
        --crypt-boot)
            crypt_boot=1
            shift;;
        --crypt-boot-key)
            crypt=1
            crypt_boot_key=$2
            shift 2;;
        --crypt-boot-args)
            crypt=1
            crypt_boot_args="$2"
            shift 2;;
        -r|--reset)
            _reset
            exit 0;;
        -h|--help)
            print_help
            exit 0;;
        --)
            shift; break;;
        *)
            echo "Internal error!"; exit;;
    esac
done

base
cron
syslog
additional_progs
kernel
set_hostname
grub
cleanup
