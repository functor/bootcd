#!/bin/bash
#
# Builds custom BootCD ISO and USB images in the current
# directory.
#
# Mark Huang <mlhuang@cs.princeton.edu>
# Copyright (C) 2004-2006 The Trustees of Princeton University
#
# $Id$
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin

BOOTCD_VERSION=4.0

if [ -f /etc/planetlab/plc_config ] ; then
    # Source PLC configuration
    . /etc/planetlab/plc_config
else
    echo "Could not find /etc/planetlab/plc_config."
    echo "This file defines the configuration of your PlanetLab installation."
    exit 1
fi

# This support for backwards compatibility can be taken out in the
# future. RC1 based MyPLCs set $PLC_BOOT_SSL_CRT in the plc_config
# file, but >=RC2 based bootcd assumes that $PLC_BOOT_CA_SSL_CRT is
# set.
if [ -z "$PLC_BOOT_CA_SSL_CRT" -a ! -z "$PLC_BOOT_SSL_CRT" ] ; then
    PLC_BOOT_CA_SSL_CRT=$PLC_BOOT_SSL_CRT
    PLC_API_CA_SSL_CRT=$PLC_API_SSL_CRT
fi

output="$PLC_NAME-BootCD-$BOOTCD_VERSION.iso"

usage()
{
    echo "Usage: build.sh [OPTION]..."
    eceho "	-o file		Output file (default: $output)"
    echo "	-h		This message"
    exit 1
}

# Get options
while getopts "o:h" opt ; do
    case $opt in
	o)
	    output=$OPTARG
	    ;;
	h|*)
	    usage
	    ;;
    esac
done

FULL_VERSION_STRING="$PLC_NAME BootCD $BOOTCD_VERSION"
echo "* Building image for $FULL_VERSION_STRING"

# Do not tolerate errors
set -e

# Change to our source directory
srcdir=$(cd $(dirname $0) && pwd -P)
pushd $srcdir >/dev/null

# Root of the isofs
isofs=$PWD/isofs

# Miscellaneous files
misc=$(mktemp -d /tmp/misc.XXXXXX)
trap "rm -rf $misc" ERR INT

# initramfs requires that /init be present
ln -sf /sbin/init $misc/init

# Create version file
echo "$FULL_VERSION_STRING" >$misc/.bootcd

# Install GPG, boot, and API server public keys and certificates
install -D -m 644 $PLC_ROOT_GPG_KEY_PUB $misc/$PLC_ROOT_GPG_KEY_PUB
install -D -m 644 $PLC_BOOT_CA_SSL_CRT $misc/$PLC_BOOT_CA_SSL_CRT
install -D -m 644 $PLC_API_CA_SSL_CRT $misc/$PLC_API_CA_SSL_CRT

cat > $misc/etc/planetlab/plc_config <<EOF
PLC_ROOT_GPG_KEY_PUB='$PLC_ROOT_GPG_KEY_PUB'

PLC_BOOT_HOST='$PLC_BOOT_HOST'
PLC_BOOT_IP='$PLC_BOOT_IP'
PLC_BOOT_PORT=$PLC_BOOT_PORT
PLC_BOOT_SSL_PORT=$PLC_BOOT_SSL_PORT
PLC_BOOT_CA_SSL_CRT='$PLC_BOOT_CA_SSL_CRT'

PLC_API_HOST='$PLC_API_HOST'
PLC_API_IP='$PLC_API_IP'
PLC_API_PORT=$PLC_API_PORT
PLC_API_PATH='$PLC_API_PATH'
PLC_API_CA_SSL_CRT='$PLC_API_CA_SSL_CRT'
EOF

# Generate /etc/issue
if [ "$PLC_WWW_PORT" = "443" ] ; then
    PLC_WWW_URL="https://$PLC_WWW_HOST/"
elif [ "$PLC_WWW_PORT" != "80" ] ; then
    PLC_WWW_URL="http://$PLC_WWW_HOST:$PLC_WWW_PORT/"
else
    PLC_WWW_URL="http://$PLC_WWW_HOST/"
fi

mkdir -p $misc/etc
cat >$misc/etc/issue <<EOF
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

# Pack miscellaneous files into a compressed archive
echo "* Compressing miscellaneous files image"
(cd $misc && find . | cpio --quiet -H newc -o) | \
    python ../filesystem/cpiochown.py --owner root:root - | \
    gzip -9 >$isofs/misc.img

rm -rf $misc
trap - ERR INT

# Calculate ramdisk size (total uncompressed size of all initrds)
ramdisk_size=$(gzip -l $isofs/*.img | tail -1 | awk '{ print $2; }') # bytes
ramdisk_size=$((($ramdisk_size + 1023) / 1024)) # kilobytes

# Write isolinux configuration
echo "$FULL_VERSION_STRING" >$isofs/version
cat >$isofs/isolinux.cfg <<EOF
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=base.img,bootcd.img,misc.img root=/dev/ram0 rw console=tty0
DISPLAY version
PROMPT 0
TIMEOUT 40
EOF

popd >/dev/null

# Create ISO image
echo "* Creating ISO image"
mkisofs -o "$output" \
    -R -allow-leading-dots -J -r \
    -b isolinux.bin -c boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    $isofs

# XXX Create USB image

exit 0
