#
# Copyright (c) Microsoft Corporation. All Rights Reserved.
#

# debian/ubuntu superuser setup script

# show what's happening.
set -x
# exit on any unobserved failure.
set -e

APT_PACKAGES="vim-tiny git python python-dev python-pip libgmp-dev graphviz graphviz-dev pkg-config"

# the following workaround saves us from a long-standing concurrency bug in `apt` that
# i have observed when using vagrant on windows systems.
# see https://stackoverflow.com/questions/15505775/debian-apt-packages-hash-sum-mismatch
# for more details. at some point, this will not be needed but that seems like a long
# ways off still.
rm -rf /var/lib/apt/lists/*
apt-get clean
apt_fix_path=/etc/apt/apt.conf.d/99fixbadproxy
echo "Acquire::http::Pipeline-Depth 0;" > $apt_fix_path
echo "Acquire::http::No-Cache true;" >> $apt_fix_path
echo "Acquire::BrokenProxy true;" >> $apt_fix_path

# install all of the packages specified at the top of this script.
apt-get update
apt-get -y install $APT_PACKAGES

# let's install security updates and ensure an editor is installed, to be safe.
apt-get -y install unattended-upgrades
unattended-upgrade

