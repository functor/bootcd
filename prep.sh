#!/bin/bash
#
# Builds the BootCD reference image, the first of two
# initramfs cpio archives that are concatenated together by
# isolinux/syslinux to form a custom BootCD.
#
# Aaron Klingaman <alk@absarokasoft.com>
# Mark Huang <mlhuang@cs.princeton.edu>
# Copyright (C) 2004-2006 The Trustees of Princeton University
#
# $Id: prep.sh,v 1.3 2006/05/15 21:13:58 mlhuang Exp $
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin

# In both a normal CVS environment and a PlanetLab RPM
# build environment, all of our dependencies are checked out into
# directories at the same level as us.
if [ -d ../build ] ; then
    PATH=$PATH:../build
    srcdir=..
else
    echo "Error: Could not find sources in either . or .."
    exit 1
fi

export PATH

# Release and architecture to install
releasever=4
basearch=i386

# Packages to install
packagelist=(
dev
dhclient
bash
coreutils
iputils
kernel
bzip2
diffutils
logrotate
passwd
rsh
rsync
sudo
tcpdump
telnet
traceroute
time
wget
yum
curl
gzip
python
tar
pciutils
kbd
authconfig
hdparm
lvm
lvm2
kexec-tools
gnupg
nano
parted
pyparted
openssh-server
openssh-clients
ncftp
dosfstools
dos2unix
bind-utils
sharutils
pycurl
)

usage()
{
    echo "Usage: prep.sh [OPTION]..."
    echo "	-r release	Fedora release number (default: $releasever)"
    echo "	-a arch		Fedora architecture (default: $basearch)"
    echo "	-h		This message"
    exit 1
}

# Get options
while getopts "r:a:h" opt ; do
    case $opt in
	r)
	    releasever=$OPTARG
	    ;;
	a)
	    basearch=$OPTARG
	    ;;
	h|*)
	    usage
	    ;;
    esac
done

# Do not tolerate errors
set -e

# Root of the initramfs reference image
bootcd=$PWD/build/bootcd
install -d -m 755 $bootcd

# Write version number
rpmquery --specfile bootcd.spec --queryformat '%{VERSION}\n' | head -1 >build/version.txt

# Install base system
for package in "${packagelist[@]}" ; do
    packages="$packages -p $package"
done
mkfedora -v -r $releasever -a $basearch -k $packages $bootcd

# Disable all services in reference image
chroot $bootcd sh -c "/sbin/chkconfig --list | awk '{ print \$1 }' | xargs -i /sbin/chkconfig {} off"

# Install configuration files
echo "* Installing configuration files"
for file in fstab mtab modprobe.conf inittab hosts sysctl.conf ; do
    install -D -m 644 conf_files/$file $bootcd/etc/$file
done

# Install initscripts
echo "* Installing initscripts"
for file in pl_sysinit pl_hwinit pl_netinit pl_validateconf pl_boot ; do
    install -D -m 755 conf_files/$file $bootcd/etc/init.d/$file
done

# Install fallback node configuration file
echo "* Installing fallback node configuration file"
install -D -m 644 conf_files/default-net.cnf $bootcd/usr/boot/default-net.cnf

# Build pcitable for hardware detection
echo "* Building pcitable for hardware detection"
pci_map_file=$(find $bootcd/lib/modules/ -name modules.pcimap | head -1)
module_dep_file=$(find $bootcd/lib/modules/ -name modules.dep | head -1)
pci_table=$bootcd/usr/share/hwdata/pcitable
$srcdir/bootmanager/source/merge_hw_tables.py \
    $module_dep_file $pci_map_file $pci_table $bootcd/etc/pl_pcitable

# Copy /etc/passwd out
install -D -m 644 $bootcd/etc/passwd build/passwd

# Root of the isofs
isofs=$PWD/build/isofs
install -d -m 755 $isofs

# Copy the kernel out
for kernel in $bootcd/boot/vmlinuz-* ; do
    if [ -f $kernel ] ; then
	install -D -m 644 $kernel $isofs/kernel
    fi
done

# initramfs requires that /init be present
ln -sf /sbin/init $bootcd/init

# Pack the rest into a compressed archive
echo "* Compressing reference image"
(cd $bootcd && find . | cpio --quiet -c -o) | gzip -9 >$isofs/bootcd.img

# Build syslinux
echo "* Building syslinux"
CFLAGS="-Werror -Wno-unused -finline-limit=2000" make -C syslinux

# Install isolinux
echo "* Installing isolinux"
install -D -m 644 syslinux/isolinux.bin $isofs/isolinux.bin

exit 0
