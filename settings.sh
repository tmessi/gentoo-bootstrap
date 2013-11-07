# settings that will be shared between all scripts

cat <<DATAEOF > "/etc/profile.d/boostrap-settings.sh"
build_arch="amd64"
build_proc="amd64"
stage3current=\`curl -s http://distfiles.gentoo.org/releases/\${build_arch}/autobuilds/latest-stage3-\${build_proc}.txt|grep -v "^#"\`
export stage3url="http://distfiles.gentoo.org/releases/\${build_arch}/autobuilds/\${stage3current}"
export stage3file=\${stage3current##*/}

# chost
export chost="x86_64-pc-linux-gnu"

# kernel version to use
export kernel_version="3.10.17"

# timezone (as a subdirectory of /usr/share/zoneinfo)
export timezone="UTC"

# locale
export locale="en_US.utf8"

# chroot directory for the installation
export chroot=/mnt/gentoo

# number of cpus in the host system (to speed up make and for kernel config)
export nr_cpus=$(</proc/cpuinfo grep processor|wc -l)
DATAEOF

