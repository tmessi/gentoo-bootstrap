#!/bin/bash
source /etc/profile

# install cron
chroot "$chroot" /bin/bash <<DATAEOF
emerge sys-process/fcron
rc-update add fcron default
DATAEOF
