#!/bin/bash
#
# Builds custom BootCD ISO and USB images in the current
# directory. For backward compatibility, if an old-style static
# configuration is specified, that configuration file will be parsed
# instead of the current PLC configuration in
# /etc/planetlab/plc_config.
#
# Aaron Klingaman <alk@absarokasoft.com>
# Mark Huang <mlhuang@cs.princeton.edu>
# Copyright (C) 2004-2006 The Trustees of Princeton University
#
# $Id: build.sh,v 1.35 2006/04/07 03:58:07 mlhuang Exp $
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin

CONFIGURATION=default
NODE_CONFIGURATION_FILE=

usage()
{
    echo "Usage: build.sh [OPTION]..."
    echo "	-c name		(Deprecated) Static configuration to use (default: $CONFIGURATION)"
    echo "	-f planet.cnf	Node to customize CD for (default: none)"
    echo "	-h		This message"
    exit 1
}

# Get options
while getopts "c:f:h" opt ; do
    case $opt in
	c)
	    CONFIGURATION=$OPTARG
	    ;;
	f)
	    NODE_CONFIGURATION_FILE=$OPTARG
	    ;;
	h|*)
	    usage
	    ;;
    esac
done

# Do not tolerate errors
set -e

# Change to our source directory
srcdir=$(cd $(dirname $0) && pwd -P)
pushd $srcdir

# Root of the isofs
isofs=$PWD/build/isofs

# Build reference image if it does not exist. This should only need to
# be executed once at build time, never at run time.
if [ ! -f $isofs/bootcd.img ] ; then
    ./prep.sh
fi

# build/version.txt written by prep.sh
BOOTCD_VERSION=$(cat build/version.txt)

if [ -f /etc/planetlab/plc_config ] ; then
    # Source PLC configuration
    . /etc/planetlab/plc_config
elif [ -d configurations/$CONFIGURATION ] ; then
    # (Deprecated) Source static configuration
    . configurations/$CONFIGURATION/configuration
    PLC_NAME="PlanetLab"
    PLC_MAIL_SUPPORT_ADDRESS="support@planet-lab.org"
    PLC_WWW_HOST="www.planet-lab.org"
    PLC_WWW_PORT=80
    if [ -n "$EXTRA_VERSION" ] ; then
	BOOTCD_VERSION="$BOOTCD_VERSION $EXTRA_VERSION"
    fi
    PLC_BOOT_HOST=$PRIMARY_SERVER
    PLC_BOOT_SSL_PORT=$PRIMARY_SERVER_PORT
    PLC_BOOT_SSL_CRT=configurations/$CONFIGURATION/$PRIMARY_SERVER_CERT
    PLC_ROOT_GPG_KEY_PUB=configurations/$CONFIGURATION/$PRIMARY_SERVER_GPG
fi

FULL_VERSION_STRING="$PLC_NAME BootCD $BOOTCD_VERSION"

# Root of the ISO and USB images
overlay=$(mktemp -d /tmp/overlay.XXXXXX)
install -d -m 755 $overlay
trap "rm -rf $overlay" ERR

# Create version files
echo "* Creating version files"

# Boot Manager compares pl_version in both places to make sure that
# the right CD is mounted. We used to boot from an initrd and mount
# the CD on /usr. Now we just run everything out of the initrd.
for file in $overlay/pl_version $overlay/usr/isolinux/pl_version ; do
    mkdir -p $(dirname $file)
    echo "$FULL_VERSION_STRING" >$file
done

# Install boot server configuration files
echo "* Installing boot server configuration files"

# We always intended to bring up and support backup boot servers,
# but never got around to it. Just install the same parameters for
# both for now.
for dir in $overlay/usr/boot $overlay/usr/boot/backup ; do
	install -D -m 644 $PLC_BOOT_SSL_CRT $dir/cacert.pem
	install -D -m 644 $PLC_ROOT_GPG_KEY_PUB $dir/pubring.gpg
	echo "$PLC_BOOT_HOST" >$dir/boot_server
	echo "$PLC_BOOT_SSL_PORT" >$dir/boot_server_port
	echo "/boot/" >$dir/boot_server_path
done

# (Deprecated) Install old-style boot server configuration files
install -D -m 644 $PLC_BOOT_SSL_CRT $overlay/usr/bootme/cacert/$PLC_BOOT_HOST/cacert.pem
echo "$FULL_VERSION_STRING" >$overlay/usr/bootme/ID
echo "$PLC_BOOT_HOST" >$overlay/usr/bootme/BOOTSERVER
echo "$PLC_BOOT_HOST" >$overlay/usr/bootme/BOOTSERVER_IP
echo "$PLC_BOOT_SSL_PORT" >$overlay/usr/bootme/BOOTPORT

# Generate /etc/issue
echo "* Generating /etc/issue"

if [ "$PLC_WWW_PORT" = "443" ] ; then
    PLC_WWW_URL="https://$PLC_WWW_HOST/"
elif [ "$PLC_WWW_PORT" != "80" ] ; then
    PLC_WWW_URL="http://$PLC_WWW_HOST:$PLC_WWW_PORT/"
else
    PLC_WWW_URL="http://$PLC_WWW_HOST/"
fi

mkdir -p $overlay/etc
cat >$overlay/etc/issue <<EOF
$FULL_VERSION_STRING
$PLC_NAME Node: \n
Kernel \r on an \m
$PLC_WWW_URL

This machine is a node in the $PLC_NAME distributed network.  It has
not fully booted yet. If you have cancelled the boot process at the
request of $PLC_NAME Support, please follow the instructions provided
to you. Otherwise, please contact $PLC_MAIL_SUPPORT_ADDRESS.

Console login at this point is restricted to root. Provide the root
password of the default $PLC_NAME Central administrator account at the
time that this CD was created.

EOF

# Set root password
echo "* Setting root password"

if [ -z "$ROOT_PASSWORD" ] ; then
    # Generate an encrypted password with crypt() if not defined
    # in a static configuration.
    ROOT_PASSWORD=$(python <<EOF
import crypt, random, string
salt = [random.choice(string.letters + string.digits + "./") for i in range(0,8)]
print crypt.crypt('$PLC_ROOT_PASSWORD', '\$1\$' + "".join(salt) + '\$')
EOF
)
fi

# build/passwd copied out by prep.sh
sed -e "s@^root:[^:]*:\(.*\)@root:$ROOT_PASSWORD:\1@" build/passwd \
    >$overlay/etc/passwd

# Install node configuration file (e.g., if node has no floppy disk or USB slot)
if [ -f "$NODE_CONFIGURATION_FILE" ] ; then
    echo "* Installing node configuration file"
    install -D -m 644 $NODE_CONFIGURATION_FILE $overlay/usr/boot/plnode.txt
fi

# Pack overlay files into a compressed archive
echo "* Compressing overlay image"
(cd $overlay && find . | cpio --quiet -c -o) | gzip -9 >$isofs/overlay.img

rm -rf $overlay
trap - ERR

# Calculate ramdisk size (total uncompressed size of both archives)
ramdisk_size=$(gzip -l $isofs/bootcd.img $isofs/overlay.img | tail -1 | awk '{ print $2; }') # bytes
ramdisk_size=$(($ramdisk_size / 1024)) # kilobytes

# Write isolinux configuration
echo "$FULL_VERSION_STRING" >$isofs/pl_version
cat >$isofs/isolinux.cfg <<EOF
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img root=/dev/ram0 rw
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF

# Change back to output directory
popd

# Create ISO image
echo "* Creating ISO image"
iso="$PLC_NAME-BootCD-$BOOTCD_VERSION.iso"
mkisofs -o "$iso" \
    -R -allow-leading-dots -J -r \
    -b isolinux.bin -c boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    $isofs

# Create USB image
echo "* Creating USB image"
usb="$PLC_NAME-BootCD-$BOOTCD_VERSION.usb"

# Leave 1 MB of free space on the VFAT filesystem
mkfs.vfat -C "$usb" $(($(du -sk $isofs | awk '{ print $1; }') + 1024))

# Mount it
tmp=$(mktemp -d /tmp/bootcd.XXXXXX)
mount -o loop "$usb" $tmp
trap "umount $tmp; rm -rf $tmp" ERR

# Populate it
echo "* Populating USB image"
(cd $isofs && find . | cpio -p -d -u $tmp/)

# Use syslinux instead of isolinux to make the image bootable
mv $tmp/isolinux.cfg $tmp/syslinux.cfg
umount $tmp
rmdir $tmp
trap - ERR

echo "* Making USB image bootable"
$srcdir/syslinux/unix/syslinux "$usb"

exit 0
