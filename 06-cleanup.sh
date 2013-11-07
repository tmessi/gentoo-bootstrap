#!/bin/bash
source /etc/profile

# cleanup
chroot "$chroot" /bin/bash <<DATAEOF
# delete temp, cached and build artifact data
eclean -d distfiles
rm -rf /tmp/*
rm -rf /var/log/*
rm -rf /var/tmp/*
DATAEOF

