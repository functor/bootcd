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
# Copyright (C) 2004-2007 The Trustees of Princeton University
#
# $Id$
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin

CONFIGURATION=default
NODE_CONFIGURATION_FILE=
DEFAULT_TYPES="usb iso"
# Leave 4 MB of free space
FREE_SPACE=4096
CUSTOM_DIR=
OUTPUT_BASE=
GRAPHIC_CONSOLE="graphic"
SERIAL_CONSOLE="ttyS0:115200:n:8"
CONSOLE_INFO=$GRAPHIC_CONSOLE
MKISOFS_OPTS="-R -J -r -f -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"

ALL_TYPES=""
for x in iso usb usb_partition; do for s in "" "_serial" ; do for c in "" "_cramfs" ; do
  t="${x}${c}${s}"
  case $t in
      usb_partition_cramfs|usb_partition_cramfs_serial)
	  # unsupported
	  ;;
      *)
	  ALL_TYPES="$ALL_TYPES $t" ;;
  esac
done; done; done

# NOTE
# the custom-dir feature is designed to let a myplc try/ship a patched bootcd
# without the need for a full devel environment
# for example, you would create /root/custom-bootcd/etc/rc.d/init.d/pl_hwinit
# and run this script with -C /root/custom-bootcd
# this creates a third .img image of the custom dir, that 'hides' the files from 
# bootcd.img in the resulting unionfs
# it seems that this feature has not been used nor tested in a long time, use with care
usage()
{
    echo "Usage: build.sh [OPTION]..."
    echo "    -c name          (Deprecated) Static configuration to use (default: $CONFIGURATION)"
    echo "    -f plnode.txt    Node to customize CD for (default: none)"
    echo "    -t 'types'       Build the specified images (default: $DEFAULT_TYPES)"
    echo "    -a               Build all known types as listed below"
    echo "    -s console-info  Enable a serial line as console and also bring up getty on that line"
    echo "                     console-info: tty:baud-rate:parity:bits"
    echo "                     or 'default' shortcut for $SERIAL_CONSOLE"
    echo "                     Using this is recommended, rather than mentioning 'serial' in a type"
    echo "    -O output-base   The prefix of the generated files (default: PLC_NAME-BootCD-VERSION)"
    echo "                     useful when multiple types are provided"
    echo "                     can be a full path"
    echo "    -o output-name   The full name of the generated file"
    echo "    -C custom-dir    Custom directory"
    echo "    -n               Dry run - mostly for debug/test purposes"
    echo "    -h               This message"
    echo "All known types: $ALL_TYPES"
    exit 1
}

# init
TYPES=""
# Get options
while getopts "c:f:t:as:O:o:C:nh" opt ; do
    case $opt in
    c)
        CONFIGURATION=$OPTARG ;;
    f)
        NODE_CONFIGURATION_FILE=$OPTARG ;;
    t)
        TYPES="$TYPES $OPTARG" ;;
    a)
        TYPES="$ALL_TYPES" ;;
    s)
        CONSOLE_INFO="$OPTARG" 
	[ "$CONSOLE_INFO" == "default" ] && CONSOLE_INFO=$SERIAL_CONSOLE
	;;
    O)
        OUTPUT_BASE="$OPTARG" ;;
    o)
        OUTPUT_NAME="$OPTARG" ;;
    C)
        CUSTOM_DIR="$OPTARG" ;;
    n)
	DRY_RUN=true ;;
    h|*)
        usage ;;
    esac
done

# use default if not set
[ -z "$TYPES" ] && TYPES="$DEFAULT_TYPES"

# Do not tolerate errors
set -e

# Change to our source directory
srcdir=$(cd $(dirname $0) && pwd -P)
pushd $srcdir

# Root of the isofs
isofs=$PWD/build/isofs

# The reference image is expected to have been built by prep.sh (see .spec)
# we disable the initial logic that called prep.sh if that was not the case
# this is because prep.sh needs to know pldistro 
if [ ! -f $isofs/bootcd.img -o ! -f build/version.txt ] ; then
    echo "You have to run prep.sh prior to calling $0 - exiting"
    exit 1
fi

# build/version.txt written by prep.sh
BOOTCD_VERSION=$(cat build/version.txt)

if [ -f /etc/planetlab/plc_config ] ; then
    # Source PLC configuration
    . /etc/planetlab/plc_config
fi

### This support for backwards compatibility can be taken out in the
### future. RC1 based MyPLCs set $PLC_BOOT_SSL_CRT in the plc_config
### file, but >=RC2 based bootcd assumes that $PLC_BOOT_CA_SSL_CRT is
### set.
if [ -z "$PLC_BOOT_CA_SSL_CRT" -a ! -z "$PLC_BOOT_SSL_CRT" ] ; then
    PLC_BOOT_CA_SSL_CRT=$PLC_BOOT_SSL_CRT
fi

# If PLC configuration is not valid, try a static configuration
if [ -z "$PLC_BOOT_CA_SSL_CRT" -a -d configurations/$CONFIGURATION ] ; then
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
    PLC_BOOT_CA_SSL_CRT=configurations/$CONFIGURATION/$PRIMARY_SERVER_CERT
    PLC_ROOT_GPG_KEY_PUB=configurations/$CONFIGURATION/$PRIMARY_SERVER_GPG
fi

FULL_VERSION_STRING="${PLC_NAME} BootCD ${BOOTCD_VERSION}"

echo "* Building images for $FULL_VERSION_STRING"

# From within a myplc chroot /usr/tmp is too small 
# to build all possible images, whereas /data is part of the host
# filesystem and usually has sufficient space.  What we
# should do is check whether the expected amount of space
# is available.
BUILDTMP=/usr/tmp
if [ -d /data/tmp ] ; then
    isreadonly=$(mktemp /data/tmp/isreadonly.XXXXXX || /bin/true)
    if [ -n "$isreadonly" ] ; then
        rm -f "$isreadonly"
        BUILDTMP=/data/tmp
    fi
fi

declare -a _CLEANUPS=()
function do_cleanup()
{
    cd /
    for i in "${_CLEANUPS[@]}"; do
        $i
    done
}
function push_cleanup()
{
    _CLEANUPS=( "${_CLEANUPS[@]}" "$*" )
}
function pop_cleanup()
{
    unset _CLEANUPS[$((${#_CLEANUPS[@]} - 1))]
}

trap "do_cleanup" ERR INT EXIT

BUILDTMP=$(mktemp -d ${BUILDTMP}/bootcd.XXXXXX)
push_cleanup rm -fr "${BUILDTMP}"
mkdir "${BUILDTMP}/isofs"
for i in "$isofs"/{bootcd.img,kernel}; do
    ln -s "$i" "${BUILDTMP}/isofs"
done
cp "/usr/lib/syslinux/isolinux.bin" "${BUILDTMP}/isofs"
isofs="${BUILDTMP}/isofs"

# Root of the ISO and USB images
echo "* Populating root filesystem..."
overlay="${BUILDTMP}/overlay"
install -d -m 755 $overlay
push_cleanup rm -fr $overlay

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
    install -D -m 644 $PLC_BOOT_CA_SSL_CRT $dir/cacert.pem
    install -D -m 644 $PLC_ROOT_GPG_KEY_PUB $dir/pubring.gpg
    echo "$PLC_BOOT_HOST" >$dir/boot_server
    echo "$PLC_BOOT_SSL_PORT" >$dir/boot_server_port
    echo "/boot/" >$dir/boot_server_path
done

# (Deprecated) Install old-style boot server configuration files
install -D -m 644 $PLC_BOOT_CA_SSL_CRT $overlay/usr/bootme/cacert/$PLC_BOOT_HOST/cacert.pem
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
    echo "* Installing node configuration file $NODE_CONFIGURATION_FILE -> /usr/boot/plnode.txt of the bootcd image"
    install -D -m 644 $NODE_CONFIGURATION_FILE $overlay/usr/boot/plnode.txt
fi

# Pack overlay files into a compressed archive
echo "* Compressing overlay image"
(cd $overlay && find . | cpio --quiet -c -o) | gzip -9 >$isofs/overlay.img

rm -rf $overlay
pop_cleanup

if [ -n "$CUSTOM_DIR" ]; then
    echo "* Compressing custom image"
    (cd "$CUSTOM_DIR" && find . | cpio --quiet -c -o) | gzip -9 >$isofs/custom.img
fi

# Calculate ramdisk size (total uncompressed size of both archives)
ramdisk_size=$(gzip -l $isofs/bootcd.img $isofs/overlay.img ${CUSTOM_DIR:+$isofs/custom.img} | tail -1 | awk '{ print $2; }') # bytes
ramdisk_size=$((($ramdisk_size + 1023) / 1024)) # kilobytes

echo "$FULL_VERSION_STRING" >$isofs/pl_version

popd

function extract_console_dev()
{
    local console="$1"
    dev=$(echo $console| awk -F: ' {print $1}')
    echo $dev
}

function extract_console_baud()
{
    local console="$1"
    baud=$(echo $console| awk -F: ' {print $2}')
    [ -z "$baud" ] && baud="115200"
    echo $baud
}

function extract_console_parity()
{
    local console="$1"
    parity=$(echo $console| awk -F: ' {print $3}')
    [ -z "$parity" ] && parity="n"
    echo $parity
}

function extract_console_bits()
{
    local console="$1"
    bits=$(echo $console| awk -F: ' {print $4}')
    [ -z "$bits" ] && bits="8"
    echo $bits
}

function build_iso()
{
    local iso="$1" ; shift
    local console="$1" ; shift
    local custom="$1"
    local serial=

    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
	console_parity=$(extract_console_parity $console)
	console_bits=$(extract_console_bits $console)
    fi

    # Write isolinux configuration
    cat >$isofs/isolinux.cfg <<EOF
${serial:+SERIAL 0 ${console_baud}}
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${serial:+console=${console_dev},${console_baud}${console_parity}${console_bits}}
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF

    # Create ISO image
    echo "* Creating ISO image"
    mkisofs -o "$iso" \
        $MKISOFS_OPTS \
        $isofs
}

function build_usb_partition()
{
    echo -n "* Creating USB image with partitions..."
    local usb="$1" ; shift
    local console="$1" ; shift
    local custom="$1"
    local serial=

    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
	console_parity=$(extract_console_parity $console)
	console_bits=$(extract_console_bits $console)
    fi

    local size=$(($(du -Lsk $isofs | awk '{ print $1; }') + $FREE_SPACE))
    size=$(( $size / 1024 ))

    local heads=64
    local sectors=32
    local cylinders=$(( ($size*1024*2)/($heads*$sectors) ))
    local offset=$(( $sectors*512 ))

    /usr/lib/syslinux/mkdiskimage -M -4 "$usb" $size $heads $sectors
    
    cat >${BUILDTMP}/mtools.conf<<EOF
drive z:
file="${usb}"
cylinders=$cylinders
heads=$heads
sectors=$sectors
offset=$offset
mformat_only
EOF
    # environment variable for mtools
    export MTOOLSRC="${BUILDTMP}/mtools.conf"

    ### COPIED FROM build_usb() below!!!!
    echo -n " populating USB image... "
    mcopy -bsQ -i "$usb" "$isofs"/* z:/
	
    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${serial:+SERIAL 0 ${console_baud}}
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${serial:+console=${console_dev},${console_baud}${console_parity}${console_bits}}
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF
    mdel -i "$usb" z:/isolinux.cfg 2>/dev/null || :
    mcopy -i "$usb" "$tmp" z:/syslinux.cfg
    rm -f "$tmp"
    rm -f "${BUILDTMP}/mtools.conf"
    unset MTOOLSRC

    echo "making USB image bootable."
    syslinux -o $offset "$usb"

}

# Create USB image
function build_usb()
{
    echo -n "* Creating USB image... "
    local usb="$1" ; shift
    local console="$1" ; shift
    local custom="$1"
    local serial=

    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
	console_parity=$(extract_console_parity $console)
	console_bits=$(extract_console_bits $console)
    fi

    mkfs.vfat -C "$usb" $(($(du -Lsk $isofs | awk '{ print $1; }') + $FREE_SPACE))

    # Populate it
    echo -n " populating USB image... "
    mcopy -bsQ -i "$usb" "$isofs"/* ::/

    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${serial:+SERIAL 0 $console_baud}
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${serial:+console=${console_dev},${console_baud}${console_parity}${console_bits}}
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF
    mdel -i "$usb" ::/isolinux.cfg 2>/dev/null || :
    mcopy -i "$usb" "$tmp" ::/syslinux.cfg
    rm -f "$tmp"

    echo "making USB image bootable."
    syslinux "$usb"
}


# Setup CRAMFS related support
function prepare_cramfs()
{
    [ -n "$CRAMFS_PREPARED" ] && return 0
    local console=$1; shift
    local custom=$1; 
    local serial=
    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
    fi

    echo "* Setting up CRAMFS-based images"
    local tmp="${BUILDTMP}/cramfs-tree"
    mkdir -p "$tmp"
    push_cleanup rm -rf $tmp
    pushd $tmp
    gzip -d -c $isofs/bootcd.img     | cpio -diu
    gzip -d -c $isofs/overlay.img    | cpio -diu
    [ -n "$custom" ] && \
        gzip -d -c $isofs/custom.img | cpio -diu

    # clean out unnecessary rpm lib
    echo "* clearing var/lib/rpm/*"
    rm -f var/lib/rpm/*

    # bootcd requires this directory
    mkdir -p mnt/confdevice

    # relocate various directory to /tmp
    rm -rf root
    ln -fs /tmp/root root
    ln -fs /sbin/init linuxrc 
    ln -fs /tmp/resolv.conf etc/resolv.conf
    ln -fs /tmp/etc/mtab etc/mtab

    # have pl_rsysinit copy over appropriate etc & var directories into /tmp/etc/
    # make /tmp/etc
    echo "* renaming dirs in ./etc"
    pushd etc
    for dir in `find * -type d -prune | grep -v rc.d`; do
        mv ${dir} ${dir}_o
        ln -fs /tmp/etc/${dir} ${dir}
    done
    popd

    echo "* renaming dirs in ./var"
    # rename all top-level directories and put in a symlink to /tmp/var
    pushd var
    for dir in `find * -type d -prune`; do
        mv ${dir} ${dir}_o
        ln -fs /tmp/var/${dir} ${dir}
    done
    popd

    # overwrite fstab to mount / as cramfs and /tmp as tmpfs
    echo "* Overwriting etc/fstab to use cramfs and tmpfs"
    rm -f ./etc/fstab
    cat >./etc/fstab <<EOF
/dev/ram0     /              cramfs     ro              0 0
none          /dev/pts       devpts     gid=5,mode=620  0 0
none          /proc          proc       defaults        0 0
none          /sys           sysfs      defaults        0 0
EOF

    pushd dev
    rm -f console
    mknod console c 5 1
    #for i in 0 1 2 3 4 5 6 7 8; do rm -f ram${i} ; done
    #for i in 0 1 2 3 4 5 6 7 8; do mknod ram${i} b 1 ${i} ; done
    #ln -fs ram1 ram
    #ln -fs ram0 ramdisk
    popd

    # update etc/inittab to start with pl_rsysinit
    sed -i 's,pl_sysinit,pl_rsysinit,' etc/inittab

    # modify inittab to have a serial console
    if [ -n "$serial" ] ; then
	echo "T0:23:respawn:/sbin/agetty -L $console_dev $console_baud vt100" >> etc/inittab
        # and let root log in
	echo "$console_dev" >> etc/securetty
    fi

    # calculate the size of /tmp based on the size of /etc & /var + 8MB slack
    etcsize=$(du -s ./etc | awk '{ print $1 }')
    varsize=$(du -s ./var | awk '{ print $1 }')
    let msize=($varsize+$etcsize+8192)/1024

    # make dhclient happy
    for i in $(seq 0 9); do ln -fs /tmp/etc/dhclient-eth${i}.conf etc/dhclient-eth${i}.conf ; done
    ln -fs /tmp/etc/resolv.conf etc/resolv.conf
    ln -fs /tmp/etc/resolv.conf.predhclient etc/resolv.conf.predhclient

    # generate pl_rsysinit
    cat > etc/rc.d/init.d/pl_rsysinit <<EOF
#!/bin/sh
# generated by build.sh
echo -n "pl_rsysinit: preparing /etc and /var for pl_sysinit..."
mount -t tmpfs -orw,size=${msize}M,mode=1777 tmpfs /tmp
mkdir -p /tmp/root
mkdir -p /tmp/etc
touch /tmp/etc/resolv.conf
touch /tmp/etc/mtab
mkdir -p /tmp/var

# make mtab happy
echo "tmpfs /tmp tmpfs rw,size=${msize}M,mode=1777 1 1" > /tmp/etc/mtab

# copy over directory contents of all _o directories from /etc and /var
# /tmp/etc and /tmp/var
pushd /etc
for odir in \$(cd /etc && ls -d *_o); do dir=\$(echo \$odir | sed 's,\_o$,,'); (mkdir -p /tmp/etc/\$dir && cd \$odir && find . | cpio -p -d -u /tmp/etc/\$dir); done
popd
pushd /var
for odir in \$(cd /var && ls -d *_o); do dir=\$(echo \$odir | sed 's,\_o$,,'); (mkdir -p /tmp/var/\$dir && cd \$odir && find . | cpio -p -d -u /tmp/var/\$dir); done
popd

echo "done"

# hand over to pl_sysinit
echo "pl_rsysinit: handing over to pl_sysinit"
/etc/init.d/pl_sysinit
EOF
    chmod +x etc/rc.d/init.d/pl_rsysinit

    popd

    # create the cramfs image
    echo "* Creating cramfs image"
    mkfs.cramfs $tmp/ ${BUILDTMP}/cramfs.img
    cramfs_size=$(($(du -sk ${BUILDTMP}/cramfs.img | awk '{ print $1; }') + 1))
    rm -rf $tmp
    pop_cleanup
}

# Create ISO CRAMFS image
function build_iso_cramfs()
{
    local iso="$1" ; shift
    local console="$1" ; shift
    local custom="$1"
    local serial=

    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
	console_parity=$(extract_console_parity $console)
	console_bits=$(extract_console_bits $console)
    fi
    prepare_cramfs "$console" "$custom"
    echo "* Creating ISO CRAMFS-based image"

    local tmp="${BUILDTMP}/cramfs-iso"
    mkdir -p "$tmp"
    push_cleanup rm -rf $tmp
    (cd $isofs && find . | grep -v "\.img$" | cpio -p -d -u $tmp/)
    cat >$tmp/isolinux.cfg <<EOF
${serial:+SERIAL 0 $console_baud}
DEFAULT kernel
APPEND ramdisk_size=$cramfs_size initrd=cramfs.img root=/dev/ram0 ro ${serial:+console=${console_dev},${console_baud}${console_parity}${console_bits}}
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF

    cp ${BUILDTMP}/cramfs.img $tmp
    mkisofs -o "$iso" \
        $MKISOFS_OPTS \
        $tmp

    rm -fr "$tmp"
    pop_cleanup
}

# Create USB CRAMFS based image
function build_usb_cramfs()
{
    local usb="$1" ; shift
    local console="$1" ; shift
    local custom="$1"
    local serial=

    if [ "$console" != "$GRAPHIC_CONSOLE" ] ; then
	serial=1
	console_dev=$(extract_console_dev $console)
	console_baud=$(extract_console_baud $console)
	console_parity=$(extract_console_parity $console)
	console_bits=$(extract_console_bits $console)
    fi
    prepare_cramfs "$console" "$custom"
    echo "* Creating USB CRAMFS based image"

    let vfat_size=${cramfs_size}+$FREE_SPACE

    # Make VFAT filesystem for USB
    mkfs.vfat -C "$usb" $vfat_size

    # Populate it
    echo "* Populating USB with overlay images and cramfs"
    mcopy -bsQ -i "$usb" $isofs/kernel $isofs/pl_version ::/
    mcopy -bsQ -i "$usb" ${BUILDTMP}/cramfs.img ::/

    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${serial:+SERIAL 0 $console_baud}
DEFAULT kernel
APPEND ramdisk_size=$cramfs_size initrd=cramfs.img root=/dev/ram0 ro ${serial:+console=${console_dev},${console_baud}${console_parity}${console_bits}}
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF
    mcopy -bsQ -i "$usb" "$tmp" ::/syslinux.cfg
    rm -f "$tmp"

    echo "* Making USB CRAMFS based image bootable"
    syslinux "$usb"
}

function type_to_name()
{
    echo $1 | sed '
        s/usb$/.usb/;
        s/usb_partition$/-partition.usb/;
        s/iso$/.iso/;
        s/usb_cramfs$/-cramfs.usb/;
        s/iso_cramfs$/-cramfs.iso/;
        '
}

[ -z "$OUTPUT_BASE" ] && OUTPUT_BASE="$PLC_NAME-BootCD-$BOOTCD_VERSION"

for t in $TYPES; do
    arg=$t
    console=$CONSOLE_INFO

    # figure if this is a serial image (can be specified in the type or with -s)
    if  [[ "$t" == *serial* || "$console" != "$GRAPHIC_CONSOLE" ]]; then
	# remove serial from type
	t=`echo $t | sed 's/_serial//'`
	# check console
	[ "$console" == "$GRAPHIC_CONSOLE" ] && console="$SERIAL_CONSOLE"
	# compute filename part
	if [ "$console" == "$SERIAL_CONSOLE" ] ; then
	    serial="-serial"
	else
	    serial="-serial-$(echo $console | sed -e 's,:,,g')"
	fi
    else
	serial=""
    fi
    
    tname=`type_to_name $t`
    # if -o is specified (as it has no default)
    if [ -n "$OUTPUT_NAME" ] ; then
	output=$OUTPUT_NAME
    else
	output="${OUTPUT_BASE}${serial}${tname}"
    fi

    echo "*** Dealing with type=$arg"
    echo '*' build_$t "$output" "$console" "$CUSTOM_DIR"
    if [ ! -n "$DRY_RUN" ] ; then
	build_$t "$output" "$console" "$CUSTOM_DIR" 
    fi
done

exit 0
