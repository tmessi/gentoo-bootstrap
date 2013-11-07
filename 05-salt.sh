#!/bin/bash
source /etc/profile

# Install salt via bootstrap
chroot "$chroot" /bin/bash <<DATAEOF
wget -O - http://bootstrap.saltstack.org | sh
DATAEOF

