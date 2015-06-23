#!/bin/bash
#
# Builds custom BootCD ISO and USB images in the current
# directory. 
#
# Aaron Klingaman <alk@absarokasoft.com>
# Mark Huang <mlhuang@cs.princeton.edu>
# Copyright (C) 2004-2007 The Trustees of Princeton University
#
# Jan 2015 - f21 comes with isolinux 6.03 (was 4.05 in f20)
# http://www.syslinux.org/wiki/index.php/ISOLINUX

COMMAND=$(basename $0)
DIRNAME=$(dirname $0)
PATH=/sbin:/bin:/usr/sbin:/usr/bin

# debugging flags
# keep KERNEL_DEBUG_ARGS void for production
KERNEL_DEBUG_ARGS=""
# add more flags here for debugging
# KERNEL_DEBUG_ARGS="$KERNEL_DEBUG_ARGS some_other_kernel_arg"
# see also
#  (*) GetBootMedium that has some provisions for common
#      kargs, like e.g. for removing the hangcheck feature,
#      or for turning on debug messages for systemd
#      these can be turned on with tags on the node
#  (*) tests default config, that uses this feature so
#      the tests can benefit these features, without deploying
#      them by default in production

# defaults
DEFAULT_TYPES="usb iso"
# Leave 4 MB of free space
GRAPHIC_CONSOLE="graphic"
SERIAL_CONSOLE="ttyS0:115200:n:8"
CONSOLE_INFO=$GRAPHIC_CONSOLE
MKISOFS_OPTS="-R -J -r -f -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"
# isolinux-debug.bin is supposedly helpful as well if available,
# when things don't work as expected
#MKISOFS_OPTS="-R -J -r -f -b isolinux-debug.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"

FREE_SPACE=4096

# command-line settable args
NODE_CONFIGURATION_FILE=
CUSTOM_DIR=
OUTPUT_BASE=
DRY_RUN=""
OUTPUT_NAME=""
TYPES=""
KERNEL_ARGS=""

# various globals
BUILDTMP=""
FULL_VERSION_STRING=""
ISOREF=""
ISOFS=""
OVERLAY=""
IS_SERIAL=""
console_dev=""
console_baud=""
console_spec=""
console_serial_line=""


#################### compute all supported types
# removing support for serial in the type
# this is because kargs.txt goes in the overlay, that is computed only once
# so we cannot handle serial and graphic modes within the same invokation of this script

ALL_TYPES=""
for x in iso usb usb_partition; do for c in "" "_cramfs" ; do
  t="${x}${c}"
  case $t in
      usb_partition_cramfs)
	  # unsupported
	  ;;
      *)
	  ALL_TYPES="$ALL_TYPES $t" ;;
  esac
done; done

#################### cleanup utilities
declare -a _CLEANUPS=()
function do_cleanup() {
    cd / ; for i in "${_CLEANUPS[@]}"; do $i ; done
}
function push_cleanup() {
    _CLEANUPS=( "${_CLEANUPS[@]}" "$*" )
}
function pop_cleanup() {
    unset _CLEANUPS[$((${#_CLEANUPS[@]} - 1))]
}

#################### initialization
function init_and_check () {

    # Change to our source directory
    local srcdir=$(cd $DIRNAME && pwd -P)
    pushd $srcdir

    # Root of the isofs
    ISOREF=$PWD/${VARIANT}

    # The reference image is expected to have been built by prep.sh (see .spec)
    # we disable the initial logic that called prep.sh if that was not the case
    # this is because prep.sh needs to know pldistro 
    if [ ! -f $ISOREF/isofs/bootcd.img -o ! -f $ISOREF/version.txt ] ; then
	echo "Could not find isofs and version.txt in $ISOREF"
	if [ "$VARIANT" == "build" ] ; then
	    echo "You have to run prep.sh prior to calling $COMMAND"
	else
	    echo "You need to create your variant image, see kvariant.sh"
	fi
	echo "Exiting .."
	exit 1
    fi

    # build/version.txt written by prep.sh
    BOOTCD_VERSION=$(cat ${VARIANT}/version.txt)

    if [ -f /etc/planetlab/plc_config ] ; then
        # Source PLC configuration
	. /etc/planetlab/plc_config
    fi

    # use /var/tmp that should be large enough on both chroot- or vserver-based myplc
    BUILDTMP=/var/tmp

    FULL_VERSION_STRING="${PLC_NAME} BootCD ${BOOTCD_VERSION}"

}

# NOTE
# the custom-dir feature is designed to let a myplc try/ship a patched bootcd
# without the need for a full devel environment
# for example, you would create /root/custom-bootcd/etc/rc.d/init.d/pl_hwinit
# and run this script with -C /root/custom-bootcd
# this creates a third .img image of the custom dir, that 'hides' the files from 
# bootcd.img in the resulting unionfs
# it seems that this feature has not been used nor tested in a long time, use with care

usage() {
    echo "Usage: $COMMAND [OPTION]..."
    echo "    -f plnode.txt    Node to customize CD for (default: none)"
    echo "    -t 'types'       Build the specified images (default: $DEFAULT_TYPES)"
    echo "                     NOTE: mentioning 'serial' as part of the type is not supported anymore"
    echo "    -a               Build all known types as listed below"
    echo "    -s console-info  Enable a serial line as console and also bring up getty on that line"
    echo "                     console-info: tty:baud-rate:parity:bits"
    echo "                     or 'default' shortcut for $SERIAL_CONSOLE"
    echo "    -S               equivalent to -s default"
    echo "    -O output-base   The prefix of the generated files (default: PLC_NAME-BootCD-VERSION)"
    echo "                     useful when multiple types are provided"
    echo "                     can be a full path"
    echo "    -o output-name   The full name of the generated file"
    echo "    -C custom-dir    Custom directory"
    echo "    -V variant       Use a variant - see kvariant.sh"
    echo "    -n               Dry run - mostly for debug/test purposes"
    echo "    -k               Add additional parameters to the kargs.txt file"
    echo "    -h               This message"
    echo "All known types: $ALL_TYPES"
    exit 1
}

#################### 
function parse_command_line () {

    # init
    TYPES=""
    # Get options
    while getopts "f:t:as:SO:o:C:V:k:nh" opt ; do
	case $opt in
	    f) NODE_CONFIGURATION_FILE=$OPTARG ;;
	    t) TYPES="$TYPES $OPTARG" ;;
	    a) TYPES="$ALL_TYPES" ;;
	    s) CONSOLE_INFO="$OPTARG" ;;
	    S) CONSOLE_INFO=$SERIAL_CONSOLE ;;
	    O) OUTPUT_BASE="$OPTARG" ;;
	    o) OUTPUT_NAME="$OPTARG" ;;
	    C) CUSTOM_DIR="$OPTARG" ;;
	    V) VARIANT="$OPTARG" ;;
	    k) KERNEL_ARGS="$KERNEL_ARGS $OPTARG" ;;
	    n) DRY_RUN=true ;;
	    h|*) usage ;;
	esac
    done

    # use defaults if not set
    [ -z "$TYPES" ] && TYPES="$DEFAULT_TYPES"
    [ -z "$VARIANT" ] && VARIANT="build"
    [ "$CONSOLE_INFO" == "default" ] && CONSOLE_INFO=$SERIAL_CONSOLE

    if [ -n "$NODE_CONFIGURATION_FILE" ] ; then
    # check existence of NODE_CONFIGURATION_FILE and normalize as we will change directory
	if [ ! -f "$NODE_CONFIGURATION_FILE" ] ; then
	    echo "Node configuration file $NODE_CONFIGURATION_FILE not found - exiting"
	    exit 1
	fi
	cf_dir="$(dirname $NODE_CONFIGURATION_FILE)"
	cf_dir="$(cd $cf_dir; pwd -P)"
	cf_file="$(basename $NODE_CONFIGURATION_FILE)"
	NODE_CONFIGURATION_FILE="$cf_dir"/"$cf_file"
    fi

    # check TYPES 
    local matcher="XXX$(echo $ALL_TYPES | sed -e 's,\W,XXX,g')XXX"
    for t in $TYPES; do
	echo Checking type $t
	echo $matcher | grep XXX${t}XXX &> /dev/null
	if [ "$?" != 0 ] ; then
	    echo Unknown type $t
	    usage
	fi
    done

}

####################
function init_serial () {
    local console=$1; shift
    if [ "$console" == "$GRAPHIC_CONSOLE" ] ; then
	IS_SERIAL=
	console_spec=""
	echo "Standard, graphic, non-serial mode"
    else
	IS_SERIAL=true
	console_dev=$(echo "$console" | awk -F: ' {print $1}')
	console_baud=$(echo "$console" | awk -F: ' {print $2}')
	[ -z "$console_baud" ] && console_baud="115200"
	local console_parity=$(echo "$console" | awk -F: ' {print $3}')
	[ -z "$console_parity" ] && console_parity="n"
	local console_bits=$(echo "$console" | awk -F: ' {print $4}')
	[ -z "$console_bits" ] && console_bits="8"
	console_spec="console=${console_dev},${console_baud}${console_parity}${console_bits}"
	local tty_nb=$(echo $console_dev | sed -e 's,[a-zA-Z],,g')
	console_serial_line="SERIAL ${tty_nb} ${console_baud}"
	echo "Serial mode"
	echo "console_serial_line=${console_serial_line}"
	echo "console_spec=${console_spec}"
    fi
}

#################### run once : build the overlay image
function build_overlay () {

    BUILDTMP=$(mktemp -d ${BUILDTMP}/bootcd.XXXXXX)
    push_cleanup rm -fr "${BUILDTMP}"

    # initialize ISOFS
    ISOFS="${BUILDTMP}/isofs"
    mkdir -p "$ISOFS"
    for i in "$ISOREF"/isofs/{bootcd.img,kernel}; do
	ln -s "$i" "$ISOFS"
    done
    # use new location as of fedora 12
    # used to be in /usr/lib/syslinux/isolinux.bin
    # removed backward compat in jan. 2015
    # as of syslinux 6.05 (fedora 21) ldlinux.c32 is required by isolinux.bin
    # the debug version can come in handy at times, and is 40k as well
    isolinuxdir="/usr/share/syslinux"
    # ship only what is mandatory, and forget about
    # (*) isolinux-debug.bin as its name confuses mkisofs
    # (*) memdisk that is not useful
    isolinuxfiles="isolinux.bin ldlinux.c32"
    for isolinuxfile in $isolinuxfiles; do
	[ -f $isolinuxdir/$isolinuxfile ] && cp $isolinuxdir/$isolinuxfile "${BUILDTMP}/isofs"
    done

    # Root of the ISO and USB images
    echo "* Populating root filesystem..."
    OVERLAY="${BUILDTMP}/overlay"
    install -d -m 755 $OVERLAY
    push_cleanup rm -fr $OVERLAY

    # Create version files
    echo "* Creating version files"

    # Boot Manager compares pl_version in both places to make sure that
    # the right CD is mounted. We used to boot from an initrd and mount
    # the CD on /usr. Now we just run everything out of the initrd.
    for file in $OVERLAY/pl_version $OVERLAY/usr/isolinux/pl_version ; do
	mkdir -p $(dirname $file)
	echo "$FULL_VERSION_STRING" >$file
    done

    # Install boot server configuration files
    echo "* Installing boot server configuration files"

    # We always intended to bring up and support backup boot servers,
    # but never got around to it. Just install the same parameters for
    # both for now.
    for dir in $OVERLAY/usr/boot $OVERLAY/usr/boot/backup ; do
	install -D -m 644 $PLC_BOOT_CA_SSL_CRT $dir/cacert.pem
	install -D -m 644 $PLC_ROOT_GPG_KEY_PUB $dir/pubring.gpg
	echo "$PLC_BOOT_HOST" >$dir/boot_server
	echo "$PLC_BOOT_SSL_PORT" >$dir/boot_server_port
	echo "/boot/" >$dir/boot_server_path
    done

    # Install old-style boot server configuration files
    # as opposed to what a former comment suggested, 
    # this is still required, somewhere in the bootmanager apparently
    install -D -m 644 $PLC_BOOT_CA_SSL_CRT $OVERLAY/usr/bootme/cacert/$PLC_BOOT_HOST/cacert.pem
    echo "$FULL_VERSION_STRING" >$OVERLAY/usr/bootme/ID
    echo "$PLC_BOOT_HOST" >$OVERLAY/usr/bootme/BOOTSERVER
    echo "$PLC_BOOT_HOST" >$OVERLAY/usr/bootme/BOOTSERVER_IP
    echo "$PLC_BOOT_SSL_PORT" >$OVERLAY/usr/bootme/BOOTPORT

    # Generate /etc/issue
    echo "* Generating /etc/issue"

    if [ "$PLC_WWW_PORT" = "443" ] ; then
	PLC_WWW_URL="https://$PLC_WWW_HOST/"
    elif [ "$PLC_WWW_PORT" != "80" ] ; then
	PLC_WWW_URL="http://$PLC_WWW_HOST:$PLC_WWW_PORT/"
    else
	PLC_WWW_URL="http://$PLC_WWW_HOST/"
    fi

    mkdir -p $OVERLAY/etc
    cat >$OVERLAY/etc/issue <<EOF
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
    sed -e "s@^root:[^:]*:\(.*\)@root:$ROOT_PASSWORD:\1@" ${VARIANT}/passwd >$OVERLAY/etc/passwd

# this is more harmful than helpful
# idea being, since we start a full-featured fedora system now, it would
# have been nice to be able to enter sshd very early on - before bm has even been downloaded
# however somehow it appears that these lines ruin all chances to enter ssh at all
# either early or even later on;
# plus, it is unclear what this would give on non=systemd nodes, so I am backing off for now    
#    # recent bootCDs rely on a standard systemd startup sequence
#    # so allow debug key to enter in this context whenever that makes sense
#    mkdir -p $OVERLAY/root/.ssh
#    chmod 700 $OVERLAY/root/.ssh
#    cp $PLC_DEBUG_SSH_KEY_PUB $OVERLAY/root/.ssh/authorized_keys
#    chmod 600 $OVERLAY/root/.ssh/authorized_keys

    # Install node configuration file (e.g., if node has no floppy disk or USB slot)
    if [ -f "$NODE_CONFIGURATION_FILE" ] ; then
	echo "* Installing node configuration file $NODE_CONFIGURATION_FILE -> /usr/boot/plnode.txt of the bootcd image"
	install -D -m 644 $NODE_CONFIGURATION_FILE $OVERLAY/usr/boot/plnode.txt
	NODE_ID=$(source $NODE_CONFIGURATION_FILE; echo $NODE_ID)
	echo "* Building network configuration for $NODE_ID"
	plnet -- --root $OVERLAY --files-only --program BootCD $NODE_ID
    fi

    [ -n "$IS_SERIAL" ] && KERNEL_ARGS="$KERNEL_ARGS ${console_spec}"

    # tmp: should be restricted to f15 nodes and above
    # making sure the network interfaces are still numbered eth0 and above
    KERNEL_ARGS="$KERNEL_ARGS biosdevname=0"
    # making sure selinux is turned off - somehow this is needed with lxc/f14
    KERNEL_ARGS="$KERNEL_ARGS selinux=0"
    # add any debug flag if any (defined in the header of this script)
    KERNEL_ARGS="$KERNEL_ARGS $KERNEL_DEBUG_ARGS"
    # propagate kernel args for later boot stages
    [ -n "$KERNEL_ARGS" ] && echo "$KERNEL_ARGS" > $OVERLAY/kargs.txt

    # Pack overlay files into a compressed archive
    echo "* Compressing overlay image"
    (cd $OVERLAY && find . | cpio --quiet -c -o) | gzip -9 >$ISOFS/overlay.img

    rm -rf $OVERLAY
    pop_cleanup

    if [ -n "$CUSTOM_DIR" ]; then
	echo "* Compressing custom image"
	(cd "$CUSTOM_DIR" && find . | cpio --quiet -c -o) | gzip -9 >$ISOFS/custom.img
    fi

    # Calculate ramdisk size (total uncompressed size of both archives)
    ramdisk_size=$(gzip -l $ISOFS/bootcd.img $ISOFS/overlay.img ${CUSTOM_DIR:+$ISOFS/custom.img} | tail -1 | awk '{ print $2; }') # bytes
    ramdisk_size=$((($ramdisk_size + 1023) / 1024)) # kilobytes

    echo "$FULL_VERSION_STRING" >$ISOFS/pl_version

    popd
}

#################### plain ISO
function build_iso() {
    local iso="$1" ; shift
    local custom="$1"

    # Write isolinux configuration
    cat >$ISOFS/isolinux.cfg <<EOF
${console_serial_line}
PROMPT 0
DEFAULT planetlab-bootcd

LABEL planetlab-bootcd
  DISPLAY pl_version
  LINUX kernel
  APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${KERNEL_ARGS}
EOF

    # Create ISO image
    echo "* Generated isolinux.cfg -------------------- BEG"
    cat $ISOFS/isolinux.cfg
    echo "* Generated isolinux.cfg -------------------- END"
    echo "* Creating ISO image in pwd=$(pwd)"
    echo "* with command mkisofs -o $iso $MKISOFS_OPTS $ISOFS"
    mkisofs -o "$iso" $MKISOFS_OPTS $ISOFS
}

#################### USB with partitions
function build_usb_partition() {
    echo -n "* Creating USB image with partitions..."
    local usb="$1" ; shift
    local custom="$1"

    local size=$(($(du -Lsk $ISOFS | awk '{ print $1; }') + $FREE_SPACE))
    size=$(( $size / 1024 ))

    local heads=64
    local sectors=32
    local cylinders=$(( ($size*1024*2)/($heads*$sectors) ))
    local offset=$(( $sectors*512 ))

    if [ -f  /usr/lib/syslinux/mkdiskimage ] ; then
        /usr/lib/syslinux/mkdiskimage -M -4 "$usb" $size $heads $sectors
    else
        mkdiskimage -M -4 "$usb" $size $heads $sectors
    fi

    cat >${BUILDTMP}/mtools.conf<<EOF
drive z:
file="${usb}"
cylinders=$cylinders
heads=$heads
sectors=$sectors
offset=$offset
mformat_only
mtools_skip_check=1
EOF
    # environment variable for mtools
    export MTOOLSRC="${BUILDTMP}/mtools.conf"

    ### COPIED FROM build_usb() below!!!!
    echo -n " populating USB image... "
    mcopy -bsQ -i "$usb" "$ISOFS"/* z:/
	
    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${console_serial_line}
PROMPT 0
DEFAULT planetlab-bootcd

LABEL planetlab-bootcd
  DISPLAY pl_version
  LINUX kernel
  APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${KERNEL_ARGS}
EOF
    mdel -i "$usb" z:/isolinux.cfg 2>/dev/null || :
    mcopy -i "$usb" "$tmp" z:/syslinux.cfg
    rm -f "$tmp"
    rm -f "${MTOOLSRC}"
    unset MTOOLSRC

    echo "making USB image bootable."
    syslinux -o $offset "$usb"

}

#################### plain USB
function build_usb() {
    echo -n "* Creating USB image... "
    local usb="$1" ; shift
    local custom="$1"

    rm -f "$usb"
    mkfs.vfat -C "$usb" $(($(du -Lsk $ISOFS | awk '{ print $1; }') + $FREE_SPACE))

    cat >${BUILDTMP}/mtools.conf<<EOF
mtools_skip_check=1
EOF
    # environment variable for mtools
    export MTOOLSRC="${BUILDTMP}/mtools.conf"

    # Populate it
    echo -n " populating USB image... "
    mcopy -bsQ -i "$usb" "$ISOFS"/* ::/

    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${console_serial_line}
PROMPT 0
DEFAULT planetlab-bootcd

LABEL planetlab-bootcd
  DISPLAY pl_version
  LINUX kernel
  APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img${custom:+,custom.img} root=/dev/ram0 rw ${KERNEL_ARGS}
EOF
    mdel -i "$usb" ::/isolinux.cfg 2>/dev/null || :
    mcopy -i "$usb" "$tmp" ::/syslinux.cfg
    rm -f "$tmp"
    rm -f "${MTOOLSRC}"
    unset MTOOLSRC

    echo "making USB image bootable."
    syslinux "$usb"
}

#################### utility to setup CRAMFS related support
function prepare_cramfs() {
    [ -n "$CRAMFS_PREPARED" ] && return 0
    local custom=$1; 

    echo "* Setting up CRAMFS-based images"
    local tmp="${BUILDTMP}/cramfs-tree"
    mkdir -p "$tmp"
    push_cleanup rm -rf $tmp
    pushd $tmp
    gzip -d -c $ISOFS/bootcd.img     | cpio -diu
    gzip -d -c $ISOFS/overlay.img    | cpio -diu
    [ -n "$custom" ] && \
        gzip -d -c $ISOFS/custom.img | cpio -diu

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
    for file in etc/inittab etc/event.d/rcS etc/init/rcS.conf; do
	[ -f $file ] && sed -i 's,pl_sysinit,pl_rsysinit,' $file
    done

    # modify inittab to have a serial console
    # xxx this might well be broken with f12 and above xxx
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
# generated by $COMMAND
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

#################### Create ISO CRAMFS image
function build_iso_cramfs() {
    local iso="$1" ; shift
    local custom="$1"

    prepare_cramfs "$custom"
    echo "* Creating ISO CRAMFS-based image"

    local tmp="${BUILDTMP}/cramfs-iso"
    mkdir -p "$tmp"
    push_cleanup rm -rf $tmp
    (cd $ISOFS && find . | grep -v "\.img$" | cpio -p -d -u $tmp/)
    cat >$tmp/isolinux.cfg <<EOF
${console_serial_line}
PROMPT 0
DEFAULT planetlab-bootcd

LABEL planetlab-bootcd
  DISPLAY pl_version
  LINUX kernel
  APPEND ramdisk_size=$ramdisk_size initrd=cramfs.img root=/dev/ram0 rw ${KERNEL_ARGS}
EOF

    cp ${BUILDTMP}/cramfs.img $tmp
    mkisofs -o "$iso" \
        $MKISOFS_OPTS \
        $tmp

    rm -fr "$tmp"
    pop_cleanup
}

#################### Create USB CRAMFS based image
function build_usb_cramfs() {
    local usb="$1" ; shift
    local custom="$1"

    prepare_cramfs "$custom"
    echo "* Creating USB CRAMFS based image"

    let vfat_size=${cramfs_size}+$FREE_SPACE

    # Make VFAT filesystem for USB
    mkfs.vfat -C "$usb" $vfat_size

    # Populate it
    echo "* Populating USB with overlay images and cramfs"
    mcopy -bsQ -i "$usb" $ISOFS/kernel $ISOFS/pl_version ::/
    mcopy -bsQ -i "$usb" ${BUILDTMP}/cramfs.img ::/

    # Use syslinux instead of isolinux to make the image bootable
    tmp="${BUILDTMP}/syslinux.cfg"
    cat >$tmp <<EOF
${console_serial_line}
PROMPT 0
DEFAULT planetlab-bootcd

LABEL planetlab-bootcd
  DISPLAY pl_version
  LINUX kernel
  APPEND ramdisk_size=$ramdisk_size initrd=cramfs.img root=/dev/ram0 rw ${KERNEL_ARGS}
EOF

    mcopy -bsQ -i "$usb" "$tmp" ::/syslinux.cfg
    rm -f "$tmp"

    echo "* Making USB CRAMFS based image bootable"
    syslinux "$usb"
}

#################### map on all types provided on the command-line and invoke one of the above functions
function build_types () {

    [ -z "$OUTPUT_BASE" ] && OUTPUT_BASE="$PLC_NAME-BootCD-$BOOTCD_VERSION"

    # alter output filename to reflect serial settings
    if [ -n "$IS_SERIAL" ] ; then
	if [ "$CONSOLE_INFO" == "$SERIAL_CONSOLE" ] ; then
	    serial="-serial"
	else
	    serial="-serial-$(echo $CONSOLE_INFO | sed -e 's,:,,g')"
	fi
    else
	serial=""
    fi
    
    function type_to_name() {
	echo $1 | sed '
        s/usb$/.usb/;
        s/usb_partition$/-partition.usb/;
        s/iso$/.iso/;
        s/usb_cramfs$/-cramfs.usb/;
        s/iso_cramfs$/-cramfs.iso/;
        '
    }

    for t in $TYPES; do
	arg=$t

	tname=`type_to_name $t`
        # if -o is specified (as it has no default)
	if [ -n "$OUTPUT_NAME" ] ; then
	    output=$OUTPUT_NAME
	else
	    output="${OUTPUT_BASE}${serial}${tname}"
	fi

	echo "*** Dealing with type=$arg"
	echo '*' build_$t "$output" "$CUSTOM_DIR"
	[ -n "$DRY_RUN" ] || build_$t "$output" "$CUSTOM_DIR" 
    done
}

#################### 
function main () {

    parse_command_line "$@"

    init_and_check

    echo "* Building bootcd images for $NODE_CONFIGURATION_FILE ($FULL_VERSION_STRING) - $(date +%H-%M:%S)"
    # Do not tolerate errors
    set -e
    trap "do_cleanup" ERR INT EXIT

    init_serial $CONSOLE_INFO
    build_overlay
    build_types

    echo "* Done with bootcd images for $NODE_CONFIGURATION_FILE - $(date +%H-%M:%S)"
    exit 0
}

####################
main "$@"
