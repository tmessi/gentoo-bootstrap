#!/bin/bash

device=sdb

sgdisk -Z /dev/$device

# Partition the disk (http://www.rodsbooks.com/gdisk/sgdisk.html)
sgdisk -n 1:0:+2M   -t 1:ef02 -c 1:"linux-bios" \
       -n 2:0:+1G   -t 2:ef00 -c 2:"linux-boot" \
       -n 3:0:0     -t 3:8e00 -c 3:"linux-root" \
       -p /dev/$device

mkfs.vfat -ntboot  /dev/${device}2
mkfs.xfs  -Lthumby /dev/${device}3

mount -Ltboot /boot

grub2-install --target=x86_64-efi --efi-directory=/boot --no-flopp /dev/$device && \
grub2-mkconfig -o /boot/grub/grub.cfg
