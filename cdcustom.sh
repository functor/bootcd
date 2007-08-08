#!/bin/bash

# purpose : create a node-specific CD ISO image

# NOTE (see also bootcd/build.sh)
# If you run your own myplc instance, and you dont need to
# customize the bootcd, you might wish to use bootcd/build.sh
# with the -f option
# However cdcustom.sh might turn out useful if
# (*) you only have an iso image and nothing else
# (*) or you want to generate several iso images in a single run
# (*) or you run myplc rpm, but need to customize the bootcd image,
#     because the myplc rpm does not come with the required sources

# See usage for full details

######## Implementation note
# in a former release it was possible to perform faster by
# loopback-mounting the generic iso image
# Unfortunately mkisofs cannot graft a file that already exists on the
# original tree (so overlay.img cannot be overridden)
# to make things worse we cannot loopback-mount the cpio-gzipped
# overlay image either, so all this stuff is way more complicated
# than it used to be.
#
# as of 2006 jun 28 we use a third image named custom.img for
# overriding files in bootcd.img, which let us use bootcd.img intact
# and thus notably speeds things up 
#
######## Logic
# here is how we do this
# for efficiency, we do only once:
#   (*) mount the generic iso
#   (*) copy it into a temp dir
#   (*) unzip/unarchive overlay image into another temp dir
#   (*) if required prepare a custom.img 
# then for each node, we
#   (*) insert plnode.txt at the right place if not a default iso
#   (*) rewrap a gzipped/cpio overlay.img, that we push onto the
#       copied iso tree
#   (*) rewrap this into an iso image
# and cleanup/umount everything 


set -e 
COMMANDSH=$(basename $0)
COMMAND=$(basename $0 .sh)
REVISION="$Id: cdcustom.sh,v 1.8 2006/06/28 15:01:01 thierry Exp $"

function usage () {

   echo "Usage: $COMMANDSH [-f] [ -c bootcd-dir] generic-iso node-config [.. node-configs]"
   echo " Creates a node-specific ISO image"
   echo "*Options"
   echo -e " -f\r\t\tForces overwrite of output iso images"
   echo -e " -c bootcd-dir\r\t\tis taken as the root of a set of custom bootcd files"
   echo -e "\t\ti.e. the files under dir take precedence"
   echo -e "\t\tover the ones in the generic bootcd"
   echo "*Arguments"
   echo -e " generic-iso\r\t\tThe iso image as downloaded from myplc"
   echo -e "\t\ttypically in /plc/data/var/www/html/download/"
   echo -e " node-config(s)\r\t\tnode config files (plnode.txt format)"
   echo -e " default\r\t\tmentioned instead of a plnode.txt file, for generating"
   echo -e "\t\ta node-independent iso image"
   echo -e "\t\tThis is defaultbehaviour when no node-config are provided"
   echo "*Outputs"
   echo " node-specific iso images are named after nodename[-bootcd-dir].iso"
   echo " node-independant iso image is named after bootcd-dir.iso"
   echo "*Examples"
   echo "# $COMMANDSH -c onelab-bootcd /plc/data/var/www/html/download/onelab-BootCD-3.3.iso"
   echo "  Creates onelab-bootcd.iso that has no plnode.txt embedded and that uses"
   echo "  the hw init scripts located under onelab-bootcd/etc/rc.d/init.d/"
   echo "# $COMMANDSH  /plc/data/var/www/html/download/onelab-BootCD-3.3.iso node1.txt node2.txt"
   echo "  Creates node1.iso and node2.iso that have plnode.txt embedded for these two nodes"
   echo "  and the standard bootcd"
   echo "*Version $REVISION"
   exit 1
}

### read config file in a subshell and echoes host_name
function host_name () {
  export CONFIG=$1; shift
  ( . "$CONFIG" ; echo $HOST_NAME )
}

### Globals
PLNODE_PATH=/usr/boot
PLNODE=plnode.txt
DEFAULT_TARGET=default
# defined on the command-line
CUSTOM_DIR=
## arg-provided generic iso
ISO_GENERIC=
# node-dep conf file
NODE_CONFIG=
# resulting iso image and log
NODE_ISO=
NODE_LOG=
## mount points and temps
ISO_MOUNT=/tmp/$COMMAND-$$-mount
ISO_ROOT=/tmp/$COMMAND-$$-iso
OVERLAY_ROOT=/tmp/$COMMAND-$$-overlay
# node-dep cpio/gzip image
NODE_OVERLAY=

CPIO_OARGS="-oc --quiet"
CPIO_IARGS="-id --quiet"
CPIO_PARGS="-pdu --quiet"

# export DEBUG=true
# for enabling debug messages (set -x)

# export VERBOSE=true for enabling this
function verbose () {
   if [ -n "$VERBOSE" ] ; then
     echo "$@"
   fi
 }

function message () { echo -e "$COMMAND : $@" ; }
function message-n () { echo -en "$COMMAND : $@" ; }
function message-done () { echo Done ; }
function error () { echo -e "$COMMAND : ERROR $@ - exiting" ; exit 1 ;}

# lazy startup
STARTED_UP=
function startup () {

   [[ -n "$DEBUG" ]] && set -x

   # lazy : run only once
   [[ -n "$STARTED_UP" ]] && return
   message "lazy start up"

   ### checking
   [ ! -f "$ISO_GENERIC" ] && error "Could not find template ISO image"
   [ -d "$ISO_MOUNT" ] && error "$ISO_MOUNT already exists" 
   [ -d "$ISO_ROOT" ] && error "$ISO_ROOT already exists" 
   [ -d "$OVERLAY_ROOT" ] && error "$OVERLAY_ROOT already exists"

   verbose "Creating temp dirs"
   mkdir -p $ISO_MOUNT $ISO_ROOT $OVERLAY_ROOT
   verbose "Mounting generic ISO $ISO_GENERIC under $ISO_MOUNT"
   mount -o ro,loop $ISO_GENERIC $ISO_MOUNT

   ### DONT!! use tar for duplication
   message "Duplicating ISO image in $ISO_ROOT"
   (cd $ISO_MOUNT ; find . | cpio $CPIO_PARGS  $ISO_ROOT )

   message "Extracting generic overlay image in $OVERLAY_ROOT"
   gzip -d -c "$ISO_ROOT/overlay.img" | ( cd "$OVERLAY_ROOT" ; cpio $CPIO_IARGS )

   if [ -n "$CUSTOM_DIR" ] ; then
     [ -d "$CUSTOM_DIR" ] || error "Directory $CUSTOM_DIR not found"
     prepare_custom_image
   fi

   STARTED_UP=true

}   

function prepare_custom_image () {

   # Cleaning any sequel
   rm -f custom.img
   [ -f custom.img ] && error "Could not cleanup custom.img"
   
   message "WARNING : You are creating *custom* boot CDs"

   message-n "Creating $ISO_ROOT/custom.img"
   (cd $CUSTOM_DIR ; find . | cpio $CPIO_OARGS) | gzip -9 > $ISO_ROOT/custom.img
   message-done
   
}

function node_cleanup () {
   verbose "Cleaning node-dependent cpio image"
   rm -rf "$NODE_OVERLAY"
  
}

function cleanup () {

   echo "$COMMAND : cleaning up"
   [[ -n "$DEBUG" ]] && set -x

   verbose "Cleaning overlay image"
   rm -rf "$OVERLAY_ROOT"
   verbose "Cleaning ISO image"
   rm -rf "$ISO_ROOT"
   verbose "Cleaning node-dep overlay image"
   rm -f "$NODE_OVERLAY"
   verbose "Unmounting $ISO_MOUNT"
   umount "$ISO_MOUNT" 2> /dev/null
   rmdir "$ISO_MOUNT"
   exit
}

function abort () {
   echo "$COMMAND : Aborting"
   message "Cleaning $NODE_ISO"
   rm -f "$NODE_ISO"
   cleanup
}

function main () {

   trap abort int hup quit err
   set -e

   [[ -n "$DEBUG" ]] && set -x

   # accept -b as -c, I am used to it now
   while getopts "c:b:fh" opt ; do
     case $opt in
       c|b)
	 CUSTOM_DIR=$OPTARG ;;
       f)
	 FORCE_OUTPUT=true ;;
       h|*)
	 usage ;;
     esac
   done

   shift $(($OPTIND-1))
   
   [[ -z "$@" ]] && usage
   ISO_GENERIC=$1; shift

   if [[ -z "$@" ]] ; then
     nodes="$DEFAULT_TARGET"
   else
     nodes="$@"
   fi

#  perform that later (lazily)
#  so that (1st) node-dep checking are done before we bother to unpack
#   startup

   for NODE_CONFIG in $nodes ; do

     if [ "$NODE_CONFIG" = "$DEFAULT_TARGET" ] ; then
       NODE_DEP=""
       # default node without customization does not make sense
       if [ -z "$CUSTOM_DIR" ] ; then
	 message "creating a non-custom node-indep. image refused\n(Would have no effect)"
	 continue
       else
	 NODENAME=$DEFAULT_TARGET
	 NODEOUTPUT=$(basename $CUSTOM_DIR)
       fi
     else
       NODE_DEP=true
       NODENAME=$(host_name $NODE_CONFIG)
       if [ -z "$NODENAME" ] ; then
	 message "HOST_NAME not found in $NODE_CONFIG - skipped"
	 continue
       fi
       if [ -z "$CUSTOM_DIR" ] ; then
	 NODEOUTPUT=$NODENAME
       else
	 NODEOUTPUT=${NODENAME}-$(basename $CUSTOM_DIR)
       fi
     fi

     message "$COMMAND : dealing with node $NODENAME"

     NODE_ISO="$NODEOUTPUT.iso"
     NODE_LOG="$NODEOUTPUT.log"

     ### checking
     if [ -e  "$NODE_ISO" ] ; then
       if [ -n "$FORCE_OUTPUT" ] ; then
	 message "$NODE_ISO exists, will overwrite (-f)"
	 rm $NODE_ISO
       else
	 message "$NODE_ISO exists, please remove first - skipped" ; continue
       fi
     fi
     if [ -n "$NODE_DEP" -a ! -f "$NODE_CONFIG" ] ; then
       message "Could not find node-specifig config - skipped" ; continue
     fi
     
     startup

     if [ -n "$NODE_DEP" ] ; then
       verbose "Pushing node config into overlay image"
       mkdir -p $OVERLAY_ROOT/$PLNODE_PATH
       cp "$NODE_CONFIG" $OVERLAY_ROOT/$PLNODE_PATH/$PLNODE
     else
       verbose "Cleaning node config for node-indep. image"
       rm -f $OVERLAY_ROOT/$PLNODE_PATH/$PLNODE
     fi

     echo "$COMMAND : Creating overlay image for $NODENAME"
     (cd "$OVERLAY_ROOT" ; find . | cpio $CPIO_OARGS) | gzip -9 > $ISO_ROOT/overlay.img

     message "Refreshing isolinux.cfg"
     # Calculate ramdisk size (total uncompressed size of both archives)

     ##########
     # N.B. Thierry Parmentelat - 2006-06-28
     # the order in which these images need to be mentioned here for
     # isolinux involved some - not so educated - guesses
     # as per syslinux source code in syslinux/runkernel.inc, the
     # config file is parsed left to right, and indeed it's in that
     # order that the files are loaded right off the CD
     # This does not tell however, in case a given file is present in
     # two different images - and that's the very purpose here - which
     # one will take precedence over the other
     # I came up with this order on a trial-and-error basis, I would
     # have preferred to find it described somewhere
     # Might be worth checking with other versions of syslinux in case
     # the custom files would turn out to not be taken into account
     ##########

     if [ -n "$CUSTOM_DIR" ] ; then
       images="bootcd.img custom.img overlay.img"
     else
       images="bootcd.img overlay.img"
     fi
     
     ramdisk_size=$(cd $ISO_ROOT ; gzip -l $images | tail -1 | awk '{ print $2; }') # bytes
     # keep safe, provision for cpio's block size
     ramdisk_size=$(($ramdisk_size / 1024 + 1)) # kilobytes

     initrd_images=$(echo "$images" | sed -e 's/ /,/g')
     # Write isolinux configuration
     cat > $ISO_ROOT/isolinux.cfg <<EOF
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=$initrd_images root=/dev/ram0 rw
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF

     message-n "Writing custom image, log on $NODE_LOG .. "
     mkisofs -o "$NODE_ISO" -R -allow-leading-dots -J -r -b isolinux.bin \
     -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
     "$ISO_ROOT" > "$NODE_LOG" 2>&1
     message-done
   
     node_cleanup
     
     message "CD ISO image for $NODENAME in $NODE_ISO"
   done

   cleanup

}

####################
main "$@"
