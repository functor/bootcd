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

. build.common

pldistro=$1 ; shift
nodefamily=$1; shift
rpmversion=$1; shift

# Packages to install, junk and precious : see build/<pldistro>/bootcd.pkgs

# Do not tolerate errors
set -e

# Root of the initramfs reference image
bootcd=$PWD/build/bootcd
install -d -m 755 $bootcd

# Write version number
echo ${rpmversion} > build/version.txt
echo ${nodefamily} > build/nodefamily

# Install base system
echo "* Creating fedora root image"
pl_root_makedevs $bootcd
pkgsfile=$(pl_locateDistroFile ../build/ $pldistro bootcd.pkgs) 
pl_root_mkfedora $bootcd $pldistro $pkgsfile
pl_root_tune_image $bootcd

# Add site_admin console account to BootCD: with root priv, and self passwd
CRYPT_SA_PASSWORD=$(python -c "import crypt, random, string; salt = [random.choice(string.letters + string.digits + \"./\") for i in range(0,8)] ; print crypt.crypt('site_admin', '\$1\$' + \"\".join(salt) + '\$')")
chroot ${bootcd} /usr/sbin/useradd -p "$CRYPT_SA_PASSWORD" -o -g 0 -u 0 -m site_admin

# Install ipnmac (for SuperMicro machines with IPMI)
echo "* Installing IPMI utilities"
install -D -m 755 ipnmac/ipnmac.x86 $bootcd/usr/sbin/ipnmac

# Install initscripts
echo "* Installing initscripts"
for file in pl_functions pl_sysinit pl_hwinit pl_netinit pl_validateconf pl_boot ; do
    sed -i -e "s,@PLDISTRO@,$pldistro,g" -e "s,@FCDISTRO@,$fcdistro,g" initscripts/$file
    install -D -m 755 initscripts/$file $bootcd/etc/init.d/$file
done

# Install configuration files
echo "* Installing configuration files"
for file in fstab mtab modprobe.conf inittab hosts sysctl.conf ; do
    install -D -m 644 etc/$file $bootcd/etc/$file
done
# connect our initscripts scripts for upstart
# fedora 9 comes with /sbin/init from upstart, that uses /etc/event.d instead of inittab
# (in fact inittab is read for determining the default runlevel)
if [ -d $bootcd/etc/event.d ] ; then
    echo "* Tuning /etc/event.d/ for upstart"
    pushd $bootcd/etc/event.d
    # use our system initialisation script
    sed -i -e 's,/etc/rc\.d/rc\.sysinit[a-z\.]*,/etc/init.d/pl_sysinit,g' rcS
    # use our startup script in runlevel 2
    sed -i -e 's,/etc/rc\.d/rc[ \t][ \t]*2,/etc/init.d/pl_boot,g' rc2
    popd    
fi
# ditto for f14 and higher init style
if [ -d $bootcd/etc/init ] ; then
    echo "* Tuning /etc/init/ for upstart"
    pushd $bootcd/etc/init
    # use our system initialisation script
    sed -i -e 's,/etc/rc\.d/rc\.sysinit[a-z\.]*,/bin/bash -c /etc/init.d/pl_sysinit,g' rcS.conf
    # use our startup script in runlevel 2
    sed -i -e 's,/etc/rc.d/rc[a-z\.]*,/etc/init.d/pl_boot,g' rc.conf
    popd    
fi
# Install systemd files for f16 and above
if [ -d $bootcd/etc/systemd/system ] ; then
    echo "* Installing systemd files"
    for file in pl_boot.service pl_boot.target ; do
        install -D -m 644 systemd/$file $bootcd/etc/systemd/system
    done
    echo "* Enabling getty on tty2"
    # select pl_boot target this way instead of using kargs, as kargs apply to kexec boot as well
    ln -sf /etc/systemd/system/pl_boot.target $bootcd/etc/systemd/system/default.target
    [ -d $bootcd/etc/systemd/system/pl_boot.target.wants ] || mkdir -p $bootcd/etc/systemd/system/pl_boot.target.wants
    ln -sf /usr/lib/systemd/system/getty@.service $bootcd/etc/systemd/system/pl_boot.target.wants/getty@tty2.service
fi

# Install fallback node configuration file
echo "* Installing fallback node configuration file"
install -D -m 644 usr-boot/default-node.txt $bootcd/usr/boot/default-node.txt

# Copy /etc/passwd out
install -D -m 644 $bootcd/etc/passwd build/passwd

# Root of the isofs
isofs=$PWD/build/isofs
install -d -m 755 $isofs

# Copy the kernel out
for kernel in $bootcd/boot/vmlinuz-* ; do
    if [ -f $kernel ] ; then
	install -D -m 644 $kernel $isofs/kernel
	echo "* kernel created from $kernel" > $isofs/kernel.from
    fi
done

# Don't need /boot anymore
rm -rf $bootcd/boot

# initramfs requires that /init be present
ln -sf /sbin/init $bootcd/init

# Pack the rest into a compressed archive
echo "* Compressing reference image"
(cd $bootcd && find . | cpio --quiet -c -o) | gzip -9 > $isofs/bootcd.img

exit 0
